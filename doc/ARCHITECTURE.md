# fourletters Architecture

This document outlines the architectural components and communication patterns for **fourletters**, a simple, reliable, end-to-end (E2E) encrypted PWA messenger.

## 1. Component Overview

The system consists of a frontend Progressive Web App (PWA), a Server for authentication and state, lightweight Hubs for WebSocket routing, a PostgreSQL relational database, and RabbitMQ for reliable asynchronous message queuing.

```mermaid
flowchart TD
    Client["Angular PWA<br/>(IndexedDB, WebCrypto)"]
    Hub["Hub (WebSocket)"]
    Server["Server (REST API)"]
    DB[(PostgreSQL)]
    MQ[[RabbitMQ]]
    PushService[FCM / APNs]
    OAuth[VK / Google OAuth API]

    Client -->|HTTPS Auth/Keys| Server
    Client -->|WebSocket| Hub
    Client -->|Request Token| OAuth
    Server -->|Verify Token| OAuth
    Server -->|Read/Write| DB
    Hub -->|Pub/Sub| MQ
    MQ -->|Pub/Sub| Hub
    Server -->|Consume DLQ| MQ
    MQ -->|Consume DLQ| Server
    Server -->|Trigger Push| PushService
    PushService -->|Wake up / Notify| Client
```

