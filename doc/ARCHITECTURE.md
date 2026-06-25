# fourletters Architecture

This document outlines the architectural components and communication patterns for **fourletters**, a simple, reliable, end-to-end (E2E) encrypted PWA messenger.

> **Scope — Phase 1 (first version).** This document describes the architecture as it is built for the first release: a **single Server instance**, an in-heap message hot tier, trusted Hubs, **no Redis**, and **no volunteer relays**. Deferred capabilities — volunteer Hubs, the untrusted-Hub hardening (detection, route scoping), and multi-instance Server scaling with Redis — are described separately in [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md). The Phase 1 design deliberately keeps the client wire format and send path forward-compatible with those extensions, so they can be added later without a redesign.

## 1. Component Overview

The system consists of a frontend Progressive Web App (PWA), a **Server** that owns authentication and the durable message inbox, lightweight **Hubs** that deliver live messages over WebSocket, a PostgreSQL relational database, and RabbitMQ used purely as a live fan-out bus.

A defining principle of the architecture is an **asymmetric message path**:

*   **Sending is durable:** the PWA submits every outgoing message over HTTPS to the **Server**, which is the sole authority for accepting and durably owning a message. Clients never send through a Hub.
*   **Receiving is best-effort:** a Hub only pushes already-accepted messages to recipients that are online *right now*. A Hub is a disposable relay and is never responsible for durability.

```mermaid
flowchart TD
    Client["Angular PWA<br/>(IndexedDB, WebCrypto, Outbox)"]
    Hub["Hub (WebSocket)"]
    Server["Server (REST API + Inbox)"]
    DB[(PostgreSQL)]
    MQ[[RabbitMQ<br/>live fan-out]]
    PushService[FCM / APNs]
    OAuth[VK / Google OAuth API]

    Client -->|HTTPS Auth/Keys| Server
    Client -->|HTTPS Send message| Server
    Client -->|HTTPS GET /inbox sync| Server
    Client -->|WebSocket receive live| Hub
    Client -->|Signed delivery receipt| Server
    Client -->|Request Token| OAuth
    Server -->|Verify Token| OAuth
    Server -->|Read/Write inbox| DB
    Server -->|Publish user.recipient| MQ
    MQ -->|Live fan-out| Hub
    Hub -->|Fetch Key config via JWKS| Server
    Server -->|Trigger Push| PushService
    PushService -->|Wake up / Notify| Client
```

