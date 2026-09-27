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

### Color Architecture

The color system works like CSS custom properties — semantic tokens that resolve based on theme configuration:

- **Views use `FXColors.*`** — never hardcode colors. `FXColors.bg`, `FXColors.fg`, `FXColors.accent`, `FXColors.success`, `FXColors.diffAddedBg`, etc.
- **`FXColors` → `FXTheme` → `FXPalette.generate(tone, dark)`** — colors resolve at render time from the active tone + appearance mode
- **Base tones** (slate, zinc, neutral, stone): Tailwind-derived 11-shade scales (50→950). Dark mode reads top-down (900=bg, 800=elevated, 700=surface), light mode reads bottom-up (50=bg, 100=elevated, 200=surface). Same scale, both modes cohesive.
- **Text contrast**: `fg`, `fgSecondary`, and `fgTertiary` each clear WCAG AA (4.5:1) on `bg` and `bgElevated` in every tone and mode, and keep that order; `fgTertiary` clears 3:1 on `bgSurface`. `DesignTokenTests` enforces this — rerun it after touching any foreground or background token.
- **Accent colors** (violet, blue, emerald, orange, rose): independent of the base tone. `onAccent` is white, or the tone's darkest ink for emerald and orange, which cannot carry white text. `accentSecondary` (teal) adapts per mode.
- **Semantic colors** (success, warning, error, info): adapt per mode — brighter on dark, deeper on light
- **Muted tints** (`successMuted`, `warningMuted`, `errorMuted`, `infoMuted`, `accentMuted`, `accentSecondaryMuted`): tinted backgrounds for banners, badges, and highlighted rows
- **Diff colors** (`diffAddedBg`, `diffRemovedBg`, `diffAddedFg`, `diffRemovedFg`): proper semantic tokens with GitHub-style pastels in light mode, Codex-style muted darks in dark mode. Do NOT use `FXColors.success.opacity(0.08)` for diffs — use the diff tokens.
- **Theme changes trigger full re-render** via `preferences.themeVersion` incrementing and `.id()` on MainLayout

**Rules for future changes:**
- Never add raw `Color(red:green:blue:)` in views — add a token to `FXColors` if one is missing
- Never use system `.background` materials or vibrancy — FlowX uses opaque custom backgrounds
- Never use native macOS menus/popovers with glass — use `FXDropdown` for custom flat menus
- Diff views must use `FXColors.diffAddedBg` / `FXColors.diffRemovedBg`, not opacity-modified semantic colors
- Tinted backgrounds use the `*Muted` tokens, not `FXColors.warning.opacity(0.08)` and friends
- `fgQuaternary` is only for disabled states and decorative glyphs; text and a control's only icon use `fgTertiary` or stronger
- When adding a new base tone or accent, follow the existing pattern in `Colors.swift` and keep `DesignTokenTests` passing

### Typography

- SF Pro Rounded for all UI text (titles, body, captions, buttons)
- Monospaced for code, terminal output, and diff line numbers
- Text sizes scale via `FXTextSizePreset` (compact 0.93x → large 1.16x)
- Use `FXTypography.*` constants, never hardcode font sizes in views

### Spacing, Radii, Borders & Elevation

- 8px baseline grid: `FXSpacing.xxxs` (2) through `FXSpacing.huge` (48)
- Corner radii: `FXRadii.xs` (4) through `FXRadii.xxl` (16)
- Border widths: `FXBorderWidth.hairline` (0.5, the default edge), `.regular` (1, focus), `.strong` (1.5, drop targets)
- Shadows: `.fxShadow(FXShadow.popover | .dialog | .palette | .trailingPanel)`; never hand-write `.shadow(...)`
- Shell dimensions (title bar, sidebar, settings panel, command palette, dialogs, row menus) live in `FXLayout`

### Animations

- Use `FXAnimation.*` presets (snappy, gentle, quick, smooth, panel, micro)
- Never hardcode animation durations in views

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
- Never use SwiftUI's `.contextMenu`; use `.fxContextMenu(sections:)`, which opens the `FXDropdown` panel at the pointer. Build a row's `[FXDropdownSection]` once and pass it to both the context menu and the row's "…" dropdown
