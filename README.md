# Ostra

Ostra is a native macOS app for running coding agents. Agents sit on a canvas as glass cards. A Liquid Glass chat box at the bottom of the window talks to the selected agent, and starts a new agent when none is selected.

The agents run on [T3 Code](https://github.com/pingdotgg/t3code). Ostra runs a local T3 Code server in the background and draws its own interface on top of it.

## Requirements

- macOS 26 or later, on Apple silicon
- Xcode 26 or later, for the Swift toolchain
- At least one agent provider installed and signed in: Codex (`codex login`) or Claude Code (`claude auth login`)

## Build and run

To build the app and open it:

```bash
Scripts/bundle.sh --open
```

The script builds a release binary and assembles `dist/Ostra.app`.

To run from source during development:

```bash
swift run Ostra
```

To try the interface without a provider, use the simulated engine:

```bash
swift run Ostra --demo
```

The first launch on the real engine downloads the pinned T3 Code release (about 115 MB) into `~/Library/Application Support/Ostra`, verifies its checksum, and starts it. Ostra keeps its own T3 Code data directory, so it doesn't touch an existing T3 Code install.

## Using Ostra

Ostra is keyboard-first and modal:

- While the chat box has focus, keys type text. Press **Esc** to leave.
- Otherwise, single keys are commands. Press **Return** to type.

You don't have to memorize shortcuts. Press **M** for the menu; every menu shows its keys, and a key does the same thing whether a menu is open or not.

| Key | Action |
| --- | --- |
| `A` | Start a new agent |
| `S` | Select an agent by name |
| `D` | Archive the selected agent. Press `Z` to undo. |
| `M` | Open the menu |
| `R` | Rename the selected agent. Double-clicking a name does the same. |
| `C` | Open the code panel: diff, files, terminal, and activity |
| `P` | Choose the project for new agents |
| `⌘K` | Search everything: agents, actions, projects, files, and messages |
| `Tab` | Go to the next agent, even while you type. `F` changes which agents `Tab` visits. |
| `Space` | Open or close the chat |
| `Y` / `N` | Approve or deny what the agent asks for |
| `⌘1` – `⌘3` | Switch the chat's tabs, even while you type. Each tab shows its key. |
| `⌥1` – `⌥4` | Switch the code panel's tools: diff, files, terminal, and activity |
| `⌘V` | Paste text, images, or files into the message |
| `\` | Split the chat to show two agents side by side |

To change a shortcut, press **?** for the shortcuts sheet, click the shortcut, and press the new keys.

To start an agent, deselect everything, type a task in the chat box, and press **Return**. The agent starts in the highlighted project.

To send files or images with a message, paste them, drop them on the window, or click **+** in the chat box. Long pasted text becomes an attachment, so the message stays readable.

To change the canvas background, the glass, or the side the code panel opens on, press **,** for Settings.

## How it's built

The package has three targets:

- `OstraCore`: domain models, the `AgentBackend` protocol, and the app's state. It has no UI code.
- `T3Bridge`: the T3 Code engine. It installs and supervises the server and speaks its WebSocket RPC.
- `Ostra`: the SwiftUI app.

The app talks to agents only through `AgentBackend`, so a different engine can replace T3 Code without changes to the interface. `MockBackend` implements the same protocol for demo mode and tests.

## Develop

Run the tests:

```bash
swift test
```

The live engine test starts a real server and a real agent run, so it's off by default. To run it, set `OSTRA_T3_LIVE=1`.

To check the interface after a change, script the app and capture its window:

```bash
Scripts/snapshot.sh /tmp/shots "wait:2.6 key:tab key:space wait:1.5" chat:4.5
```

## Credits

- [T3 Code](https://github.com/pingdotgg/t3code), MIT License
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), MIT License
- [Geist](https://vercel.com/font) and Geist Mono, SIL Open Font License 1.1
