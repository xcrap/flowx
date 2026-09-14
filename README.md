# FlowX

FlowX is a native macOS AI workspace for orchestrating conversations, browser previews, git inspection, and terminals in a focused desktop shell.

## Features

- **Clean shell layout** instead of canvas nodes
- **Provider-native conversations** discovered from Codex and Claude Code for each workspace
- **Current model catalogs** — GPT-6 Astra; GPT-5.6 Sol, Terra, and Luna; Claude Fable 5, Opus 4.8, Sonnet 5, and Haiku 4.5 — plus runtime discovery and provider defaults
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
make benchmark-chat # Measure optimized transcript preparation
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

Codex permits one writer per task. If another Codex app or session owns a task,
FlowX can continue displaying its transcript but cannot send to it. A rejected
resume preserves the unsent text and attachments independently of transcript
refreshes and across app restarts. Finish any running work and quit the owning
Codex app or session, then choose **Retry message**. Retry uses the original
request, and queued requests remain paused until the conflict is resolved.

## Chat performance

Completed turns reuse their prepared presentation until their contents change.
Text streaming updates only the streaming row and scroll observer, with an
immediate first publication and a 50 ms cadence for subsequent bursts. Collapsed
user prompts parse at most 2,000 characters until expanded. Scroll restoration
reveals stable layout after three unchanged passes, then follows late Markdown
or image resizing while pinned. All eight tone/appearance palettes are cached.

The selected provider task checks for external changes every second while the
window is visible, including beside a foreground Codex window. Codex checks use
the rollout file's size and modification time, so unchanged files do not reload.
Selecting a task refreshes it immediately. Providers without a file revision
fall back to a five-second refresh; updates become visible after the provider
writes them to its native transcript. FlowX-owned turns keep using their stream.
Native local images load through a bounded background cache, so a slow file
open cannot hold up newer text. Completed image loads trigger a refresh too.

`make benchmark-chat` runs an opt-in release benchmark with identical-output
checks: 240 messages across 100 latest-turn updates, plus 100 parses of a 133 KB
assistant response. It measures presentation preparation, not frame rate or
provider response latency. Normal package tests cover cache invalidation,
history pruning, streaming delivery/cancellation, scroll geometry and themes.

## Diff performance

Inline and split diffs share one virtualized AppKit list from `FXDesign`.
Only visible rows have SwiftUI hosting views; disclosure updates a compact
file index rather than constructing every code row. Git refreshes retain the
canvas and scroll offset, and toggling display mode reuses prepared split rows.
Extremely long lines show a 4,096-character preview; copying rows preserves
their full text. The native rendering test opens a 100,000-row list offscreen,
checks that fewer than 100 rows are built, and verifies reaching/copying its end.
Run `make benchmark-diff` to report viewport construction work and timing.

The diff toolbar includes Collapse All / Expand All and direct Inline / Split
choices. Its searchable file navigator shows filenames, folders and change
counts; Enter opens the first match. Selecting a file expands it and jumps to
its header, including repeat selections. Collapse All also applies to new files
that arrive on refresh. Hide Files to give the code more room; narrow panels
place the navigator above the diff. Commit and Push share the comparison header,
with the commit form appearing only when requested.
