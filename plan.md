# FlowX — Implementation Plan

## Context

FlowX is a ground-up rebuild of the Flow app concept. Flow was a node-based macOS app with an infinite canvas where agents lived as draggable nodes. FlowX replaces that with a clean, traditional sidebar + content layout — no nodes, no canvas, no zoom. The core value (multi-agent AI conversations powered by Claude Code CLI and Codex) stays the same, but the UX becomes a polished, high-performance single-window app inspired by tools like Polyscope.

**What we reuse from `/Users/xcrap/projects/flow`:**
- Provider system (ClaudeCodeProvider, CodexProvider, AIProvider protocol, ProviderRegistry)
- Conversation engine (ConversationState, ConversationService, streaming/queuing)
- Stream event parsing and token tracking
- RuntimeDiscovery (binary resolution for claude/codex CLIs)
- Terminal sessions (SwiftTerm integration)
- Git services (GitStatusService polling)
- Core model patterns (Codable persistence, @Observable state)

**What we discard:**
- AFCanvas package entirely (CanvasState, ProjectCanvasView, node rendering, pan/zoom)
- Node-based concepts (WorkflowNode positions, NodeConnection, canvas coordinates)

## Current Status (March 29, 2026)

The app is no longer just a visual mockup. The FlowX shell now builds against real provider, conversation, runtime discovery, terminal, persistence, and git foundations ported from `/Users/xcrap/projects/flow`.

**Implemented now:**
- FXCore / FXAgent / FXTerminal ported and compiling inside FlowX
- Real `AppState`, `ProjectPersistence`, and `ConversationPersistence`
- Real provider registration, runtime health checks, send / cancel / reset flows
- Real runtime activity rendering, queued prompt editing/removal, supervised approval handling, session resume/retry UX, token/context status, and per-agent terminal sessions
- Real git polling, searchable file inspection, staged / unstaged / base inspection, inline / split diff rendering, and commit / push actions
- Real split browser panel backed by `WKWebView` with per-agent persisted URL state
- More polished empty states plus core shell shortcuts for sidebar, right panel, terminal, send, settings, agent switching, and command palette
- Deeper workspace persistence for conversation scroll position, inspector state, and shell panel visibility

**Still outstanding before calling the core shell “feature-complete”:**
- Provider/session polish: deeper session recovery edge cases and additional multi-provider supervision depth
- Accessibility and performance passes beyond the now-landed lazy conversation rendering and dynamic window title
- Additional session restore and agent/workspace quality-of-life polish

**Active next slice:**
- Keep closing shell polish gaps around accessibility, performance, and remaining session/workspace depth

---

## Architecture Decision: SwiftUI + AppKit Hybrid

**Recommendation: SwiftUI-primary with targeted AppKit bridges**

| Component | Technology | Reason |
|-----------|-----------|--------|
| App shell & navigation | SwiftUI `NavigationSplitView` | Native sidebar behavior, clean API |
| Sidebar | SwiftUI | List, disclosure groups, drag-drop — all excellent in SwiftUI |
| Conversation view | SwiftUI | ScrollView, lazy stacks, text rendering |
| Split view (content area) | `NSSplitView` via `NSViewRepresentable` | Precise divider control, animated resizing, persistent proportions |
| WebKit browser panel | `WKWebView` via `NSViewRepresentable` | No SwiftUI native equivalent |
| Terminal panel (bottom) | SwiftTerm `LocalProcessTerminalView` via `NSViewRepresentable` | Already AppKit-based |
| Git diff view | SwiftUI (custom) or WKWebView | Depends on fidelity needs |
| Animations | SwiftUI + Core Animation | SwiftUI for transitions, CA for custom micro-animations |
| Window chrome | Native (unified toolbar) | Best performance, platform consistency |

---

## New Package Structure

