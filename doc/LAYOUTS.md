# PWA Messenger Layouts

This document outlines the architectural layouts for the **fourletters** PWA messenger. It focuses on the mobile-first viewport constraints and structural boundaries required for offline-first, performance-minded rendering. Layouts act as strict viewport shells to separate UI behavior from application logic.

## 1. main-layout (Global Application Shell)
The root-level wrapper orchestrating the primary application workspace and dynamic contextual panel. It houses a primary main content area alongside a dynamic side drawer (`mat-sidenav`) that can render auxiliary components fluidly.

```mermaid
block-beta
  columns 3
  block:Body:2
    columns 1
    CurrentPage["Active Page View<br/>(Router Outlet)"]
  end
  block:SidePanel:1
    columns 1
    DynamicContent["Dynamic Component Context<br/>(NgComponentOutlet)"]
  end

  style Body fill:#ffffff,stroke:#ccc,color:#000
  style SidePanel fill:#f4f4f4,stroke:#ccc,color:#000
```
* **Context Usage:** App-level shell for main authenticated views.
* **Architectural Boundaries**:
  * **Main Body (`mat-sidenav-content`):** Fluid viewport serving changing page layouts.
  * **Side Panel (`mat-sidenav`):** Expandable over/side container managed globally (`SidePanelService`) to mount dynamic components on demand without leaving the current context.

---

## 2. split-layout (Wide Screens / Desktop View)
A Master-Detail composition designed for wide viewports. It acts as a responsive structural wrapper that concurrently coordinates modular layouts (e.g., standard list and chat interface) into a unified grid.

```mermaid
block-beta
  columns 2
  block:Master
    columns 1
    Header["Sticky Header"]
    List["Conversations List"]
  end
  block:Detail
    columns 1
    ChatHeader["Chat Header"]
    Messages["Messages Area"]
    ChatFooter["Input Area"]
  end

  style Header fill:#2a2a2a,stroke:#333,color:#fff
  style ChatHeader fill:#2a2a2a,stroke:#333,color:#fff
  style List fill:#ffffff,stroke:#ccc,color:#000
  style Messages fill:#e5e5ea,stroke:#ccc,color:#000
  style ChatFooter fill:#f9f9f9,stroke:#ccc,color:#000
```
* **Context Usage:** Main page.
* **Architectural Boundaries**:
  * **Master Pane:** Constraint-bound side orchestration surface.
  * **Detail Pane:** Fluid focal container orchestrating primary interactions.

---

## 3. list-layout (Conversations / List View)
The primary vertical scrolling container. Designed to act as the default document flow for lists, settings, and forms.

```mermaid
block-beta
  columns 1
  Header["Sticky Header<br/>(Search, Menu)"]
  block:List
    columns 1
    C1["Conversation 1"]
    C2["Conversation 2"]
    C3["Conversation 3"]
    C4["..."]
  end

  style Header fill:#2a2a2a,stroke:#333,color:#fff
  style List fill:#ffffff,stroke:#ccc,color:#000
```
* **Context Usage:** Conversations, Contacts, Settings
* **Architectural Boundaries**:
  * **Header Shell:** Persistent top-bound surface for global actions.
  * **Body Shell:** Unbounded vertical flow intended for lists and core content.

---

## 4. chat-layout (Opened-Conversation / Chat View)
An immersive, fixed-height viewport. Strictly bounds the structural grid to the dynamic screen height, preventing standard document scroll and ensuring consistent geometry when native virtual keyboards deploy.

```mermaid
block-beta
  columns 1
  Header["Sticky Header<br/>(Back, Avatar, Name, Options)"]
  block:Messages
    columns 1
    M1("Message from Alice")
    M2("Message from Bob")
    M3("Message from Alice")
  end
  Footer["Fixed Bottom<br/>(Text Input, Attachment, Send)"]

  style Header fill:#2a2a2a,stroke:#333,color:#fff
  style Messages fill:#e5e5ea,stroke:#ccc,color:#000
  style Footer fill:#f9f9f9,stroke:#ccc,color:#000
```
* **Context Usage:** Active messaging sessions.
* **Architectural Boundaries**:
  * **Header Shell:** Contextual focal header.
  * **Body Shell:** Inverse-scrolling layer bridging messages.
  * **Footer Shell:** Fixed input composition area mapped accurately to native device safe-areas.

---

## 5. profile-layout (Account Info / Media View)
A rich detail container orchestrating nested scrolling constraints and sticky surface transitions.

```mermaid
block-beta
  columns 1
  Header["Sticky Header<br/>(Back, User Info Title, Edit)"]
  Hero["First Body Part<br/>(Large Avatar, Status, Phone)"]
  Tabs["Sticky Tabs<br/>(Media | Links | Files)"]
  block:Content
    columns 2
    I1["Image"] I2["Image"]
    I3["Image"] I4["Image"]
  end

  style Header fill:#2a2a2a,stroke:#333,color:#fff
  style Hero fill:#f0f0f0,stroke:#ccc,color:#000
  style Tabs fill:#2a2a2a,stroke:#333,color:#fff
  style Content fill:#ffffff,stroke:#ccc,color:#000
```
* **Context Usage:** User identity profiles, Group configurations.
* **Architectural Boundaries**:
  * **Header Shell:** Minimal navigational threshold.
  * **Lead Body:** Primary hero context (pictures, bios) shifting with scroll.
  * **Sticky Mid-Shell:** Secondary navigation intercepting the header position on scroll ascent.
  * **Trailing Body:** Flexible space for media grids or additional lists.



