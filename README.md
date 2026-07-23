# FlowX

FlowX is a native macOS AI workspace for orchestrating conversations, browser previews, git inspection, and terminals in a focused desktop shell.

## Features

- **Clean shell layout** instead of canvas nodes
- **Provider-native conversations** discovered from Codex and Claude Code for each workspace
- **Current model catalogs** — GPT-5.6 Sol, Terra, and Luna; Claude Fable 5, Opus 4.8, Sonnet 5, and Haiku 4.5 — plus runtime discovery and provider defaults
- **Persistent session continuity** — begin in FlowX and resume in the provider, or the other way around
- **Unified provider controls** — Supervised, Accept Edits, or Full Access — while structured questions always remain visible and require an answer
- **Image attachments and durable image history** with bounded decoding and storage
- **Browser split** for previewing local and remote pages
- **Up to 3 terminal panes** per agent
- **Git inspector** for changes, files, commit, and push
- **Command palette** and keyboard-driven shell actions
- **Steer or queue follow-ups while a turn is running** — choose the default in Settings, use Command-Return for it, and Control-Return for the opposite behavior
- **Per-agent persistence** across app restarts

## Requirements

- macOS 26 or later
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Codex](https://openai.com/codex) CLI installed as `codex`
- [Claude Code](https://claude.com/product/claude-code) CLI installed as `claude` for Anthropic sessions

## Build And Run

```bash
make generate   # Regenerate FlowX.xcodeproj
make dev        # Build debug app and open dist/FlowX-Dev.app
make build      # Build release app to dist/FlowX.app
make test       # Run package tests
make check      # Run tests + compile the integrated debug app
make clean      # Remove build artifacts
```

### From Xcode

```bash
xcodegen generate
open FlowX.xcodeproj
```

## Project Structure

- `FlowX/` — app target, shell UI, state, services
- `Packages/FXCore` — shared models and runtime environment
- `Packages/FXAgent` — providers and conversation engine
- `Packages/FXTerminal` — terminal integration
- `Packages/FXDesign` — design system primitives

## Persistence

- Debug app data: `~/Library/Application Support/FlowX-Dev/`
- Release app data: `~/Library/Application Support/FlowX/`

FlowX stores workspace layout and a bounded UI cache in those directories. The
provider's own Codex or Claude session remains authoritative and can be opened
from the provider's other native clients.
