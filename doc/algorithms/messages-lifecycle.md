# MessageController ↔ InboxService — Message & Receipt Lifecycle

This document maps the server-side control flow of the message path: how the four `MessageController` endpoints delegate to `InboxService`, and how a message moves through the **hot tier** (heap), the **cold tier** (PostgreSQL `inbox`), and the in-memory **pending-receipts** backstop.

For the high-level model see [2.4 Message Sending & Receiving](../ARCHITECTURE.md#24-message-sending--receiving-server-owned-inbox), [2.5 Delivery Guarantee](../ARCHITECTURE.md#25-delivery-guarantee-server-retained-copy--signed-receipt), and [2.6 Send-Side Reconciliation](../ARCHITECTURE.md#26-send-side-reconciliation-outbox-resync).

## Components

| Store | Where | Durable | Holds |
| --- | --- | --- | --- |
| **Hot tier** (`HotTierStorage`) | JVM heap | No (sender's outbox backs it) | Accepted messages during the post-accept hold window |
| **Cold tier** (`inbox` table) | PostgreSQL | Yes | Messages not confirmed within the hold window |
| **Pending receipts** (`PendingReceipts`) | JVM heap | No (resync re-drives) | Delivery/read acks owed to an offline sender |

## Endpoints → InboxService

| Endpoint | Service call | Effect |
| --- | --- | --- |
| `POST /messages` | `accept` | Stamp sender, **store in hot tier**, publish live, return `accepted` + `serverStartedAt` |
| `POST /messages/batch` | `acceptAll` | Same as `accept` per item (idempotent by `messageId`); used by client resync |
| `GET /inbox` | `getInbox` | Return **hot ∪ cold** messages (as recipient) **+ drained pending receipts** (as sender) |
| `POST /receipts` | `recordReceipt` | Drop the retained copy, **record the ack**, and relay it live to the sender |
| *(scheduled)* | `flushExpired` | Persist-then-evict messages whose hold window elapsed |

## Control-flow block diagram

```mermaid
flowchart TD
    subgraph Controller [MessageController]
        P1["POST /messages"]
        P2["POST /messages/batch"]
        G1["GET /inbox"]
        R1["POST /receipts"]
    end

    subgraph Service [InboxService]
        Acc["accept / acceptAll"]
        Inb["getInbox"]
        Rec["recordReceipt"]
        Flush["flushExpired (scheduled)"]
    end

    Hot[("Hot tier — heap")]
    Cold[("Cold tier — PostgreSQL inbox")]
    PR[("Pending receipts — heap")]
    MQ[["RabbitMQ live fan-out"]]
    Push[["Web Push (VAPID)"]]

    P1 --> Acc
    P2 --> Acc
    G1 --> Inb
    R1 --> Rec

    Acc -->|store copy| Hot
    Acc -->|"publish user.recipient (mandatory)"| MQ

    Flush -->|"claim + persist (1 write)"| Cold
    Flush -->|then evict| Hot

    Rec -->|"drop copy (hot or cold)"| Hot
    Rec -->|"delete row if flushed"| Cold
    Rec -->|"relay live (mandatory)"| MQ
    MQ -.->|"receipt unroutable: sender offline → retain"| PR
    MQ -.->|"message unroutable: recipient offline → notify"| Push

    Inb -->|"union read (as recipient)"| Hot
    Inb -->|"union read (as recipient)"| Cold
    Inb -->|"drain acks (as sender)"| PR
```

## Message-copy state machine

The server-retained copy of one message:

```mermaid
stateDiagram-v2
    [*] --> HotTier: accept() — store + publish live

    HotTier --> Dropped: receipt within hold window<br/>(0 DB writes)
    HotTier --> ColdTier: hold window elapses<br/>flushExpired: persist (1 write) then evict

    ColdTier --> Dropped: receipt — delete row
    ColdTier --> ColdTier: GET /inbox — returned to recipient,<br/>kept until acknowledged

    Dropped --> [*]
```

- **Confirmed fast (both online):** `HotTier → Dropped`, **zero** DB writes.
- **Recipient offline:** `HotTier → ColdTier` (one write), delivered later via `GET /inbox`, then `ColdTier → Dropped` on the signed receipt. The message is published **`mandatory`**, so the broker returns it as unroutable the instant the recipient has no live binding — that return fires a **Web Push** notification (see [Push notifications](#push-notifications)) while the copy is still in the hot tier, preserving the zero-write fast path.
- A message in transit during flush is briefly in **both** tiers (harmless duplicate, de-duped by `messageId`) and **never in neither** (persist-then-evict).

## Receipt path (delivered / read / undecryptable)

A receipt carries `originalSenderId`, so relaying it does **not** depend on the retained copy still existing — this is what lets a second receipt (`read` after `delivered`, in any order) still reach the sender. The receipt is published **`mandatory`**: if the sender is **online** it is routed and delivered live (and *nothing* is stored); if the sender is **offline** the broker returns it as unroutable and the Server retains it in `PendingReceipts` for the sender's next `GET /inbox`. This way an online sender never piles up duplicate acks.

The Server authenticates the **submitter** of `POST /receipts` via JWT (transport auth) and then relays the recipient's **`signature` unaltered** — live as `ReceiptData.signature` and in `GET /inbox` as `MessageReceipt.signature`. Receipts travel outside the Double Ratchet, so each carries an explicit identity-key signature: it is the end-to-end proof the **original sender** verifies against the key directory; server-side verification is optional (reject-early) and never the load-bearing check.

```mermaid
flowchart TD
    Start([Recipient sends receipt]) --> Drop["recordReceipt: drop retained message copy (first receipt only)"]
    Drop --> Live["relay receipt live, mandatory"]
    Live --> Online{Sender online?<br/> routable binding}
    Online -- "Yes (routed)" --> Got["Sender gets it instantly → ✓✓ / read<br/> (nothing stored)"]
    Online -- "No (returned unroutable)" --> Store["Server retains it in PendingReceipts (heap)"]
    Store --> Pull["Sender reconnects → GET /inbox drains pending receipts"]
    Pull --> Got
```

- **Online senders cost nothing extra:** routable receipts are never stored, so a busy conversation does not accumulate thousands of acks to re-send.
- **Non-durable on purpose:** a Server restart clears `PendingReceipts`; the sender then detects the restart (`serverStartedAt` changed) and resyncs, which re-drives the receipt.
- `read` supersedes `delivered` for the same message, so only the latest status per message is retained.
- Requires `spring.rabbitmq.publisher-returns: true`; both **messages** and **receipts** are published `mandatory`. An unroutable **receipt** is retained in `PendingReceipts`; an unroutable **message** triggers a Web Push notification (see [Push notifications](#push-notifications)).

### `undecryptable` — the negative ack

An `undecryptable` receipt travels the **same `recordReceipt` path** — drop the retained copy, relay `mandatory` to the sender — but means the opposite of `delivered`: the recipient got the bytes yet could **not** decrypt them, because the payload was sealed to a **stale Signal identity / pre-key** (the recipient has since logged in on a new device and rotated keys, so the Double Ratchet has no matching session). Dropping the copy is still correct: *no key in existence can decrypt it*, so re-delivery is futile. The repair happens **end-to-end at the sender**, not on the Server:

1. Recipient's ratchet decrypt fails (no session / stale pre-key) → it returns a signed `undecryptable` receipt instead of `delivered`, then discards the message locally.
2. Server drops the retained copy and relays the NACK (live, or via `PendingReceipts` if the sender is offline) — identical machinery to a `delivered`.
3. Sender receives `undecryptable` → re-fetches the recipient's current pre-key bundle (which also re-pins the identity, surfacing *“security code changed”*, see [MESSAGE_SECURITY.md §3.1](../MESSAGE_SECURITY.md#31-key-change-detection-security-code-changed)) → opens a fresh session and **resends the same `messageId` once**.
4. The resend is a brand-new copy through the normal hot/cold path; it now decrypts and is cleared by an ordinary `delivered`.

- **Loop-safe:** the sender resends **once per `messageId`**. If the resend is *also* returned `undecryptable`, the payload is treated as undeliverable — the sender stops and surfaces it locally (it is not a key-rotation problem). Without this NACK an undecryptable message would otherwise sit in the cold tier and be re-pulled on every `GET /inbox` forever, since it can never earn a `delivered`.
- **Server-blind:** the Server never learns *why* — `undecryptable` is just another opaque receipt type it drops-and-relays. No new endpoint, no inbox bookkeeping.

## Push notifications

Because messages are published **`mandatory`**, the broker returns any envelope it cannot route to a live consumer. For a **message**, an unroutable return means the recipient has **no Hub binding** — i.e. the app is not currently connected — which is exactly when a background **Web Push** notification is fired.

```mermaid
flowchart TD
    Acc([accept: store copy + publish message, mandatory]) --> Route{Recipient bound?<br/>live Hub consumer}
    Route -- "Yes (routed)" --> Live["delivered live via Hub → receipt clears copy"]
    Route -- "No (returned unroutable)" --> Notify["ReturnsCallback → PushNotificationService.notifyRecipient"]
    Notify --> Debounce{Passes per-recipient<br/>debounce window?}
    Debounce -- No --> Skip["skip (recent push already sent)"]
    Debounce -- Yes --> Lookup["load push_subscriptions row + sender/group metadata"]
    Lookup --> Send["send VAPID push: title = sender/group name, body = generic"]
    Send --> Stale{404 / 410?}
    Stale -- Yes --> Del["delete stale subscription row"]
```

- **Trigger, not content:** the push payload carries only `senderId` / `groupId` (identity the Server already knows) plus a generic body — **never** E2E message content. The client resolves the local conversation on click and navigates to it.
- **Fast path preserved:** the notification fires from the `ReturnsCallback` while the copy is still in the **hot tier**, so a normal offline delivery still costs a single DB write at flush time and nothing extra here.
- **Only on the unroutable return:** push is fired **exclusively** when the mandatory publish comes back unroutable (recipient has no live binding). There is deliberately **no** flush-time backstop: the rare case where a message routes to a Hub binding that *looks* alive but never delivers is left to the ordinary `GET /inbox` sync — a missed wake-up is a minor UX cost, not a correctness problem.
- **Debounced per recipient:** rapid bursts to the same offline recipient collapse into one notification within a short window (`push.debounce-seconds`), so a chatty sender does not fan out a storm of notifications.
- **Single device:** one subscription per user (`push_subscriptions` keyed by `user_id`, upserted on `POST /push/subscribe`). A stale endpoint returning `404`/`410` is pruned on send; a new login on another device replaces the row.

