# FlowX

FlowX is a native macOS AI workspace built as the cleaner, node-free evolution of `/Users/xcrap/projects/flow`. It keeps the provider, conversation, terminal, and git foundations from Flow, but moves them into a more focused shell with a stronger UI.

## Current State

The app is already running on real foundations, not a static mockup:

- Claude Code and Codex providers wired into the app shell
- Real streaming conversations, queued prompts, resume/retry, and supervised approvals
- Per-agent workspace state with split browser and multi-pane terminals
- Git changes, files, commit, and push flows
- Persistence for projects, agents, conversations, and workspace layout

This repo is still in active implementation. The remaining roadmap lives in [`plan.md`](./plan.md).

## Features

- **Clean shell layout** instead of canvas nodes
- **Multi-provider agent chat** with Claude Code and Codex
- **Supervised approvals** for tool calls where supported
- **Browser split** for previewing local and remote pages
- **Up to 3 terminal panes** per agent
- **Git inspector** for changes, files, commit, and push
- **Command palette** and keyboard-driven shell actions
- **Per-agent persistence** across app restarts

## Requirements

- macOS 26 or later
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Claude Code](https://claude.ai/code) CLI installed as `claude`
- [Codex](https://openai.com/codex) CLI installed as `codex` if you want OpenAI models

## Build And Run

```bash
make generate   # Regenerate FlowX.xcodeproj
make dev        # Build debug app and open dist/FlowX-Dev.app
make build      # Build release app to dist/FlowX.app
make test       # Run package tests
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
- `plan.md` — implementation roadmap and current status

## Persistence

- Debug app data: `~/Library/Application Support/FlowX-Dev/`
- Release app data: `~/Library/Application Support/FlowX/`

## Status

FlowX is already beyond mockup stage, but it is not feature-complete yet. The main remaining work is deeper git/session polish, performance, and final accessibility/detail passes.
