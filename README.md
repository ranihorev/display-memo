# DisplayMemo

A macOS menu-bar utility that automatically restores display arrangements when the same combination of monitors is reconnected.

## Problem

macOS sometimes forgets:
- Physical display positions (left/right/above/below)
- Which display is the "Main Display" (white menu bar)

This is especially common when reconnecting through docks or hubs.

## Solution

1. Connect your monitors
2. Arrange them in **System Settings → Displays**
3. Click **Save Current Arrangement for This Setup** in DisplayMemo
4. Later, when the same monitors are detected, DisplayMemo restores the saved arrangement automatically

## Features

- **Menu-bar only** - No dock icon, no main window
- **Automatic restore** - Detects when monitors reconnect and restores layout
- **Manual restore** - One-click restore from the menu
- **Smart display matching** - Identifies displays by vendor/model ID
- **Handles identical monitors** - Uses proximity-based matching for duplicate displays
- **Launch at login** - Optional auto-start on macOS 13+
- **Resilient** - Debounce and stability checks handle dock connection event storms

## Requirements

- macOS 13.0 or later
- Xcode (for building)

## Building

```bash
./build.sh
```

The built app will be at `dist/DisplayMemo.app`.

### Manual Build

```bash
xcodebuild -scheme DisplayMemo \
  -configuration Release \
  -derivedDataPath .build \
  build
```

## Installation

1. Build the app using the instructions above
2. Copy `dist/DisplayMemo.app` to your Applications folder
3. Launch DisplayMemo
4. (Optional) Enable "Launch at Login" from the menu

## Usage

### Menu Options

- **Status row** - Shows "Active: \<Profile Name\>" or "Unknown Configuration"
- **Save Current Arrangement for This Setup** - Saves the current display layout
- **Restore Saved Arrangement Now** - Manually restores the saved layout
- **Auto-Restore on Connection** - Toggle automatic restoration (default: On)
- **Delete Saved Profile for This Setup** - Removes the saved profile
- **Launch at Login** - Toggle auto-start
- **Quit DisplayMemo** - Exit the application

### How It Works

1. DisplayMemo observes display configuration changes
2. When monitors are connected, it computes a "signature" based on vendor/model IDs
3. If a saved profile matches the signature, it restores the arrangement
4. Display origins are normalized relative to the main display for consistent restoration

## Technical Details

- **Display Identity**: Displays are identified by VendorID + ModelID only (no serial numbers)
- **Profile Storage**: `~/Library/Application Support/DisplayMemo/profiles.json`
- **Atomic Writes**: Profiles are written atomically to prevent corruption
- **Event Handling**: 2-second debounce with stability gate prevents multiple restore attempts

## Limitations (V1)

- No resolution/refresh rate enforcement
- No rotation enforcement
- No mirroring configuration support
- One profile per display configuration

## License

MIT License
