# fourletters — Message Security & Client Data Storage

This document describes the **end-to-end (E2E) cryptography** and the **client-side at-rest storage** model: what keys the PWA creates, how the Server acts as a public-key directory, how messages are encrypted/signed/verified, and how the client stores and loads messages from IndexedDB without leaking plaintext at rest.

It complements the server-side flow in [ARCHITECTURE.md §2.3–§2.6](ARCHITECTURE.md#23-e2e-encryption--key-exchange) and the message lifecycle in [algorithms/messages-lifecycle.md](algorithms/messages-lifecycle.md). The Server and Hub **never see plaintext** — payloads are encrypted on the sender's device and decrypted only on the recipient's.

> **Scope — Phase 1.** Single Server instance, trusted Hubs. The crypto contract here is the same one that makes untrusted volunteer Hubs safe later (see [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md)).

---

## 1. Client-Side Storage (IndexedDB)

The PWA stores everything locally in **IndexedDB** via [WebCrypto](https://developer.mozilla.org/docs/Web/API/Web_Crypto_API). Plaintext is **never** written to disk: message bodies are stored as ciphertext and decrypted on demand into a volatile in-memory cache.

### 1.1 Per-user databases (multiple users, same browser)

A single browser profile may be shared by several users (e.g. a family device). Each user gets an **isolated IndexedDB database**, named by their Server user id:

```
fourletters:{userId}
```

A small, unencrypted **registry** database (`fourletters:registry`) holds only the list of known `userId`s and display metadata (name, avatar) so the login screen can offer an account picker. It contains **no keys and no message content**.

```mermaid
flowchart TD
    Reg[("fourletters:registry<br/>(userId list, display names)")]
    DBA[("fourletters:{userA}<br/>keys · contacts · conversations · messages")]
    DBB[("fourletters:{userB}<br/>keys · contacts · conversations · messages")]
    Reg -.lists.-> DBA
    Reg -.lists.-> DBB
```

The **active user** is whichever session is currently authenticated (the access JWT's subject). The app opens only the database matching the authenticated `userId`, so users see separate histories and keys (see the at-rest limitation in [§1.2](#12-at-rest-encryption-of-the-per-user-db)).

Each per-user database has these object stores:

| Object store | Holds | At rest |
| --- | --- | --- |
| `identity` | The user's own key pairs (see [§2](#2-keys-created-at-first-authentication)) | Non-extractable `CryptoKey` handles |
| `contacts` | Cached **public** keys of conversation partners | Plaintext (public keys are not secret) |
| `conversations` | One record per conversation: partner id, last-message preview, unread count, ordering timestamp | **AES-GCM ciphertext** (preview is plaintext-derived) |
| `messages` | Chat history across all conversations, each tagged with its conversation and a delivery `status` | **AES-GCM ciphertext** |
| `meta` | `serverStartedAt`, sync cursors, the DB master key | Mixed (key material is a non-extractable handle) |

There is **no separate outbox store**: an outgoing message is an ordinary `messages` record whose `status` is `pending` or `accepted` until a signed receipt advances it to `delivered`/`read`. Resync and the “unconfirmed outbox” are simply a query over `messages` by `status`.

### 1.2 At-rest encryption of the per-user DB

The at-rest key is a **local, non-extractable AES-GCM master key**, not a server-issued secret — so history decrypts fully **offline**. At first run the client generates a **256-bit AES-GCM master key** with WebCrypto and stores the **`CryptoKey` object itself** in the `meta` store:

- Created with `extractable: false`, so script (including any XSS payload) **cannot read the raw bytes** — it can only *use* the handle to encrypt/decrypt.
- Persisted in IndexedDB and available with **no network**.
- Each `messages` and `conversations` record is encrypted with this key using a fresh random IV (AES-GCM).

```mermaid
flowchart TD
    Gen["First run: generate AES-GCM master key<br/>(extractable = false)"]
    Store["Store CryptoKey handle in IndexedDB (meta)"]
    Use["Encrypt/decrypt message & conversation records<br/>AES-GCM + random IV"]
    Gen --> Store --> Use
```

> **Known limitation — no cryptographic isolation between users of the same browser profile.** IndexedDB is partitioned per **origin**, not per account-picker user, and a non-extractable `CryptoKey` handle can be *used* by any script on the origin. So the per-user database gives **logical** separation (separate histories and keys, the app opens only the active user's DB) but not a cryptographic barrier: code running on the origin could open another local user's DB and use its master key. The data is still **never plaintext at rest**, **not readable by other origins or websites**, and the raw key bytes are **not exfiltratable** (`extractable: false`). Separate **OS user accounts** *do* provide real isolation — each OS account has its own profile storage, protected by file-system permissions — so the gap applies only to people sharing **one** OS account (or merely separate browser profiles, which are not a security boundary). Binding the master key to a per-user secret so it is usable by **only one** user is deferred — see [FUTURE_EXTENSIONS.md](FUTURE_EXTENSIONS.md#8-per-user-at-rest-key-binding).

Decrypted plaintext lives **only in memory** (a bounded in-RAM cache; see [§5](#5-loading-messages-in-the-gui)) and is dropped on **logout or lock**; the at-rest store stays encrypted. Removing an account from the device deletes its `fourletters:{userId}` database and its registry entry.

---

## 2. Keys Created at First Authentication

On the user's **first** authenticated session on a device, the PWA generates **two distinct key pairs** with WebCrypto (separate keys for separate purposes — never reuse a signing key for encryption):

| Key pair | Algorithm | Purpose | Stored | Published |
| --- | --- | --- | --- | --- |
| **Identity / signing key** | ECDSA P-256 | Sign outgoing messages and delivery/read receipts; verify peers' signatures | Private: non-extractable in `identity`. | Public key → directory |
| **Encryption key** | ECDH P-256 | Derive a shared secret to encrypt/decrypt message payloads | Private: non-extractable in `identity`. | Public key → directory |
| **DB master key** | AES-GCM 256 | At-rest encryption of local stores ([§1.2](#12-encrypting-the-per-user-db--and-staying-readable-offline)) | Non-extractable in `meta`. | **Never** |

Both **private** keys are generated `extractable: false` and stored as `CryptoKey` handles, so they cannot be exfiltrated by script. Both **public** keys are uploaded to the Server's directory (see [§3](#3-server-as-public-key-directory)) so other users can message and verify this user.

### 2.1 Key lifecycle, logout & single-active-device policy

Phase 1 enforces **one active device per user**. The key pairs are generated **only when absent** — the client never regenerates on a login where keys already exist locally. This is what makes the two logout paths behave differently:

| Event | Identity / encryption keys | Messages & conversations | Directory |
| --- | --- | --- | --- |
| **Explicit logout** (user clicks logout) | **Kept** | Kept | Unchanged |
| **Re-login on the same device** (keys present) | Reused | Kept | Unchanged — no upload |
| **First login on a new device / keys absent** | Generated | — | New public keys uploaded (`PUT /keys`), overwriting the previous ones |
| **Forced logout — session revoked** (another device took over) | **Deleted** | **Kept** | Unchanged until next login |

Because a **fresh login revokes the user's other sessions** (see [auth.md](algorithms/auth.md)), signing in on Device B makes Device A's session revoked. On Device A's next refresh the Server reports the session as **revoked**; the client then **deletes only the identity/encryption key pairs** (never the messages, never the DB master key) and returns to the login screen. The user's **local history stays readable** (it is encrypted with the independent DB master key); only the ability to decrypt *new* messages addressed to the old key is gone — those now target Device B's freshly uploaded key.

When the revoked Device A logs in again, it finds **no key pair**, regenerates one, and uploads it (`PUT /keys`) — which in turn revokes Device B. This “latest login wins” ping-pong is the intended single-device UX (one phone/one session, WhatsApp-style).

**What a new-device login does, end to end:**

1. OAuth succeeds → access token issued → the user's **other session is revoked** ([auth.md](algorithms/auth.md)).
2. The device finds **no local key pair** and generates a fresh identity + encryption pair.
3. It publishes the new public keys with `PUT /keys`, **overwriting** the directory entry.
4. New messages now target the new key; the new device has **no history** and cannot read anything sent to the old key (accepted trade-off — see below).
5. **On every contact's device,** the next interaction reconciles the changed key and shows *"X's security code changed"* ([§3.1](#31-key-change-detection-security-code-changed)) — auto-accepted, non-blocking.
6. **Groups:** nothing special. A group message is sent as one independent 1:1 copy per member sealed to that member's *current* directory key ([ARCHITECTURE.md §2.7](ARCHITECTURE.md#27-group-messaging-client-side-11-fan-out)), so the new device simply receives subsequent group messages under its new key like any 1:1. As with 1:1, history that lived only on the old device is not carried over.

> **In-flight messages self-heal via a negative ack.** A message already accepted by the Server but encrypted to the *old* key cannot be read by the new device — its signature verifies but the ECDH/AES-GCM decrypt fails. The new device returns a signed **`undecryptable`** receipt, which makes the Server **drop the retained copy** and relay a NACK to the sender; the sender re-fetches the new key (re-pinning it, [§3.1](#31-key-change-detection-security-code-changed)) and **resends once** under the fresh key. So such a message is *recovered*, not lost — see [ARCHITECTURE.md §2.5](ARCHITECTURE.md#25-delivery-guarantee-server-retained-copy--signed-receipt) and [messages-lifecycle.md](algorithms/messages-lifecycle.md#undecryptable--the-negative-ack). What is genuinely **lost** is only history that lived solely on the old device (never re-sent) — spanning one identity across devices is deferred to [FUTURE_EXTENSIONS.md §9](FUTURE_EXTENSIONS.md#9-multi-device-key-handling).


---

## 3. Server as Public-Key Directory

The Server stores and serves public keys only — it is a **directory**, not a key escrow. It never holds any private key. Public keys are not secret; their integrity is what matters (so peers encrypt/verify against the right key).

**Storage (PostgreSQL).** A `public_keys` table keyed by `user_id` holds the signing and encryption public keys (Base64 SPKI) plus timestamps.

**Endpoints** (tag `Keys`):

| Endpoint | Auth | Purpose |
| --- | --- | --- |
| `PUT /keys` | Bearer JWT | Upload/replace the caller's own public keys (`signingPublicKey`, `encryptionPublicKey`). `userId` is taken from the session, never the body. |
| `GET /keys/{userId}` | Bearer JWT | Fetch a user's current public keys to message/verify them. |
| `GET /keys?ids=…` | Bearer JWT | Batch fetch for multiple contacts. |

The client **caches** fetched public keys in its `contacts` store and refreshes on signature/decryption failure (a key may have rotated). Trust-on-first-use in Phase 1; the **key-change detection** below ([§3.1](#31-key-change-detection-security-code-changed)) is the hardening that makes a swapped key *visible*.

> Distinct from the **JWKS** endpoint, which publishes the **Server's** JWT-signing keys for the Hub to validate access tokens — unrelated to user E2E keys.

### 3.1 Key-change detection ("security code changed")

The Server writes the directory, so a malicious/compromised Server *can* publish a fake key. E2EE does not prevent that — it makes it **detectable on the clients**. Each cached contact is **pinned**: alongside its public keys the `contacts` record stores a **fingerprint** `SHA-256(signingPub ‖ encryptionPub)`. Whenever the client newly learns a contact's directory key, it compares the fresh fingerprint to the pinned one.

| First time seen (no pin) | Trust-on-first-use: accept and pin silently. No banner. |
| --- | --- |
| Fingerprint **matches** pin | Normal path, nothing shown. |
| Fingerprint **differs** | **Re-pin** the new key (auto-accept) **and** raise a non-blocking *"X's security code changed"* banner in that conversation (a `system` message). |

Detection is **event-driven — no polling**. The pin is re-checked only on moments that already happen:

- **Inbound signature fails against the pinned key** — the primary detector. `verifySender` re-fetches the contact's key **once**; if the *fresh directory key* verifies the message it is a legitimate rotation (re-pin + banner), otherwise it is a genuine bad signature (drop, do **not** re-pin). This same re-fetch fixes stale 1:1 keys after a peer's device switch.
- **Server "key changed" nudge** over the existing Hub channel (carries only `{userId}`, never key material) — the client drops the pin so the *next* `getContactKeys` reconciles. The Server can *announce* a change but cannot forge the key undetected, because the client still re-derives and pins the actual directory key.

Groups reuse the identical path per member (a member's `verifySender`), so a member's device switch surfaces as *"Y's security code changed"* in the group and re-pins that member's key for subsequent per-member sends.

> **Level 1 (notice), by design.** The banner is informational and never blocks sending — a new-device login *legitimately* changes the code (see [§2.1](#21-key-lifecycle-logout--single-active-device-policy)). It converts a *silent* server key-swap into a *visible* one. True defeat of a malicious Server needs an **out-of-band** safety-number comparison (Level 2), which single-active-device cannot automate; it is offered only as an optional manual verification.


---

## 4. Signing, Verifying & Decrypting

### Sending (on Alice's device)

1. **Encrypt.** Fetch Bob's **encryption** public key (ECDH P-256) from the directory/cache. Generate an **ephemeral ECDH key pair**, derive a shared secret `ECDH(ephemeralPriv, bobEncPub)`, run it through HKDF to an AES-GCM key, and encrypt the plaintext with a random IV. The wire `payload` (Base64) carries the ephemeral public key + IV + ciphertext.
2. **Sign.** Produce a detached **ECDSA** signature over the `payload` with Alice's **identity private key**. This is `EncryptedMessage.signature` ([models.json](models.json)).
3. **Send.** `POST /messages` to the Server (which stamps `senderId` from the session) and keep the record in `messages` with `status = pending` until the `accepted` response, then `accepted`.

### Receiving (on Bob's device)

1. **Verify signature.** Fetch Alice's **identity** public key; verify the ECDSA signature over `payload`. Reject on failure (forged/altered by a relay).
2. **Decrypt.** Read the ephemeral public key from `payload`, derive `ECDH(bobEncPriv, ephemeralPub)` → HKDF → AES-GCM key, and decrypt with the carried IV.
3. **Acknowledge.** Build a `DeliveryReceipt`: sign `(messageId, type, originalSenderId)` with Bob's **identity private key** and `POST /receipts`. The Server relays this `signature` unaltered to Alice, who verifies it against Bob's identity public key — an E2E, relay-independent delivery/read proof (see [algorithms/messages-lifecycle.md](algorithms/messages-lifecycle.md)).

```mermaid
sequenceDiagram
    participant A as Alice (sender)
    participant Dir as Key directory (Server)
    participant B as Bob (recipient)

    A->>Dir: GET Bob's encryption pubkey
    A->>A: ephemeral ECDH + HKDF → AES-GCM encrypt
    A->>A: ECDSA sign(payload) with identity key
    A-->>B: EncryptedMessage {payload, signature} (via Server/Hub)
    B->>Dir: GET Alice's identity pubkey
    B->>B: verify signature → reject if bad
    B->>B: ECDH(bobEncPriv, ephemeralPub) → HKDF → AES-GCM decrypt
    B->>B: ECDSA sign(messageId,type,originalSenderId)
    B-->>A: DeliveryReceipt.signature (relayed by Server) → Alice verifies
```

**Why two operations.** Encryption gives **confidentiality** (only Bob reads it); the signature gives **authenticity/integrity** (it really came from Alice, unaltered) and is what lets the receipt path stay trustworthy even over an untrusted Hub.

---

## 5. Loading Messages in the GUI

Messages are stored **encrypted** and decrypted **lazily**, never eagerly for the whole history. A bounded in-memory cache holds recently viewed plaintext and is cleared on logout/lock.

**Opening a conversation (read path):**
1. Read the **encrypted** records for that conversation from `messages` (paged — only the visible window + a small look-ahead).
2. For each, check the in-memory plaintext cache; on a miss, **AES-GCM decrypt** with the DB master key and insert into the cache (bounded LRU).
3. Render plaintext from the cache. Scrolling pages in older records the same way.

**Incoming message (live or via `GET /inbox`):**
1. **Verify** the sender's signature; **decrypt** the payload ([§4](#4-signing-verifying--decrypting)).
2. **Re-encrypt** with the local DB master key and persist to `messages` (de-dupe by `messageId`).
3. Update the conversation list; if that conversation is open, decrypt-on-demand into the cache and render.
4. Send the signed `delivered` (and later `read`) receipt.

```mermaid
flowchart TD
    Open[Open conversation] --> Page[Read encrypted page from IndexedDB]
    Page --> Cache{In memory cache?}
    Cache -- Hit --> Render[Render plaintext]
    Cache -- Miss --> Dec[AES-GCM decrypt with DB master key] --> Put[Put in bounded LRU] --> Render

    In[Incoming message live or inbox] --> Ver[Verify signature] --> DecIn[Decrypt payload]
    DecIn --> Reenc[Re-encrypt with DB master key] --> Save[Persist to messages] --> Ack[Send signed receipt]
```

**Properties:**
- **At rest:** only ciphertext and public keys touch disk; private and master keys are non-extractable handles.
- **In memory:** plaintext exists only transiently and is dropped on logout/lock.
- **Offline:** history decrypts with the local master key, no network needed.
- **Lazy:** decryption cost is paid per viewed message, not for the whole archive on load.

---

## 6. Group Encryption (Client-Side 1:1 Fan-Out)

A group message is **not** a distinct cryptographic primitive: it is sent as **N independent 1:1 messages**, one per other member, each encrypted with the same per-message ephemeral-ECDH envelope as a direct message ([§4](#4-signing-verifying--decrypting)). There is **no group key, no epoch, and no rotation**. The server-side flow is in [ARCHITECTURE.md §2.7](ARCHITECTURE.md#27-group-messaging-client-side-11-fan-out); this section is the client crypto.

### 6.1 Sending

1. Read the group **roster** (`GET /groups/{id}`) to get the member list; drop the sender.
2. For **each** remaining member, fetch their **encryption** public key from the directory (cached in `contacts`) and build a 1:1 payload exactly as in [§4](#4-signing-verifying--decrypting): ephemeral ECDH → HKDF → AES-GCM, then **sign** the payload with the sender's **identity** key.
3. `POST /messages` once per member with the **same** `messageId`, that member's `recipientId`, the `groupId`, the per-member `payload`, and the `signature`.

Each copy is an ordinary 1:1 message to the Server; the shared `messageId` lets the sender track the group send as one local message, and `groupId` lets each recipient thread it.

### 6.2 Receiving

Identical to a 1:1 message: **verify** the sender's identity signature, **AES-GCM-decrypt** the payload with the recipient's encryption private key, then re-encrypt with the local DB master key and persist as an ordinary `messages` record ([§5](#5-loading-messages-in-the-gui)). The `groupId` selects the group conversation to thread it into.

### 6.3 Membership & new devices

- **Roster** is owned by the Server (`groups` + `group_members`); the owner adds/removes members (`PATCH /members`), any member may leave (`DELETE /members/me`). Removing a member simply stops future fan-out to them.
- **New device:** no special handling. Because every copy is sealed to each member's *current* directory key at send time, a member on a new device receives subsequent group messages under its new key like any 1:1. A copy that raced a key change and fails to decrypt is repaired by the **`undecryptable` negative-ack** ([§2.1](#21-key-lifecycle-logout--single-active-device-policy)).

> **Security trade-off.** This model gives the same per-message confidentiality and per-sender authenticity as 1:1, and "a removed member stops receiving new messages." It does **not** provide cryptographic forward/backward secrecy across membership changes. A richer sender-key / MLS scheme that adds those guarantees is deferred — see [FUTURE_EXTENSIONS.md §10](FUTURE_EXTENSIONS.md#10-group-sender-keys--rotation). Cost scales as O(N) ciphertexts per message, acceptable for the small groups Phase 1 targets.

