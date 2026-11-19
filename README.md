# TopPrompter

A free teleprompter for Mac that floats at the very top of your screen, right under your webcam. It sits above the menu bar and your browser tabs, follows your voice word by word, and can mirror to your iPhone.

**[Download TopPrompter.zip](../../releases/latest/download/TopPrompter.zip)**. Needs macOS 14 or later, on Apple silicon or Intel. No other software is needed.

## What it does

- **Sits above everything.** It floats over the menu bar, browser tabs and full-screen apps, as close to the lens as your screen allows. Drag it anywhere and resize it from the corner.
- **Follows your voice.** Follow mode matches what you say to the script and highlights the word you're on. Speed up, slow down or skip a line, and it keeps up.
- **Stops when you stop.** Go quiet and the text holds still.
- **iPhone as the screen.** Scan a QR code and your phone becomes a full-screen prompter, one sentence per line, kept in sync with the Mac.
- **Hidden from recordings.** Screen recordings, Zoom, Meet and OBS don't capture the prompter window.
- **Any mic, recognized on your Mac.** Pick your USB mic or audio interface from the Mic menu. Where your Mac supports it, speech is recognized on the Mac itself.

### Modes

| Mode | What it does |
|---|---|
| Manual | Scrolls at a steady speed you set. |
| Talk | Scrolls at your speed only while you're speaking. |
| Follow | Listens to your words and keeps your place. Use this for written scripts. |

Anything in `[brackets]` or `(parentheses)`, and take labels like `Z01` on their own line, shows in grey and is skipped when following your voice.

## Install

1. Download `TopPrompter.zip` from [Releases](../../releases/latest), unzip it and drag **TopPrompter** into **Applications**.
2. Open it. macOS will say it can't check the app, because it isn't from the App Store. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only do this once.
   Or run this in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/TopPrompter.app
   ```
3. The first time you press **Listen** in Talk or Follow, allow **Microphone** and **Speech Recognition**.
4. Click **Edit** (or press `E`), paste your script, press `Esc`, pick **Follow** and press **Listen**.

### iPhone

Put the iPhone on the same Wi-Fi as the Mac, click **iPhone** in the toolbar and scan the QR code. It opens in Safari. Tap **Hide** to clear the buttons, or **Mirror** for prompter glass. Keep the app open on the Mac, which does the listening.

### Privacy and security

- The app has no accounts, no analytics and no internet connection. Your script and settings stay on your Mac.
- The iPhone link only starts when you click **iPhone**. It's a small web server on your own network, locked with a random secret key that's only in the QR code. Any request without the key gets "Not found". Click **Turn Off iPhone Link** in the same window to stop it.
- The link uses plain HTTP on your local network, so use it on your home or studio Wi-Fi rather than open public Wi-Fi.

## Shortcuts

| Key | Action |
|---|---|
| `Space` | Play or pause |
| `↑` `↓` | Faster or slower |
| `←` `→` | Nudge back or forward a line |
| `+` `−` | Bigger or smaller text |
| `R` | Back to the top |
| `M` | Switch mode |
| `E` / `Esc` | Edit the script / finish editing |
| `⌃⌥P` | Play or pause from any app |
| `⌃⌥R` | Restart from any app |
| `⌃⌥↑` `⌃⌥↓` | Speed from any app |
| `⌃⌥M` | Switch mode from any app |

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app isn't required.

```bash
./build.sh
open TopPrompter.app
```

`build.sh` compiles a universal (Apple silicon + Intel) app with `swiftc` and signs it ad hoc.

### Files

| File | What it is |
|---|---|
| `main.swift` | The window, toolbar, scrolling, modes and shortcuts |
| `Follower.swift` | Matches what you said to the script |
| `Voice.swift` | Mic input, voice activity and speech recognition |
| `Phone.swift` | The local web server for the iPhone view |
| `phone.html` | The iPhone page |
| `tests/main.swift` | Unit tests for the follower (`swiftc tests/main.swift Follower.swift -o /tmp/t && /tmp/t`) |

The app also has a built-in self-test: `TopPrompter.app/Contents/MacOS/TopPrompter --selftest`.

## License

MIT