```
/Users/xcrap/projects/flowx/
├── project.yml                    # XcodeGen config
├── Makefile                       # Build shortcuts
├── Packages/
│   ├── FXCore/                    # Data models (forked from AFCore, simplified)
│   │   └── Sources/FXCore/
│   │       ├── Models/
│   │       │   ├── Project.swift          # No canvas fields
│   │       │   ├── Agent.swift            # Replaces WorkflowNode (no position/size/kind)
│   │       │   ├── AgentConfiguration.swift # Slimmed NodeConfiguration
│   │       │   ├── Conversation.swift     # Same as AFCore
│   │       │   ├── Attachment.swift       # Same
│   │       │   └── ToolApprovalRequest.swift
│   │       └── Services/
│   │           ├── RuntimeDiscovery.swift  # Copied from AFCore
│   │           └── BinarySpecs.swift      # Copied
│   │
│   ├── FXAgent/                   # Providers + conversation (forked from AFAgent)
│   │   └── Sources/FXAgent/
│   │       ├── Providers/
│   │       │   ├── AIProvider.swift        # Protocol (same)
│   │       │   ├── ClaudeCodeProvider.swift # Copied verbatim
│   │       │   ├── CodexProvider.swift     # Copied verbatim
│   │       │   └── ProviderRegistry.swift  # Same
│   │       ├── Conversation/
│   │       │   ├── ConversationState.swift # nodeID → agentID rename
│   │       │   └── ConversationService.swift # nodeID → agentID rename
│   │       └── Tools/
│   │           └── GitService.swift        # Basic git operations
│   │
│   ├── FXTerminal/                # Terminal sessions (forked from AFTerminal)
│   │   └── Sources/FXTerminal/
│   │       └── TerminalSession.swift      # Nearly identical
│   │
│   └── FXDesign/                  # NEW: Design system package
│       └── Sources/FXDesign/
│           ├── Tokens/
│           │   ├── Colors.swift           # Color palette & semantic colors
│           │   ├── Typography.swift       # Type scale & font styles
│           │   ├── Spacing.swift          # Spacing scale (4px grid)
│           │   └── Radii.swift            # Corner radius tokens
│           ├── Components/
│           │   ├── FXButton.swift         # Button variants
│           │   ├── FXBadge.swift          # Status badges/pills
│           │   ├── FXCard.swift           # Card containers
│           │   ├── FXInput.swift          # Text input fields
│           │   ├── FXDivider.swift        # Styled dividers
│           │   └── FXIcon.swift           # Icon system
│           └── Animations/
│               ├── MicroAnimations.swift  # Reusable animation curves & presets
│               └── Transitions.swift      # Custom view transitions
│
├── FlowX/                         # Main app target
│   ├── FlowXApp.swift             # @main entry point
│   ├── State/
│   │   ├── AppState.swift         # Redesigned (no canvas, has activeAgentID)
│   │   ├── ProjectState.swift     # agents[] instead of nodes[]
│   │   └── WorkspaceState.swift   # Split view mode, right panel state
│   ├── Views/
│   │   ├── MainLayout.swift       # Root 3-column layout
│   │   ├── Sidebar/
│   │   │   ├── SidebarView.swift          # Project list with nested agents
│   │   │   ├── ProjectRow.swift           # Project item (expandable)
│   │   │   └── AgentRow.swift             # Agent item under project
│   │   ├── Content/
│   │   │   ├── ContentAreaView.swift      # Agent content: upper (conv+split) + bottom terminal
│   │   │   ├── ConversationView.swift     # Chat messages + streaming
│   │   │   ├── MessageBubble.swift        # Individual message rendering
│   │   │   ├── RuntimeActivityBar.swift   # Tool use / task progress strip
│   │   │   ├── ChatInputBar.swift         # Input field + model selector + attachments
│   │   │   └── TerminalPanel.swift        # Bottom toggleable terminal per agent
│   │   ├── Panels/
│   │   │   ├── RightPanelView.swift       # CHANGES/FILES tabs (inspector-style push)
│   │   │   ├── ChangesPanel.swift         # Git diff list
│   │   │   ├── FilesPanel.swift           # File tree
│   │   │   ├── DiffView.swift             # Inline diff rendering
│   │   │   └── BrowserPanel.swift         # WebKit wrapper
│   │   ├── Split/
│   │   │   └── SplitContentView.swift     # NSSplitView bridge for horizontal split
│   │   ├── StatusBar/
│   │   │   └── StatusBarView.swift        # Bottom status bar
│   │   └── Settings/
│   │       └── SettingsPanel.swift        # Inline settings (slide-in)
│   ├── Services/
│   │   ├── GitStatusService.swift         # Ported from Flow
│   │   ├── ConversationPersistence.swift  # Adapted persistence
│   │   └── ProjectPersistence.swift       # Adapted persistence
│   └── Commands/
│       └── FlowXCommands.swift            # Menu bar commands & shortcuts
```