### Components
*   **Angular PWA:** The user interface. Uses WebCrypto for E2E encryption and IndexedDB for local storage of messages and keys. Maintains an **outbox**: an outgoing message is held locally until the sender receives a cryptographically **signed delivery receipt** from the recipient, which makes the client tolerant of an unreliable relay without any blind retry loop.
*   **Server (Spring Boot):** The control plane **and the trusted owner of the message inbox**. Handles OAuth linking, validates identity, manages the public-key directory, accepts outgoing messages, holds them durably until a signed receipt arrives, publishes them to RabbitMQ for live delivery, exposes the `/inbox` sync API, and triggers push notifications. The Server is the only component trusted for delivery (never for content — payloads are E2E encrypted).
*   **Hub (Lightweight Spring Boot):** The **live delivery relay**. It holds the long-lived WebSocket connections of online users and forwards already-accepted, E2E-encrypted payloads from RabbitMQ to the recipient. It evaluates stateless JWTs (fetching the Server's public keys via the JWKS endpoint) only to authorize *which user's* live stream a connection may receive. It has **no database access** and holds no durable state — the delivery guarantee never depends on it. In Phase 1 the Hub runs in the trusted environment alongside the Server; it is nonetheless built as a blind, replaceable relay so that untrusted third-party ("volunteer") Hubs can be enabled later without a redesign (see [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md)).
*   **PostgreSQL:** Stores user accounts, OAuth linking, Signal pre-key bundles, and the **durable inbox** (cold tier) of accepted-but-not-yet-confirmed messages.
*   **RabbitMQ:** A **non-durable live fan-out bus**. It routes accepted payloads to whichever Hub a recipient is currently connected to. It is explicitly *not* a durability mechanism — losing a message in RabbitMQ is harmless because the Server retains the source of truth.

---

## 2. Communication Scenarios

### 2.1 Authentication & Identity (Token Validation Flow)

The client performs the OAuth login natively via third-party providers (VK/Google) to obtain an access token. The Server acts strictly as a token validator to confirm the user's identity and prevent spoofing before issuing an internal session.

```mermaid
sequenceDiagram
    participant User
    participant PWA as Angular PWA
    participant OAuth as VK / Google
    participant Server as Server (API)
    participant DB as PostgreSQL

    User->>PWA: Clicks Login (VK/Google)
    PWA->>OAuth: Request Token (Client-side SDK/Flow)
    OAuth-->>PWA: Access Token
    PWA->>Server: POST /api/auth/{provider}, token
    Server->>OAuth: Verify Token & Get Profile
    OAuth-->>Server: Token Valid + User ID
    Server->>DB: Find or create User mapping (Link providers)
    Server->>DB: Generate & Store Refresh Token
    Server-->>PWA: Return internal Access JWT & Refresh Token
```

### 2.2 Token Refresh Flow (Double Token Pattern)

For a detailed block diagram of the token refresh and authentication lifecycle, please refer to [algorithms/auth.md](algorithms/auth.md).

The architecture utilizes a **Double Token Pattern** to minimize database inquiries and reduce API latency:
1. **Stateless Access JWT**: Short-lived (e.g., 15 minutes). Both the Server and Hub verify the token cryptographically without executing a database query.
2. **Stateful Refresh Token**: Long-lived (e.g., 30 days) and stored securely in the PostgreSQL database.

The refresh backend is called at the every first start of app and upon or just before expiration of the short-lived Access JWT, the PWA silently submits the long-lived Refresh Token to obtain a new Access JWT. The server validates the Refresh Token against the database during this transaction, providing a mechanism for account restriction or revocation.


### 2.3 E2E Encryption & Key Exchange

Messages are protected end-to-end with the **Signal protocol** (X3DH + Double Ratchet). The server acts as a **pre-key directory**.

```mermaid
sequenceDiagram
    participant Alice as Alice PWA
    participant Server as Server (API)
    participant DB as PostgreSQL
    participant Bob as Bob PWA

    Note over Alice,Bob: Initial Setup
    Alice->>Alice: Generate Signal identity + pre-keys
    Alice->>Server: Upload Alice's pre-key bundle (PUT /keys)
    Server->>DB: Store Alice's bundle
    Bob->>Bob: Generate Signal identity + pre-keys
    Bob->>Server: Upload Bob's pre-key bundle (PUT /keys)
    Server->>DB: Store Bob's bundle

    Note over Alice,Bob: Opening a session
    Alice->>Server: Request Bob's pre-key bundle
    Server->>DB: Query (pop one one-time pre-key)
    DB-->>Server: Result
    Server-->>Alice: Return Bob's bundle
    Alice->>Alice: X3DH → Double Ratchet session
```

### 2.4 Message Sending & Receiving (Server-Owned Inbox)

For a detailed block diagram of the live fan-out topology, refer to [algorithms/rabbitmq-exchange.md](algorithms/rabbitmq-exchange.md).

The delivery model separates the **send path** (trusted, durable) from the **receive path** (untrusted, best-effort), so that an untrusted Hub can never cause permanent message loss and the sender never has to blindly retry.

**Send path (always through the Server):**
1. Alice encrypts the message through her **Double Ratchet** session with Bob (opening one from his pre-key bundle on first contact). The ratchet authenticates the message, so chat messages carry no separate signature.
2. Alice's PWA `POST`s it to the **Server** and keeps a copy in its local **outbox**.
3. The Server holds the message in its **hot tier** (in-memory pending map; see [3](#3-storage-strategy)) and **publishes** it to RabbitMQ with routing key `user.bob`. The Server returns an **`accepted`** response — Alice's send call is now complete (fire-and-forget; no client retry loop).

**Receive path (best-effort live, via whatever Hub Bob is on):**
1. RabbitMQ fans the payload out to whichever Hub currently holds Bob's binding; the Hub pushes it over the WebSocket.
2. Bob's device decrypts it and returns a **signed delivery receipt** (`delivered`) to the Server.
3. On the signed receipt, the Server **drops its retained copy** and relays the receipt to Alice, who clears her outbox. If both users are online this completes with **zero database writes**.

**If no signed receipt arrives within the hold window** (Bob is offline *or* a malicious Hub is withholding — the two are indistinguishable and need not be told apart), the Server performs a **single write** of the message to the durable **PostgreSQL inbox** (cold tier) and stops holding it in memory. Bob receives it later via live re-publish or via the `/inbox` sync API.

```mermaid
sequenceDiagram
    participant Alice as Alice PWA (Outbox)
    participant Server as Server (Inbox owner)
    participant Hot as Hot tier (in-memory)
    participant MQ as RabbitMQ (live fan-out)
    participant Hub as Hub (Bob's relay)
    participant Bob as Bob PWA
    participant DB as PostgreSQL (durable inbox)
    participant Push as FCM / APNs

    Alice->>Alice: Encrypt (Bob pubkey) + sign (Alice key)
    Alice->>Server: POST /api/messages (store in local outbox)
    Server->>Hot: Hold copy
    Server-->>Alice: accepted (send complete)
    Server->>MQ: Publish routing key user.bob
    Server->>Push: Trigger push (independent tripwire)

    alt Bob online & Hub honest
        MQ-->>Hub: Live fan-out
        Hub-->>Bob: Deliver ciphertext (WS)
        Bob->>Bob: Decrypt
        Bob->>Server: Signed delivery receipt (delivered)
        Server->>Hot: Drop retained copy (0 DB writes)
        Server-->>Alice: Relay signed receipt -> clear outbox
    else No signed receipt within hold window (offline OR malicious drop)
        Server->>DB: Single write to durable inbox (ciphertext)
        Server->>Hot: Evict from memory
        Note over Bob,Server: Delivered later via re-publish or GET /inbox sync
    end
```

### 2.5 Delivery Guarantee (Server-Retained Copy + Signed Receipt)

The delivery guarantee does **not** rest on RabbitMQ (a relay may consume a message without ever forwarding it, and a recipient may simply be offline). Instead it rests on the **Server's retained copy plus an end-to-end signed receipt**:

*   The Server **publishes `user.bob` once** as a best-effort live attempt and keeps the copy (hot tier, then DB). If a **signed** `delivered` receipt arrives, the Server drops the copy. If none arrives within the hold window, it does **not** re-publish — the copy simply flushes to the DB and waits.
*   During the in-memory hold window the **sender's outbox is the durable backup**, so the hot tier is allowed to be non-durable.
*   **Backstop (the redelivery mechanism):** whenever Bob's app (re)connects it calls `GET /api/inbox` directly on the Server to pull anything it missed live. This HTTP sync path is independent of any Hub and returns the union of the hot and cold tiers, so a message is always eventually delivered even if the live attempt was missed.
*   **Undecryptable backstop (negative ack):** if Bob receives the copy but **cannot decrypt** it — it was sealed to a stale identity / pre-key after he logged in on a new device — he returns a signed **`undecryptable`** receipt. The Server **drops the retained copy** (no one can decrypt it, so retrying delivery is pointless) and relays the NACK to Alice, who re-fetches Bob's current bundle and **resends once** under a fresh session. This prevents an undecryptable message from looping forever in the inbox (it is never acknowledged by a normal `delivered`). See [MESSAGE_SECURITY.md §2.1](MESSAGE_SECURITY.md#21-key-lifecycle-logout--single-active-device-policy).


> Receipts are **signed by the recipient's identity key** and verified against the key directory. In Phase 1 (trusted Hubs) an unsigned receipt would functionally suffice, but the signed form is a deliberate forward-compatible contract: it is what lets untrusted volunteer Hubs be enabled later without changing the wire format. Active *detection* of a misbehaving Hub (inbox state polling, automatic Hub-switching) is deferred — see [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md).

### 2.6 Send-Side Reconciliation (Outbox Resync)

> Beyond Phase 1: the resync case of accepted messages is retired once the hot tier moves to a persistent Redis store, which survives restarts (see [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md)).

On app start the client reconciles its outbox of unconfirmed messages. Resends are idempotent — every copy keeps its original `messageId`, so the Server upserts and the recipient de-duplicates; a resend never creates a duplicate. Each unconfirmed message falls into one of two cases:

*   **Never accepted (`pending`)** — the initial `POST` never succeeded (offline / error), so the Server does not have the message. It is **re-sent**. If it still cannot be accepted it is marked **`failed`** for the user to resend manually.
*   **Accepted, but the Server restarted (`accepted`)** — a freshly `accepted` message lives only in the hot tier until the hold-window flush, so a Server restart within that window can lose a not-yet-delivered copy. The trigger is `serverStartedAt`, returned on every `accepted` and `/inbox` response: if it changed since the message was sent, the copy may be gone, so the message is **re-pushed once** (`retryCount = 1`). The Server already had it, so this case is never marked `failed`.

A **group** message is N independent 1:1 copies sharing one `messageId`; if any copy is still unconfirmed (sending fails) it is **re-fanned to the current roster** ([§2.7](#27-group-messaging-client-side-11-fan-out)). Members who already received their copy de-duplicate it; if any copy still fails, the message is marked **`failed`**.

```mermaid
flowchart TD
    Start([App start]) --> Inbox["GET /inbox → save serverStartedAt"]
    Inbox --> Each["For each unconfirmed message"]
    Each --> Kind{"Status?"}
    Kind -- "pending (never accepted)" --> Resend["Re-send"]
    Kind -- "accepted + serverStartedAt changed" --> Repush["Re-push once (retryCount = 1)"]
    Resend --> Ok{"Accepted?"}
    Ok -- Yes --> Done["Confirmed"]
    Ok -- No --> Failed["Mark failed → user resends manually"]
```

### 2.7 Group Messaging (Client-Side 1:1 Fan-Out)

Phase 1 supports **group conversations** by reusing the 1:1 path verbatim: a group message is sent as **N independent 1:1 messages**, one per other member, each sent through that member's own **Double Ratchet** session exactly like a direct message (see [MESSAGE_SECURITY.md §6](MESSAGE_SECURITY.md#6-group-encryption-client-side-11-fan-out)). `EncryptedMessage` carries an optional `groupId` ([models.json](models.json)) so the recipient threads each copy into the right group conversation; it is absent for 1:1.

**The Server owns the roster only.** It stores group **membership** (`groups` + `group_members`) and never any key material — there is none to hold. The client reads the roster (`GET /groups/{id}`) to know whom to fan out to.

**Sending — the client fans out.** To send to a group, the client resolves the roster, and for **each** other member it ratchet-encrypts an independent 1:1 payload through that member's session and `POST`s it to `/messages` with the same `messageId`, the member's `recipientId`, and the `groupId`. The Server treats every copy as an ordinary 1:1 message — same `user.<memberId>` routing, two-tier inbox, signed-receipt, and `GET /inbox` machinery. Group delivery is literally N 1:1 deliveries, each cleared by **that member's** own signed receipt. No server fan-out, no broker group topology, no group routing key.

**New devices need no special handling.** Because every copy goes through the member's *current* session at send time, a member who logged in on a new device simply receives subsequent messages under their new identity. A copy that fails to decrypt (raced a key change mid-rotation) is repaired by the existing **undecryptable negative-ack** path ([MESSAGE_SECURITY.md §2.1](MESSAGE_SECURITY.md#21-key-lifecycle-logout--single-active-device-policy)), exactly as for 1:1.

**Authorization.** The group **owner** is the sole party permitted to change the roster — add or remove other members (`PATCH /groups/{id}/members`). Any member may **send** and may **leave** (`DELETE /groups/{id}/members/me`). Forward/backward secrecy beyond "stop fanning out to a removed member" is **not** provided in this model; a richer scheme is deferred (see [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md)).

```mermaid
sequenceDiagram
    participant Sender as Sender PWA
    participant Server as Server (roster only)
    participant MQ as RabbitMQ (live fan-out)
    participant M1 as Member 1
    participant M2 as Member 2

    Note over Sender,M2: Group send - client encrypts once per member
    Sender->>Server: GET /groups/{id} (roster)
    Server-->>Sender: members [M1, M2]
    Sender->>Sender: Encrypt+sign copy for M1, copy for M2
    Sender->>Server: POST /messages {messageId, recipientId: M1, groupId, payload_M1, sig}
    Sender->>Server: POST /messages {messageId, recipientId: M2, groupId, payload_M2, sig}
    Server->>MQ: Publish user.M1 (one stored copy)
    Server->>MQ: Publish user.M2 (one stored copy)
    MQ-->>M1: messageReceived
    MQ-->>M2: messageReceived
    M1->>Server: POST /receipts (signed delivery)
    M2->>Server: POST /receipts (signed delivery)
```


## 3. Storage Strategy

*   **Client (Angular):** **IndexedDB** is used for storing the user's Signal keys and per-contact ratchet session state, cached identity keys of contacts, decrypted chat history, and the **outbox** of unconfirmed outgoing messages.
*   **Server — two-tier inbox:** The Server owns the message inbox as the source of truth, split into a hot and a cold tier to keep database operations low:
    *   **Hot tier (in-memory pending map):** holds messages only during the short post-accept hold window, keyed by message id. It is **discardable** — durability during the window is provided by the **sender's outbox**, so the hot tier is plain **JVM heap** in the single Server instance. The hold window length `N` is a tunable knob that trades memory for database writes: messages confirmed by a signed receipt within `N` cost **zero** DB writes; lowering `N` reduces memory at the cost of writing sooner. (Sharing this tier across multiple Server instances via Redis is a deferred concern — see [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md).)
    *   **Cold tier (PostgreSQL `inbox`):** the durable store. A message is written here **once**, only if it is not confirmed within the hold window. Rows are deleted strictly upon a verified **signed delivery receipt**. PostgreSQL is required (not a queue) because the inbox needs random access by message id, repeated re-publish of the same message, and `GET /inbox` reads — none of which a FIFO queue provides.
*   **Reading the inbox (`GET /inbox`):** the Server returns the **union of the hot and cold tiers**, in arrival order; the client de-duplicates by message id. Because the flush from hot to cold is *insert-into-DB then remove-from-memory*, a message in transit is present in **both** tiers (a harmless duplicate) and never in **neither** (no gap).
*   **PostgreSQL (relational):** also stores Accounts, OAuth identities, the public-key directory, and Web Push subscriptions.
*   **Group state (PostgreSQL):** the Server persists only the group **roster** (`groups` + `group_members`); it holds no key material (see [§2.7](#27-group-messaging-client-side-11-fan-out)). A group message reuses the two-tier `inbox` as N independent 1:1 copies, each additionally carrying its `groupId` for recipient-side threading.

---

## 4. Deployment Model (Phase 1)

Phase 1 runs a **single Server instance**, a single PostgreSQL database, a single RabbitMQ broker, and one or more **Hubs** in the trusted environment. The Server and Hub scale differently and are deliberately split:

1. **Server (REST HTTP traffic):** A **single instance** handles auth, message **send**, `/inbox` sync, and signed-receipt intake. Its per-message work is just *accept + publish*, so a single vertically-scaled instance handles substantial throughput. (Running multiple Server instances requires a shared hot tier and is a deferred concern — see [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md).)
2. **Hub (WebSocket traffic):** Hubs maintain the long-lived connections used **only for live delivery to recipients** (clients never send through a Hub). The expensive resource — holding many idle connections — lives here, and **Hubs scale horizontally independently of the single Server**. The Load Balancer terminates SSL and distributes WebSocket connections (e.g. "Least Connections"); sticky sessions are NOT required because RabbitMQ is the unified fan-out backplane.

```mermaid
flowchart TD
    Clients[Clients PWA] --> LB["Load Balancer"]

    LB -->|HTTP REST<br/>auth / send / inbox| S["Server (single instance)"]

    LB -->|WebSocket Least Connections<br/>receive live| H1["Hub Node 1"]
    LB -->|WebSocket Least Connections<br/>receive live| H2["Hub Node 2"]
    LB -->|WebSocket Least Connections<br/>receive live| HN["Hub Node N"]

    S --> DB[(PostgreSQL)]
    DB --> S

    S -->|Publish user.recipient| MQ[[RabbitMQ]]
    MQ -->|Live fan-out| H1
    MQ -->|Live fan-out| H2
    MQ -->|Live fan-out| HN
    H1 -.->|JWKS| S
    H2 -.->|JWKS| S
    HN -.->|JWKS| S
```

*   **Routing:** To message Charlie, Bob `POST`s to the **Server**, which publishes `user.charlie` to RabbitMQ; whichever Hub Charlie is connected to consumes it and pushes it to Charlie. Hubs never talk to each other and never carry the send path.
*   **Resilience:** If a Hub goes down, the recipient's WebSocket disconnects and the app silently reconnects to another Hub; its `user.<id>` binding moves with it, and any messages missed while disconnected are pulled via `GET /api/inbox`. Durability never depends on a Hub.

> **Beyond Phase 1.** Offloading connection-holding to untrusted third-party **volunteer Hubs**, and scaling the Server horizontally with **Redis**, are described in [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md). Both are designed to drop in without changing the Phase 1 client wire format or send path.
