<p align="center">
  <img src="icon.png" width="128" height="128" alt="DisplayMemo icon">
</p>

# DisplayMemo

A macOS menu-bar utility that remembers your display arrangement so you don't have to reconfigure it every time.

## Problem

When you connect an external monitor, macOS doesn't know where you want it positioned. It just picks a default. So every time you plug in, you have to:

1. Open **System Settings → Displays → Arrange**
2. Drag displays to the right positions
3. Set which one is "Main" (menu bar and dock)

This gets old fast if you switch monitors regularly.

<p>
<img width="400" height="auto" alt="image" src="https://github.com/user-attachments/assets/69a41a1d-1eff-451a-9103-a68eb779e0a9" />
</p>

## Solution

DisplayMemo saves your preferred arrangement once and automatically restores it whenever you connect monitors.

1. Arrange your displays how you like them in System Settings
2. Click **Save as Default Arrangement** in DisplayMemo
3. Done — next time you connect, it just works

<p>
  <img width="400" height="auto" alt="image" src="https://github.com/user-attachments/assets/a721dcb1-b4a1-4c50-98e1-5499bf7f7a16" />
</p>

## Features

- **Menu-bar only** — Lives in your menu bar, no dock icon
- **Automatic restore** — Applies your saved layout when displays connect
- **Manual restore** — One-click restore if needed
- **Detects manual changes** — If you rearrange displays yourself, it won't fight you
- **Launch at login** — Start automatically with your Mac

## Installation

### Download

1. Download the latest `.zip` from [Releases](../../releases)
2. Unzip and drag `DisplayMemo.app` to your Applications folder
3. Double-click to open — macOS will show a warning
4. Open **System Settings → Privacy & Security**, scroll down to Security
5. Click **Open Anyway**, then enter your password

You only need to do this once.

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