---

## Phase 0 — Project Scaffolding

**Goal:** Empty but buildable Xcode project with all packages wired up.

- [x] Create `project.yml` (XcodeGen) targeting macOS 26, Swift 6.2, strict concurrency
- [x] Create `Makefile` with `generate`, `dev`, `build`, `clean` targets
- [x] Create all 4 package `Package.swift` files with correct dependencies
- [x] Create empty source files so everything compiles
- [x] Generate `.xcodeproj` and verify clean build

---

## Phase 1 — Design System + Interactive Mockup ⭐

**Goal:** A running app with the complete visual design, mock data, and all micro-animations — but no real provider integration. This IS the mockup.

**Status:** 🟡 Implemented and usable — visual shell is in place, now being converted from mock behaviors to real app behaviors.

### 1a. Design System (FXDesign package)

**Color Tokens:**
```
Background:     #111113 (primary), #161618 (elevated), #1C1C1F (surface)
Foreground:     #FAFAFA (primary), #A1A1A6 (secondary), #6E6E73 (tertiary)
Accent:         #6C5CE7 (purple primary), #4ECDC4 (teal secondary)
Semantic:       success=#34D399, warning=#FBBF24, error=#F87171, info=#60A5FA
Border:         #2C2C2E (subtle), #3A3A3C (medium)
```

**Typography Scale:**
```
title1:    24pt, semibold     (section headers)
title2:    18pt, semibold     (panel titles)
title3:    15pt, medium       (card titles)
body:      13pt, regular      (content)
caption:   11pt, regular      (metadata)
mono:      12pt, monospaced   (code, stats)
```

**Spacing Scale:** 2, 4, 6, 8, 12, 16, 20, 24, 32, 48

**Micro-Animation Presets:**
```swift
static let snappy = Animation.spring(duration: 0.25, bounce: 0.0)
static let gentle = Animation.spring(duration: 0.35, bounce: 0.15)
static let quick  = Animation.easeOut(duration: 0.15)
static let smooth = Animation.easeInOut(duration: 0.3)
```

### 1b. Sidebar Mockup
- Project list with disclosure triangles → agents nested underneath
- Agent rows with status indicator (dot: idle=gray, working=green pulse, error=red)
- Hover effects, selection highlight with accent color
- Drag-to-reorder agents within a project
- "Add Repository" button at bottom
- Collapse/expand animation

### 1c. Content Area Mockup

Each agent's content area has this vertical layout:

```
┌──────────────────┬──────────────┐
│  Conversation    │  Diff/Browser│  ← horizontal split (optional)
│  messages...     │              │
│                  │              │
│  [Input bar]     │              │
├──────────────────┴──────────────┤  ← toggleable divider
│  Terminal  $ _                  │  ← bottom terminal panel (optional)
└─────────────────────────────────┘
```

- **Upper zone:** Conversation (or horizontal split with diff/browser on right)
- **Lower zone:** Toggleable terminal panel, each agent gets its own terminal session tied to the project root
- Conversation view with mock messages (user + assistant)
- Streaming text simulation (typewriter effect with mock data)
- Runtime activity strip showing tool use progress (like the screenshot: checkmarks, in-progress indicators)
- Chat input bar above terminal divider:
  - Multi-line expanding text field
  - Model selector dropdown (Claude Opus, Sonnet, etc.)
  - Attachment button, microphone button
  - Send button with keyboard shortcut hint
