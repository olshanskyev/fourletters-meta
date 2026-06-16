# Hub WebSocket Handler Logic

This document maps out the specific execution logic inside the `HubWebSocketHandler`, detailing the responsibilities of the Hub as an intermediary between the Angular PWA Client and the RabbitMQ Broker.

It illustrates how the Hub handles incoming WebSocket messages from the client (`sendMessage`, `ackMessage`), how it handles incoming RabbitMQ payloads, event transformations, manual acknowledgements, and failure-scenario timeouts.

## Core Responsibilities
1. **Security / Identity:** Validates the JWT (via Principal) and strictly overrides the `senderId` on outgoing messages to prevent spoofing.
2. **Event Transformation:** Translates client "Actions" (intentions) into "Events" (notifications) for the receiving client.
   - `action: sendMessage` ➔ `event: messageReceived`
   - `action: ackMessage` ➔ `event: messageRead`
3. **Guaranteed Delivery:** Employs Manual ACKs and Timeout Timers to ensure messages are not deleted from RabbitMQ until the PWA definitively acknowledges them.

## Handling Missing DTO Data (The `senderId` Issue)
*Note:* For read-receipts (`messageRead`) to be successfully forwarded back to the original sender via RabbitMQ, the Hub needs to know the original target `senderId`. Since the Hub operates statelessly (reconnections wipe memory map caches), the `AckMessagePayload` / `ClientMessageAck` DTO passed from the client *must* contain the target `senderId` (the user who sent the original message). Once the Hub uses this target routing key to securely inject the message into RabbitMQ, it **transforms the data natively into the `EventMessageReceipt` DTO schema**, which naturally ignores the sender and structures the payload correctly for the WebSocket client mapping!

---

## Block Algorithm

Below is the step-by-step sequential flowchart illustrating a message flying from Client 1, passing through the backend logic, reaching Client 2, and generating a Read Receipt back to Client 1.

```mermaid
flowchart TD
    subgraph Client1 [Client 1 - Sender]
        C1_Send([Send action: sendMessage])
        C1_Dispatch([Receive event: messageDispatched])
        C1_Read([Receive event: messageRead])
    end

    subgraph Hub1 [Hub - Sender Side]
        H1_Process[Validate identity<br/>Inject senderId = Client 1]
        H1_Transform[Transform action to event:<br/>sendMessage -> messageReceived]
        H1_Publish[Publish to RabbitMQ<br/>Routing Key: user.Client2]
        H1_LocalAck[Auto-reply messageDispatched<br/>via WS]

        H1_RxAck[Receive event: messageRead from MQ]
        H1_MqAck[MQ basicAck immediately]
        H1_SendReadWS[Send exact JSON<br/>to Client 1 via WS]
    end

    subgraph RabbitMQ [RabbitMQ System]
        MQ_CheckRoute{Is Client 2 bounding<br/>to messages.exchange?}
        MQ_DLX[Route to Alternate Exchange<br/>Store-and-Forward Flow]
        MQ_RouteToC2[Route to Client 2 Hub Queue]
        MQ_RouteToC1[Route to Client 1 Hub Queue]
    end

    subgraph Hub2 [Hub - Receiver Side]
        H2_Receive[Receive messageReceived<br/>from RabbitMQ]
        H2_SetTimer[Store deliveryTag<br/>Start 10s ACK Timer]
        H2_SendClient[Send exact JSON<br/>to Client 2 via WS]

        H2_RxClientAck[Receive action: ackMessage]
        H2_Confirm[MQ basicAck<br/>Cancel 10s Timer]
        H2_TransformAck[Transform action to event:<br/>ackMessage -> messageRead]
        H2_FwdAck[Publish to MQ RK: user.Client1]

        H2_TimerExpire([10s Timer Expires or<br/>Client Disconnects])
        H2_Nack[MQ basicNack<br/>Drops to Store-and-Forward]
    end

    subgraph Client2 [Client 2 - Receiver]
        C2_Receive([Receive event: messageReceived])
        C2_SendAck([Send action: ackMessage])
    end

    %% Flow: Sending
    C1_Send --> H1_Process
    H1_Process --> H1_Transform
    H1_Transform --> H1_Publish
    H1_Publish --> H1_LocalAck
    H1_LocalAck --> C1_Dispatch

    %% Flow: Routing to Client 2
    H1_Publish --> MQ_CheckRoute
    MQ_CheckRoute -- No Offline --> MQ_DLX
    MQ_CheckRoute -- Yes Online --> MQ_RouteToC2

    %% Flow: Delivery
    MQ_RouteToC2 --> H2_Receive
    H2_Receive --> H2_SetTimer
    H2_SetTimer --> H2_SendClient
    H2_SendClient --> C2_Receive

    %% Flow: Acknowledgment
    C2_Receive -->|Processes & Reads| C2_SendAck
    C2_SendAck --> H2_RxClientAck
    H2_RxClientAck --> H2_Confirm
    H2_RxClientAck --> H2_TransformAck
    H2_TransformAck --> H2_FwdAck

    %% Flow: Return Read Receipt Route
    H2_FwdAck --> MQ_RouteToC1
    MQ_RouteToC1 --> H1_RxAck
    H1_RxAck --> H1_MqAck
    H1_RxAck --> H1_SendReadWS
    H1_SendReadWS --> C1_Read

    %% Failure Logic
    H2_SetTimer -.-> H2_TimerExpire
    H2_TimerExpire -.-> H2_Nack
```






