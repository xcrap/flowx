# FlowX

Native macOS app for orchestrating AI conversations, browser previews, git inspection, and terminals in a clean shell layout.

## Architecture

- **Swift 6.2 / SwiftUI** targeting macOS 26
- **Multi-package structure** under `Packages/`:
  - `FXCore` — shared models, environment, runtime discovery
  - `FXAgent` — providers, conversation engine, streaming, approvals
  - `FXTerminal` — terminal session management via SwiftTerm
  - `FXDesign` — shared design tokens and UI primitives; this is the code-level source of truth for FlowX interface styling and components
- **Main app target** in `FlowX/`:
  - `State/AppState.swift` wires providers, persistence, git polling, and workspace state
  - `Views/` contains the shell, sidebar, conversation UI, panels, and settings
  - `Services/` contains project, conversation, and git persistence/services
- **XcodeGen** — `project.yml` generates `FlowX.xcodeproj`

## Product Shape

- Sidebar with projects and agents
- Centered conversation surface with composer, runtime state, and onboarding
- Optional browser split for web preview
- Optional bottom terminal area with up to 3 side-by-side panes
- Right inspector for changes and files
- Settings panel and command palette

## Design System Source of Truth

- `Packages/FXDesign` is the primary UI source of truth for FlowX
- Implement UI by extending `FXDesign` first, then consuming those components from app views
- Keep tokens, component shapes, spacing, interaction patterns, and dropdown behavior consistent across the app
- Avoid default macOS visual treatments when FlowX already defines a custom control style
- If a component is missing from `FXDesign`, add it there first and then use it from app views instead of styling each screen ad hoc

## Build

```bash
make generate   # Regenerate FlowX.xcodeproj
make dev        # Debug build + open dist/FlowX-Dev.app
make build      # Release build to dist/FlowX.app
make test       # Run package tests
make clean      # Remove build artifacts
```

Debug and release use separate app-support directories so local development does not overwrite release data.

## Providers

### Claude Code

- Spawns `claude -p` with `--output-format stream-json`
- Uses `--include-partial-messages` for streaming updates
- Supports `--resume <sessionID>`
- Access mode maps to Claude permission flags:
  - `fullAccess` -> `--dangerously-skip-permissions`
  - `acceptEdits` -> `--permission-mode acceptEdits`
  - `supervised` -> `--permission-mode default`

### Codex

- Uses persistent `codex app-server` sessions over JSON-RPC
- Reuses threads for conversation continuity
- Access mode maps to approval and sandbox settings:
  - `supervised` -> `approval=untrusted`, `sandbox=workspace-write`
  - `acceptEdits` -> `approval=on-request`, `sandbox=workspace-write`
  - `fullAccess` -> `approval=never`, `sandbox=danger-full-access`
- Supervised approvals are surfaced in the FlowX UI

## Persistence

- Debug data: `~/Library/Application Support/FlowX-Dev/`
- Release data: `~/Library/Application Support/FlowX/`
- Projects and workspace layout: `projects.json`
- Conversations: `conversations/<projectID>.json`

## Working Notes

- Preserve current FlowX product behavior unless a change is intentional
- Treat the FlowX design system as binding guidance, not loose inspiration
- Do not ship native glassy menus, left-side menu indicators, or improvised control styles when FlowX defines a flatter custom alternative