- Terminal toggle button in toolbar or via ⌘` shortcut

### 1d. Right Panel Mockup
- Toggle button in toolbar to show/hide
- CHANGES / FILES tab bar
- Changes tab: list of files with +/- line counts, checkmarks
- Local / Base toggle
- Push button (accent colored)
- Slide-in animation from right edge

### 1e. Split View Mockup
- Button/gesture to split the upper zone horizontally (side-by-side)
- Left half: conversation, right half: diff view or browser
- Draggable divider between left/right
- Animate split open/close

### 1f. Bottom Terminal Mockup
- Toggleable panel at the bottom of the content area (below conversation + split)
- Draggable vertical divider between upper zone and terminal
- Terminal header bar with title, resize grip, close button
- Mock terminal output with prompt
- Remembers last height when toggled off/on
- Smooth slide-up/down animation

### 1g. Status Bar
- Connection indicator (green dot + "Connected")
- Current branch with icon
- Tool call counter
- Subtle top border, minimal height (~28px)

---

## Phase 2 — Core Package Porting

**Goal:** All reusable business logic from `flow` running in FlowX packages.

**Status:** 🟢 Largely complete.

### 2a. FXCore Models
- Fork `Project.swift` — remove `canvasOffset`, `canvasZoom`; add `agentOrder: [UUID]`
- Create `Agent.swift` from `WorkflowNode` — keep `id`, `title`, `configuration`, `executionState`; drop `kind`, `position`, `isCollapsed`
- Fork `AgentConfiguration.swift` from `NodeConfiguration` — keep provider/model/effort/systemPrompt/agentMode/agentAccess/contextWindowSize; drop `script`, `language`, `cronExpression`, `triggerType`
- Copy verbatim: `Conversation.swift`, `Attachment.swift`, `ToolApprovalRequest.swift`, `RuntimeDiscovery.swift`, `BinarySpecs.swift`, `AppEnvironment.swift`

### 2b. FXAgent Providers
- Copy verbatim: `AIProvider.swift`, `ClaudeCodeProvider.swift`, `CodexProvider.swift`, `ProviderRegistry.swift`, `StreamEvent.swift`
- Port `ConversationState.swift` — rename `nodeID` → `agentID`, update imports to FXCore
- Port `ConversationService.swift` — rename nodeID references → agentID, update imports
- Port `ConversationRuntimeActivity.swift` — no changes needed beyond imports
- Copy `GitService.swift`

### 2c. FXTerminal
- Copy `TerminalSession.swift` and `TerminalSurface.swift` — update package imports only

---

## Phase 3 — State Management & Wiring

**Goal:** Real state management replacing mock data, persistence working.

**Status:** 🟢 Baseline complete, with ongoing UX refinement.

### 3a. AppState (new design)
```swift
@Observable @MainActor
final class AppState {
    var projects: [ProjectState] = []
    var activeProjectID: UUID?
    var activeAgentID: UUID?           // NEW: which agent's conversation is shown
    var rightPanelVisible: Bool = false
    var rightPanelTab: RightPanelTab = .changes  // .changes | .files
    var pendingApprovals: [ToolApprovalRequest] = []

    // Lifecycle
    func createProject(name: String, rootPath: String) -> ProjectState
    func deleteProject(_ id: UUID)
    func addAgent(to projectID: UUID, title: String, config: AgentConfiguration) -> Agent
    func removeAgent(_ agentID: UUID, from projectID: UUID)
}
```

### 3b. ProjectState (new design)
```swift
@Observable @MainActor
final class ProjectState {
    var project: Project
    var agents: [UUID: Agent] = [:]
    var agentOrder: [UUID] = []
    var onChange: (() -> Void)?

    func addAgent(title: String, config: AgentConfiguration) -> Agent
    func removeAgent(_ id: UUID)
    func moveAgent(from: IndexSet, to: Int)
}
```

### 3c. WorkspaceState (new — per agent)
```swift
@Observable @MainActor
final class WorkspaceState {
    // Horizontal split (conversation | diff/browser)
    var splitOpen: Bool = false
    var splitContent: SplitContent = .diff  // .diff | .browser
    var splitRatio: CGFloat = 0.5
    var browserURL: URL?

