# DisplayMemo

A macOS menu-bar utility that remembers your display arrangement so you don't have to reconfigure it every time.

## Problem

Every time you connect an external monitor, macOS forgets how you had your displays arranged:

- Which display is on the left vs right
- Which display is above or below
- Which display is "Main" (has the menu bar and dock)

You end up going to **System Settings → Displays → Arrange** over and over again.

## Solution

DisplayMemo saves your preferred arrangement once and automatically restores it whenever you connect monitors.

1. Arrange your displays how you like them in System Settings
2. Click **Save as Default Arrangement** in DisplayMemo
3. Done — next time you connect, it just works

## Features

- **Menu-bar only** — Lives in your menu bar, no dock icon
- **Automatic restore** — Applies your saved layout when displays connect
- **Manual restore** — One-click restore if needed
- **Detects manual changes** — If you rearrange displays yourself, it won't fight you
- **Launch at login** — Start automatically with your Mac

## Installation

### Building from Source

```bash
./build.sh
```

Copy `dist/DisplayMemo.app` to your Applications folder.

## Usage

Click the display icon in your menu bar:

| Menu Item | Description |
|-----------|-------------|
| **Save as Default Arrangement** | Saves current display positions |
| **Apply Default Arrangement** | Manually restore saved layout |
| **Clear Custom Arrangement** | Stop ignoring auto-restore (appears after manual changes) |
| **Clear Default Arrangement** | Delete saved layout |
| **Launch at Login** | Auto-start with macOS |

## How It Works

1. When you save, DisplayMemo records each display's position and resolution
2. When displays connect, it waits for the connection to stabilize (2 second debounce)
3. It matches saved displays to connected displays by resolution
4. It applies the saved positions using macOS display configuration APIs

If you manually rearrange displays after a restore, DisplayMemo notices and stops auto-restoring until you clear the custom arrangement or save a new default.

## Requirements

- macOS 13.0+
- Xcode (for building)

## Limitations

- Saves one arrangement (not multiple profiles)
- Doesn't enforce resolution or refresh rate
- Doesn't handle mirrored displays

## License

MIT
