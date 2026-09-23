# Yeobun

macOS menu-bar app by N6 Studio. SwiftUI inside an AppKit `NSStatusItem` + `NSPopover`. No Dock icon (`LSUIElement`).

Agents should drive tools with the `yeobun` CLI (`yeobun --help`, `--json`), not by clicking the popover. GUI rules below apply only to the panel.

`scripts/CaptureScreenshots.swift` points itself at a throwaway home before it seeds the model, because seeding persists tool state. Keep it that way.

Build with `./build.sh`. It picks the SDK that matches the running macOS when the Command Line Tools default to a newer beta SDK (a beta SwiftUI turns `@State` into a macro the CLT does not ship). Set `SDKROOT` to override.

## UI style — Console

One menu-bar popover. Stay on SwiftUI + AppKit. Do not add a third-party widget kit (MacControlCenterUI, web component libraries, etc.).

### Shell

- Panel background: `.regularMaterial`. Follow system light/dark. Do not force `colorScheme` or `NSAppearance.darkAqua`.
- Width 320pt (`Radius.panelWidth`). Padding 18.
- Home is one column: **pinned stats**, then a **list of rows**. No Tools / Stats tabs.
- Pinned stats are the small boxes. Pin a single number from Mac or a remote (CPU, memory, storage, network, power, battery). Each box shows that source’s icon. Storage is pinned by default; battery is not. Tap a box to open its page.
- Mac is a home row titled This MacBook. The line under the title is the short stats (CPU, RAM, storage, network, and power). Battery stays on the Mac page. Battery and network are not their own rows. Each remote is a row and can have its own icon, set on the remote page or in Settings. The icon is also used on that remote’s rows.
- The **switch** toggles a tool with its current options. The **rest of the row** opens detail. Gear (top right) → Settings. Pencil (left of gear) → edit home (hide, show, drag to reorder). Checkmark → done. Chevron → home. Closing the popover resets to home.
- No extra copy on rows: name and status only. The Mac row is the exception: it shows this Mac’s stats on one line.

### Rows

- Corner radius 12 (`Radius.row`), height 52.
- **Off / informational:** `Color.primary.opacity(0.08)` fill, `.primary` content.
- **On:** accent wash (`ModuleColor.onFill`, about 18%) and a 3pt accent bar on the leading edge. Text stays `.primary`. Do not put white type on orange or brown.
- Built-in keyboard: `Color.orange`
- Scroll reverse: `Color.accentColor`
- Lid awake: `Color.purple`
- Keep awake: `Color.brown`
- Hidden icons: `Color.teal`
- Voice typing: `Color.red`
- This Mac is the **Mac** row. Its page shows CPU, memory, power, and storage. Pin any of those to Home.
- Remote SSH servers: always informational. One home row per saved host, with the icon you assign. Whole row opens detail. Add/remove from Settings or `yeobun remote`. Linux hosts, SSH keys or ssh-agent only.
- Battery warns when charge is low; Storage warns when the disk is full.
- Status on toggle rows is `On` / `Off` (Built-in keyboard On = locked). Voice typing On = armed (shortcut registered); it reads `Listening` during a session and shows a spinner while it asks for the microphone or loads a language. Listening has its own switch in the detail view, plus a badge and the level bars. Its Vocabulary group lists terms (hints for the recognizer) with optional "sounds like" rewrites; the same list is `yeobun voice vocab`. Keep awake shows remaining time when a duration is set. Duration on the detail is a row of chips.
- Hover: brighten the row fill. Press: `scale(0.96)`, 150ms, `cubic-bezier(0.2, 0, 0, 1)`.
- Icons: Phosphor glyphs in `Glyph.swift`, drawn in a square slot so they stay centered. Outline when off, fill when on. Draw the vector directly, with no blur, opacity, or scale filter. On rows the glyph uses the accent, not white. Back, edit, settings, and the other circles stay SF Symbols.

### Chrome and details

- Back/settings: 28pt **circles**, same off-fill, system icons. No custom drop shadows.
- Type: system SF Pro. Titles semibold 12–15. Secondary labels `.secondary`. Tabular numbers on stats and the glance.
- Details/settings: grouped wells `Color.primary.opacity(0.06)`, radius 16. The leading accent stays on home rows only.
- Controls: native `Toggle` + `.switch` + `.small`. Not custom rocker switches. Not checkboxes.
- Tokens live in `Sources/App/Theme.swift` (`Radius`, `Motion`, `ModuleColor`). Home layout lives in `Sources/App/HomeConsole.swift`. Reuse them.

### Don’t

- Workshop/copper palettes, serif wordmarks, tinted card borders for depth, or forced dark popovers.
- Square tiles, a Tools/Stats tab, or an icon circle as the toggle.
- Extra description text on home rows.
- White text on a module-color fill.