    // Bottom terminal panel
    var terminalVisible: Bool = false
    var terminalHeight: CGFloat = 200      // remembers last height
}
```
Each agent gets its own `WorkspaceState` so split/terminal preferences are independent.

### 3d. Persistence
- Adapt `ProjectPersistence` — serialize projects with agents instead of nodes
- Adapt `ConversationPersistence` — use agentID instead of nodeID
- Same JSON file approach, same debounced saving pattern

### 3e. Wire to UI
- Replace mock data in sidebar with real ProjectState
- Replace mock conversation with real ConversationState
- Connect ChatInputBar → ConversationService.send()
- Connect RuntimeActivityBar → ConversationState.runtimeActivities

---

## Phase 4 — Provider Integration

**Goal:** Actually talk to Claude Code and Codex.

**Status:** 🟢 Provider runtime, queued prompt UX, persisted session resume, supervised approval handling, retry recovery, and token/context status are in.

- Wire `ProviderRegistry` registration in app startup
- Wire `RuntimeDiscovery` for binary detection + health monitoring
- Connect send flow: ChatInputBar → ConversationService → Provider → Stream → ConversationState → UI
- Implement queued prompt UI with visible/editable/removable follow-ups
- Persist and reuse `sessionID` for restart + resume recovery
- Surface supervised approval requests with approve / deny controls
- Display token/context usage in the conversation status strip

---

## Phase 5 — Git Integration + Split Views

**Goal:** Real git status, diff viewing, and WebKit browser.

**Status:** 🟢 Git polling, searchable files, staged/unstaged/base inspection, inline/split diff rendering, inline commit/push workflow, and WebKit browser are in.

### 5a. Git
- Port `GitStatusService` with 5s polling
- Wire to RightPanelView (CHANGES tab with real file list)
- Implement commit flow (inline composer is now in place)
- Push button with async execution
- Branch display in status bar

### 5b. Diff View
- Custom SwiftUI diff renderer OR WKWebView with highlight.js
- Show file diffs when selecting a file in CHANGES panel
- Side-by-side and inline diff modes

### 5c. WebKit Browser
- `WKWebView` wrapped in `NSViewRepresentable`
- URL bar, back/forward/reload controls
- Can be loaded in split view right half
- Navigation delegate for link handling

---

## Phase 6 — Terminal Integration

**Goal:** Each agent gets a real terminal session in the bottom panel.

**Status:** 🟢 Baseline complete.

- Port `TerminalSession` + SwiftTerm `LocalProcessTerminalView` via `NSViewRepresentable`
- Wire `TerminalPanel.swift` to real `TerminalSession` (replaces mock)
- Terminal spawns in project's root path as working directory
- Each agent maintains its own independent terminal session
- Terminal state persists across agent switches (session stays alive)
- Toggle via toolbar button or ⌘` shortcut
- Support multiple terminal tabs per agent (future)

---

## Phase 7 — Polish & Performance

**Goal:** Ship-quality experience.

- Keyboard shortcuts: ⌘B (sidebar), ⌘1-9 (agents), ⌘\ (right panel), ⌘` (terminal), ⌘, (settings), ⌘⇧P (command palette)
- Command palette (searchable actions for repositories, agents, panels, browser, and settings)
- Focus management (auto-focus chat input on agent switch)
- Accessibility pass for icon-only shell controls, command palette search, browser toolbar, and terminal chrome
- Scroll performance optimization (lazy rendering for long conversations)
- Memory management (cap message history, image cleanup)
- App icon and window title
- Accessibility labels
- First-launch experience (empty state, "Add Repository" prompt)

---

## Verification Plan

1. **Build**: `xcodegen generate && xcodebuild -scheme FlowX -configuration Debug build`
2. **Mockup review**: Launch app, verify all visual elements match design spec
3. **Provider test**: Send a message to Claude, verify streaming response renders
4. **Queue test**: Send multiple messages rapidly, verify queuing behavior
5. **Persistence test**: Quit and relaunch, verify conversations survive
6. **Split view test**: Open diff/browser in split, verify divider works
7. **Git test**: Make changes in project folder, verify CHANGES panel updates
8. **Performance**: Profile with Instruments (Time Profiler, Allocations) during streaming
