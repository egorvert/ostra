# Ostra

A native macOS coding-agent harness: agents on a canvas, a Liquid Glass HUD, and T3 Code as the engine. See `README.md` for what it does and how to run it.

## Layout

- `Sources/OstraCore`: models, the `AgentBackend` protocol, `AppStore` (state, selection, layout, persistence), parsers (`UnifiedDiff`, `Markdown`), and `MockBackend`. No UI imports.
- `Sources/T3Bridge`: `T3Backend`. Installs the pinned T3 Code release, supervises `t3 serve`, authenticates, and maps the server's Effect RPC stream to OstraCore types.
- `Sources/Ostra`: the SwiftUI app. `App/` holds `AppModel` (UI state, the key router, menus, the camera). `Canvas/`, `HUD/`, `Chat/`, `Menus/`, `Workspace/`, `Settings/`, and `Design/` hold views.
- `Scripts/`: `bundle.sh` builds `dist/Ostra.app`; `snapshot.sh` scripts the app and captures its window.

## Rules that keep the design intact

- **Less is the brief.** At rest the HUD is the chat box and one button per corner. Before adding anything permanent, try the menu (`M`) or showing it only when relevant.
- **Glass is for controls, never content.** Agent cards and group regions are plain surfaces. Apple's guidance says the same: no Liquid Glass in the content layer, use it sparingly, keep it monochrome.
- **Color means something.** One accent (selection and the primary action). Status colors appear only in the status dot.
- **Type.** Geist for interface and reading text, Geist Mono for code. Use `Theme.ui`, `Theme.text`, and `Theme.mono`; don't call `.system` fonts.
- **The camera doesn't follow.** Selecting an agent or opening a panel never moves the canvas. `reveal` pans only for a card that's off-screen. `G` and `0` are the explicit camera keys.
- **Motion.** Read `Design/Motion.swift` first. Keyboard-driven changes that repeat all day don't animate (`Motion.instantly`). Entrances ease out and start near full size; exits are faster. Gestures use springs.
- **Chat patterns** follow shadcn's AI Elements (`vercel/ai-elements`): check that source before inventing a pattern.

## Keyboard model

`AppModel+Keys.swift` owns it. One local event monitor routes every key press: Command and Control shortcuts first, then the open overlay, then text editing, then command mode. Add a key in one place: the `switch` in `handleCommandCharacter`, plus an entry in `ShortcutCatalog`.

## Engine

- `AgentBackend` is the only seam between the app and the engine. Keep T3 types inside `T3Bridge`.
- T3 Code is pinned in `T3Configuration.version`. The wire format is Effect RPC over a JSON WebSocket; the bridge decodes leniently through `JSONValue`, so unknown fields never break it.
- Set `OSTRA_T3_BINARY` to a `t3` binary to skip the download, and `OSTRA_SUPPORT_DIR` to keep a development run away from real state.

## Verify changes

```bash
swift build
swift test
Scripts/snapshot.sh /tmp/shots "wait:2.6 key:tab key:space wait:1.5" chat:4.5
```

Look at the captured image after any visual change. Scripted runs use the simulated engine unless `OSTRA_LIVE=1`, stay in the background, and don't save settings. Real agent runs cost provider usage: use the cheapest model (`model:codex/gpt-5.6-luna`) and short prompts.

## Writing

Code comments, commit messages, and docs follow the Google developer documentation style: second person, active voice, present tense, sentence-case headings.