### Components
*   **Angular PWA:** The user interface. Uses WebCrypto for E2E encryption and IndexedDB for local storage of messages and keys.
*   **Server (Spring Boot):** The control plane. Handles OAuth linking, validates identity, manages public keys, stores offline messages (store-and-forward), and triggers push notifications.
*   **Hub (Lightweight Spring Boot):** The data plane. A blind proxy that evaluates stateless JWTs (using the Server's public key) to authorize connections. Routes E2E encrypted WebSocket payloads directly into RabbitMQ. Has no database access, which minimizes resource consumption and attack surface.
*   **PostgreSQL:** Stores user accounts, OAuth linking, Public Keys, and acts as the persistent store for the "Store-and-Forward" offline message mechanism.
*   **RabbitMQ:** Message broker for resilient, asynchronous internal message delivery and buffering.

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
1. **Stateless Access JWT**: Short-lived (e.g., 15 minutes). The server verifies the token cryptographically without executing a database query.
2. **Stateful Refresh Token**: Long-lived (e.g., 30 days) and stored securely in the PostgreSQL database.

The refresh backend is called at the every first start of app and upon or just before expiration of the short-lived Access JWT, the PWA silently submits the long-lived Refresh Token to obtain a new Access JWT. The server validates the Refresh Token against the database during this transaction, providing a mechanism for account restriction or revocation.


### 2.3 E2E Encryption & Key Exchange

Messages are encrypted on the client side. The server acts as a Public Key directory.

```mermaid
sequenceDiagram
    participant Alice as Alice PWA
    participant Server as Server (API)
    participant DB as PostgreSQL
    participant Bob as Bob PWA

    Note over Alice,Bob: Initial Setup
    Alice->>Alice: Generate WebCrypto KeyPair
    Alice->>Server: Upload Alice's Public Key
    Server->>DB: Store Alice's Public Key
    Bob->>Bob: Generate WebCrypto KeyPair
    Bob->>Server: Upload Bob's Public Key
    Server->>DB: Store Bob's Public Key

    Note over Alice,Bob: Exchanging Keys
    Alice->>Server: Request Bob's Public Key
    Server->>DB: Query
    DB-->>Server: Result
    Server-->>Alice: Return Bob's Public Key
```

### 2.4 Message Sending & Receiving (Store-and-Forward)

To guarantee message delivery across unreliable network conditions while minimizing database writes, the system implements a **Holding Queue Pattern** utilizing RabbitMQ's Alternate Exchange, TTL, and Dead Letter Queue (DLQ) mechanics. When a receiving client is offline, a push notification is triggered instantly, but the encrypted payload is held temporarily in RabbitMQ for 30 seconds. It is only persisted to the database if the user fails to open the app within that grace period.

```mermaid
sequenceDiagram
    participant Alice as Alice PWA
    participant NodeA as Core/Volunteer Hub A
    participant Core as Server (Worker)
    participant MQ as Main RabbitMQ
    participant Push as FCM / APNs
    participant DB as PostgreSQL
    participant NodeB as Core/Volunteer Hub B
    participant Bob as Bob PWA

    Alice->>Alice: Encrypt message with Bob's Public Key
    Alice->>NodeA: Send Encrypted Payload
    NodeA->>MQ: Publish message to Topic Exchange (Routing Key: `user.bob`)

    alt Bob is Online (Connected to Node B)
        MQ-->>NodeB: Queue consumes from Topic
        NodeB-->>Bob: Deliver Encrypted Payload (via WS)
        Bob->>Bob: Decrypt message with Private Key
        Bob->>NodeB: Send ACK (Message ID)
    else Bob is Offline (Queue has no active consumers)
        MQ-->>Core: Alternate Exchange routes unread message to Core immediately
        Core->>Push: INSTANT: Send Push Notification Payload
        Core->>MQ: Route to Holding Queue (TTL: 30s)

        alt Bob wakes up < 30s
            Bob->>NodeB: App Opens, connects WS
            NodeB->>MQ: Consume from Holding Queue
            NodeB-->>Bob: Deliver Encrypted Payload (0 DB writes!)
            Bob->>Bob: Decrypt message
            Bob->>NodeB: Send ACK (Message ID)
            NodeB->>MQ: Auto-acknowledge & remove from Queue
        else Bob stays offline > 30s
            Note over MQ: Message reaches 30s TTL in Holding Queue
            MQ-->>Core: Message drops to Dead Letter Queue (DLQ)
            Core->>DB: Store encrypted message in PostgreSQL (Store-and-Forward)
        end
    end

    Note over Bob: Much later, Bob opens the app
    Bob->>NodeB: App Opens, connects WS
    NodeB->>Core: HTTP GET /api/messages/pending (Fetch via Core)
    Core->>DB: Query Database
    DB-->>Core: Return result
    Core-->>NodeB: Return pending messages
    NodeB-->>Bob: Deliver pending messages
    Bob->>Bob: Decrypt messages with Private Key
    Bob->>NodeB: Send ACK (Message IDs)
    NodeB->>Core: HTTP DELETE /api/messages (Clear Store)
    Core->>DB: Delete from PostgreSQL
```

## 3. Storage Strategy

*   **Client (Angular):** **IndexedDB** is used for storing the user's private key, cached public keys of contacts, and decrypted chat history. (System storage quotas allow for significant data capacity compared to LocalStorage limits).
*   **Server (PostgreSQL):** Stores relational data for Accounts, OAuth identities, and Web Push Subscriptions (the unique browser/device endpoints required to target FCM/APNs). Encrypted message payloads are stored *temporarily* in a table and deleted strictly upon receiving an `ACK` from the client.

---

## 4. Scalability & Deployment Models

### 4.1 Horizontal Scaling & Load Balancing (Centralized)
The split architecture naturally dictates two distinct load balancing strategies for the Control Plane (Server) and Data Plane (Hub):

1. **Server (REST HTTP Traffic):** The Server instances are stateless HTTP nodes. An API Gateway or standard Load Balancer (like Nginx, HAProxy, or AWS ALB) routes `/api/*` traffic across the Server cluster using Round-Robin.
2. **Hub (WebSocket Traffic):** Hubs maintain long-lived stateful TCP connections. The Load Balancer terminates SSL and routes WebSocket upgrade requests to backend Hub instances. Since RabbitMQ acts as the unified backplane, sticky sessions are NOT required. A "Least Connections" load balancing algorithm is seamlessly supported and highly recommended here to evenly distribute long-lived WebSocket connections as nodes scale up or down.

```mermaid
flowchart TD
    Clients[Clients PWA] --> LB["API Gateway or Load Balancer"]

    LB -->|HTTP REST Round Robin| S1["Server Node 1"]
    LB -->|HTTP REST Round Robin| S2["Server Node 2"]

    LB -->|WebSocket Least Connections| H1["Hub Node 1"]
    LB -->|WebSocket Least Connections| H2["Hub Node 2"]
    LB -->|WebSocket Least Connections| HN["Hub Node N"]

    S1 --> DB[(PostgreSQL)]
    DB --> S1
    S2 --> DB
    DB --> S2

    S1 --> MQ[[RabbitMQ Cluster]]
    MQ --> S1
    S2 --> MQ
    MQ --> S2
    H1 --> MQ
    MQ --> H1
    H2 --> MQ
    MQ --> H2
    HN --> MQ
    MQ --> HN
```

### 4.2 Volunteer Hubs (Hybrid Distributed Architecture)
To further scale and reduce infrastructure costs, this architecture supports a **Volunteer Relay Network**. Users can host lightweight volunteer nodes that seamlessly integrate into the main network to help route live WebSocket traffic, distributing the connection load.

*(Note: The "Central Server & Hubs" below represents the load-balanced Spring Boot clusters from section 4.1).*

**Separation of Concerns:**
*   **Core Infrastructure:** Hosts the PostgreSQL database, `Server` application (Auth, Key Directory, Store-and-Forward), Main RabbitMQ cluster, and at least some fallback `Hub` instances.
*   **Volunteer Infrastructure:** Volunteers run only the `fourletters-hub` application. It only requires connection credentials to the Main RabbitMQ cluster. It does not require database access or secrets. To validate a user's JWT, they verify the cryptographic signature using a shared public key (Stateless validation).

Because messages are strictly E2E encrypted and hubs lack DB credentials, volunteer nodes act purely as blind data proxies, shielding both the volunteer (from liability/database setup) and the users (from data snooping).

```mermaid
flowchart LR
    subgraph "Client Layer"
        Bob[Bob PWA]
        Charlie[Charlie PWA]
        Diana[Diana PWA]
    end

    subgraph "Volunteer Network (Edge)"
        VNodeA[Volunteer Hub Node A]
        VNodeB[Volunteer Hub Node B]
    end

    subgraph "Core Infrastructure (Main)"
        MQ[[Main RabbitMQ]]
        Central["Central Server & Hubs"]
        DB[(Main DB)]
    end

    %% Client Connections
    Bob -->|WebSocket| VNodeA
    VNodeA --> Bob
    Charlie -->|WebSocket| VNodeB
    VNodeB --> Charlie
    Diana -->|Fallback WS| Central
    Central --> Diana

    %% Message Routing (Data Plane)
    VNodeA -->|Pub/Sub| MQ
    MQ --> VNodeA
    VNodeB -->|Pub/Sub| MQ
    MQ --> VNodeB
    Central -->|Pub/Sub| MQ
    MQ --> Central
    Central -->|Read/Write| DB
    DB --> Central

    %% Control Plane
    VNodeA -.->|Health or Fallback| Central
    VNodeB -.->|Health or Fallback| Central
```

*   **Bootstrapping:** PWA clients log in with the Server. The Server returns a list of healthy "Volunteer Hubs."
*   **Routing:** Bob connects via WebSocket to Volunteer Hub A. Charlie connects to Node B. When Bob messages Charlie, Node A publishes the encrypted data directly to the Main RabbitMQ. Node B consumes it from the queue and pushes it to Charlie. The Volunteer Hubs never communicate directly with each other.
*   **Resilience (Fallback):** If a volunteer turns off Node A, Bob's WebSocket disconnects. Bob's app instantly and silently reconnects to either another Volunteer Hub or directly to the Hub to guarantee uninterrupted communication.
