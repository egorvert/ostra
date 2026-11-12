# Ostra

A native macOS coding-agent harness: agents on a canvas, a Liquid Glass HUD, and T3 Code as the engine. See `README.md` for what it does and how to run it.

## Layout

- `Sources/OstraCore`: models, the `AgentBackend` protocol, `AppStore` (state, selection, layout, persistence), parsers (`UnifiedDiff`, `Markdown`), and `MockBackend`. No UI imports.
- `Sources/T3Bridge`: `T3Backend`. Installs the pinned T3 Code release, supervises `t3 serve`, authenticates, and maps the server's Effect RPC stream to OstraCore types.
- `Sources/Ostra`: the SwiftUI app. `App/` holds `AppModel` (UI state, the key router, menus, the camera) and `Keymap` (every shortcut). `Canvas/`, `HUD/`, `Chat/`, `Menus/`, `Workspace/` (the code panel), `Settings/`, and `Design/` hold views.
- `Scripts/`: `bundle.sh` builds `dist/Ostra.app`; `snapshot.sh` scripts the app and captures its window.

## Rules that keep the design intact

- **Less is the brief.** At rest the HUD is the chat box and one button per corner. The code panel opens on the side the settings choose; the menu and the status pane take the other side. Before adding anything permanent, try the menu (`M`) or showing it only when relevant.
- **Everything that floats is glass.** The HUD, agent cards, and project regions are Liquid Glass, so they show over any background. What sits inside a panel (the conversation, a diff, a file) stays plain. Keep glass monochrome.
- **Cards share one `GlassEffectContainer`.** A container draws its glass above everything else in it, so anything that must show over a card (the selection ring, the status dot) goes in `AgentCardAdornment`, a layer above the container. Project regions stay outside the container, or the cards melt into them.
- **Ink follows the backdrop.** `adaptiveTone(over:)` gives a node dark or light glass and text from the brightness of the canvas behind it. Put glass and text under the same modifier.
- **Color means something.** One accent (selection and the primary action). Status colors appear only in the status dot.
- **Type.** Geist for interface and reading text, Geist Mono for code. Use `Theme.ui`, `Theme.text`, and `Theme.mono`; don't call `.system` fonts for text. Sizes come from one scale: 11, 12, 13, 14, and 16 for Geist; 10, 11, and 12 for Geist Mono. No half sizes.
- **Spacing and corners.** Spacing sits on a 4-point grid, and panel content starts 20 points from the edge. A row inside a rounded surface takes the surface's radius less its inset, so the corners stay concentric.
- **The camera doesn't follow.** Selecting an agent or opening a panel never moves the canvas. `reveal` pans only for a card that's off-screen. `G` and `0` are the explicit camera keys.
- **The chat stays put.** The dock stays in the middle of the window while an open code panel leaves room, and moves only as far as the panel needs (`AppModel.dockPlacement`). It hangs from the bottom of the window: when the pane changes height, for a tab, an agent, or a message, its top edge moves and its bottom edge stays. The pane's height and the request bar's room follow their targets in transactions of their own (`shownPaneHeight`, `shownRequestRoom`), so frames animate while content swaps at once.
- **Cards don't overlap.** `AppStore.drag` keeps a dragged card `CanvasLayout.cardGap` clear of every other card; it slides along the card it meets.
- **Motion.** Read `Design/Motion.swift` first. Panels animate however they open, with springs that have no bounce. Changes that repeat all day don't animate: moving the selection, cycling agents, and search opened with a key. Two exceptions: menus rise from below and fade in on a fast ease-out, however they open, and the chat pane cross-fades to another agent's or tab's content (`AnyTransition.crossfade`) while its height morphs. Entrances start near full size, exits are faster, and bounce is for things the pointer threw. Every entrance is a `Materialize` transition, which drops movement when Reduce Motion is on.
- **The chat box has one form.** It always shows its text and its footer. Don't add a collapsed state.
- **Chat patterns** follow shadcn's AI Elements (`vercel/ai-elements`): check that source before inventing a pattern.
- **Conversation text is one selectable view per run.** `MarkdownView` draws paragraphs, lists, and quotes that sit together as one `SelectableText` (an `NSTextView`), so a drag selects across them. Don't put `.textSelection` on individual `Text` views in the conversation.

## Keyboard model

`Keymap.swift` lists every command with its default keys, and the user can change them from the shortcuts sheet (`?`). `AppModel+Keys.swift` routes every key press through one local event monitor: a shortcut being recorded first, then an open name editor, then the open overlay, then the terminal, then text editing, then command mode. While the chat box has the keyboard, only chords with Command or Control run commands, and so does Tab.

A key means one thing. A menu row shows the key of the command it runs, and that key does the same thing with the menu closed; choices in a list take numbers. To add a command, add a case to `Command` with its title and default keys, handle it in `perform(_:)`, and list it in `ShortcutCatalog`.

Command and a number always switch the chat's tabs, and Option and a number always switch the code panel's tools, in every mode. Each opens its pane when it's closed, and each tab shows its key. Plain numbers pick an answer to a pending question.

Everything the app can do is also an `Action` in `AppModel+Search.swift`, which feeds global search (Command-K). Add new commands there too.

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

Look at the captured image after any visual change. To study a transition, set `OSTRA_MOTION_SCALE=6` and capture several frames a few tenths of a second apart. Scripted runs use the simulated engine unless `OSTRA_LIVE=1`, stay in the background, and don't save settings. Real agent runs cost provider usage: use the cheapest model (`model:codex/gpt-5.6-luna`) and short prompts.

## Writing

Code comments, commit messages, and docs follow the Google developer documentation style: second person, active voice, present tense, sentence-case headings.
