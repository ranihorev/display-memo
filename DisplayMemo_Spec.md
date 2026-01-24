# DisplayMemo — Product & Technical Specification (Agent-Ready)

> **Purpose of this document:** Provide a complete, implementation-ready spec that an LLM coding agent can use to generate the macOS app in one pass.

---

## Table of Contents
1. [Product Overview](#1-product-overview)  
2. [User Experience](#2-user-experience)  
3. [Technical Choices](#3-technical-choices)  
4. [Functional Requirements](#4-functional-requirements)  
5. [Data Model](#5-data-model)  
6. [Persistence](#6-persistence)  
7. [Display Observation](#7-display-observation)  
8. [Snapshot](#8-snapshot-recorder)  
9. [Restore](#9-restore-restorer)  
10. [Error Handling & User Feedback](#10-error-handling--user-feedback)  
11. [Permissions & Privacy](#11-permissions--privacy)  
12. [Logging & Diagnostics](#12-logging--diagnostics)  
13. [Non-Goals](#13-non-goals-v1-scope-limits)  
14. [Project Structure](#14-project-structure-deliverables)  
15. [Acceptance Criteria](#15-acceptance-criteria)  
16. [Agent Coding Prompt](#16-agent-coding-prompt-drop-in)

---

## 1. Product Overview

### 1.1 Goal
A **macOS menu-bar utility** that automatically restores a saved **display arrangement** (relative positions + which display is **Main**) whenever the same **combination of monitor models** is connected again.

### 1.2 Problem
macOS sometimes forgets:
- physical display positions (left/right/above/below), or
- which display is “Main Display” (white menu bar)

…especially when reconnecting through docks/hubs.

### 1.3 Solution
The user:
1. Connects monitors.
2. Fixes arrangement in **System Settings → Displays**.
3. Clicks **Save Current Arrangement for This Setup** in DisplayMemo.
4. Later, when that same set of monitors is detected, DisplayMemo restores the saved arrangement automatically (or via manual restore).

### 1.4 Identity Constraint
**Do not use serial numbers.**  
Displays are identified **only** by **VendorID + ModelID**.

If two monitors share the same VendorID/ModelID, they are **interchangeable**.

---

## 2. User Experience

### 2.1 App Surface Area
- **Menu-bar only**
- No Dock icon
- No main window

**Info.plist requirement:**  
- `LSUIElement = true`

### 2.2 Menu Contents
1. **Status (disabled menu row)**
   - `Active: <Profile Name>` OR `Unknown Configuration`
2. **Save**
   - `Save Current Arrangement for This Setup`
3. **Restore**
   - `Restore Saved Arrangement Now`
4. **Toggle**
   - `Auto-Restore on Connection` (Default: **On**)
5. **Delete**
   - `Delete Saved Profile for This Setup` (enabled only if current signature exists)
6. *(Optional, recommended)* **Toggle**
   - `Launch at Login` (Default: Off, macOS 13+)
7. **Quit**
   - `Quit DisplayMemo`

### 2.3 Notifications
Optional (recommended):
- On Save: “Layout saved for <Profile Name>”
- On Auto-Restore success/failure: “Layout restored” / “Restore failed”

If notifications are not authorized:
- Do not block functionality.
- Fall back to updating the status row and logging.

### 2.4 Profile Naming (V1)
- Each saved profile has a `displayName`.
- Default displayName generation:
  - `"<N> Displays"` or `"Built-in + <N-1> External"`
- No UI for renaming in V1.

### 2.5 Overwrite Behavior
- Saving when a profile exists for the same signature **overwrites** it.
- Notification/message should say “Updated” rather than “Saved” when overwriting.

---

## 3. Technical Choices

### 3.1 Tech Stack
- **Swift 5.9+**
- **macOS 13.0+** (recommended for modern login items; can be lowered if needed)
- **Frameworks**
  - AppKit (menu bar)
  - CoreGraphics / Quartz Display Services (display APIs)
  - Foundation (Codable, file I/O)
  - os.log (Logger) (recommended)
  - UserNotifications (optional)
  - ServiceManagement / SMAppService (optional, launch at login)

### 3.2 UI Framework Choice: AppKit vs SwiftUI
**Pick: AppKit**

**Short rationale:**  
This app is a classic **NSStatusItem** menu-bar utility with a non-windowed lifecycle. AppKit provides the most direct and stable primitives for this pattern and avoids SwiftUI `MenuBarExtra` lifecycle quirks and version-specific behavior. SwiftUI adds complexity here without a meaningful benefit.

---

## 4. Functional Requirements

### 4.1 Save Current Arrangement
When user selects **Save Current Arrangement for This Setup**:
- Read current active display list and geometry.
- Compute configuration signature.
- Save/overwrite profile under that signature.
- Update menu status to `Active: <displayName>`.

### 4.2 Restore Saved Arrangement (Manual)
When user selects **Restore Saved Arrangement Now**:
- Compute current signature.
- If profile exists and connected display count matches, restore arrangement in one transaction.
- Otherwise abort with a clear status/notification.

### 4.3 Auto-Restore
When enabled:
- On stable hardware/display topology change, compute signature.
- If matching profile exists, attempt restore automatically.
- Do not attempt partial restore. If display count differs, abort.

---

## 5. Data Model

### 5.1 Monitor Identity (Key)
Displays are identified only by vendor+model:

```swift
struct MonitorIdentity: Codable, Hashable {
  var vendorID: UInt32
  var modelID: UInt32
  var signature: String { "\(vendorID):\(modelID)" }
}
```

### 5.2 Configuration Signature
A configuration signature is built from the **multiset** of connected displays:
1. Build `[String]` of `MonitorIdentity.signature`
2. Sort lexicographically
3. Join with `"|"`

Duplicates are preserved.

Example:
- `"610:2201|610:2201|1552:9923"`

### 5.3 Profiles File (Versioned)
Use a versioned container to allow schema migration later:

```swift
struct ProfilesFile: Codable {
  var schemaVersion: Int = 1
  var profilesBySignature: [String: DisplayLayoutProfile]
}
```

### 5.4 Profile
```swift
struct DisplayLayoutProfile: Codable {
  var signature: String
  var displayName: String
  var createdAt: Date
  var updatedAt: Date
  var displays: [DisplayNode]   // one per display in this configuration
}
```

### 5.5 Display Node
Store **normalized** coordinates relative to the main display:

```swift
struct DisplayNode: Codable {
  var modelSignature: String    // vendor:model

  // Main display flag
  var isMain: Bool

  // Normalized origin (main display is always (0,0))
  var originX: Int32
  var originY: Int32

  // Debug/validation fields (not enforced in V1)
  var pixelWidth: Int32
  var pixelHeight: Int32
  var isBuiltin: Bool
}
```

---

## 6. Persistence

### 6.1 Location
Store in Application Support:

- `~/Library/Application Support/DisplayMemo/profiles.json`

### 6.2 Write Semantics
- Writes must be **atomic**:
  - write to `profiles.json.tmp`
  - rename to `profiles.json`

### 6.3 Corruption Handling
If JSON decode fails:
- Rename the file to `profiles.json.corrupt.<timestamp>`
- Start with an empty profile store
- Log error

---

## 7. Display Observation

### 7.1 Observer API
Use:
- `CGDisplayRegisterReconfigurationCallback`

### 7.2 Event Filtering (Topology Only)
Not every callback should trigger restore.

**Trigger Auto-Restore only on topology-affecting changes**, such as:
- display added/removed
- desktop shape changed
- mirror/unmirror changes

Avoid reacting to events caused by user rearranging in Settings or by the app itself.

### 7.3 Debounce + Stability Gate
Connections via docks can emit many rapid callbacks.

**Required behavior:**
1. On relevant observer event, schedule a debounce timer: **2.0 seconds**
2. When debounce fires, run stability gate:
   - compute signature
   - wait 250ms
   - compute signature again
   - proceed only if both signatures match

### 7.4 Re-entrancy Suppression
Restoring triggers callbacks; prevent loops.

- `isApplyingConfiguration = true` while applying
- ignore observer events while true
- after applying, keep a **cooldown** of ~1.0s before accepting events

### 7.5 Concurrency Rules
- All display operations run on a **single serial queue** (e.g. `"DisplayMemo.DisplayQueue"`)
- UI updates always on the main queue

---

## 8. Snapshot (Recorder)

### 8.1 Enumerate Active Displays
- Use `CGGetActiveDisplayList`
- For each display ID:
  - Vendor/Model: `CGDisplayVendorNumber`, `CGDisplayModelNumber`
  - Bounds: `CGDisplayBounds(displayID)` (origin and size)
  - Built-in: `CGDisplayIsBuiltin(displayID)` (if available)
  - Use bounds width/height as pixel dims for debug/validation fields

### 8.2 Determine Main Display
- Use `CGMainDisplayID()`
- `isMain = (displayID == mainID)`

### 8.3 Normalize Coordinates
Let:
- `mainOrigin = CGDisplayBounds(mainID).origin`

For each display:
- `originX = bounds.origin.x - mainOrigin.x`
- `originY = bounds.origin.y - mainOrigin.y`

This ensures saved coordinates are stable relative to the saved main display.

### 8.4 Snapshot Validity
If the snapshot does not contain **exactly one** `isMain == true`, abort save and show a failure message.

---

## 9. Restore (Restorer)

### 9.1 Preconditions (Hard Requirements)
Before attempting restore:
- Compute current signature.
- Must exist in profile store.
- Current display count must equal saved display count.
  - Otherwise abort (no partial apply).
- Saved profile must contain exactly one main display node.
- If mirroring is detected, abort (V1 doesn’t handle mirroring).

### 9.2 Mapping Saved Nodes → Live Displays
Because we ignore serial numbers:
- Match on `modelSignature` (vendor:model)
- For identical monitors, avoid unnecessary swaps using **greedy-by-proximity**.

**Greedy-by-proximity algorithm:**
1. Build `liveDisplays[]` with:
   - displayID
   - modelSignature
   - current normalized origin (normalize live bounds relative to current main)
2. For each `savedNode` in saved profile:
   - among unused live displays with matching modelSignature, choose the one minimizing:
     - `abs(liveX - targetX) + abs(liveY - targetY)`
   - if none exist, abort restore

### 9.3 Transactional Apply
Apply all origins in a single configuration transaction:

1. `CGBeginDisplayConfiguration(&configRef)`
2. For each mapped pair:
   - target absolute origin is:
     - savedNode `(originX, originY)` where main is (0,0)
   - call `CGConfigureDisplayOrigin(configRef, displayID, targetX, targetY)`
3. Commit:
   - try `.permanently`
   - if fails, retry once with `.forSession`
4. On any abort mid-flight:
   - call `CGCancelDisplayConfiguration(configRef)`

### 9.4 Main Display Guarantee
- Ensure the mapped display corresponding to the saved main node is assigned to `(0,0)`
- All other displays use their saved normalized coordinates

### 9.5 Post-Apply Verification + One Retry
After commit:
- Re-read display bounds and normalize against the new main display origin
- Verify each mapped display is within ±1 px of target
- If mismatch:
  - schedule **one** retry after ~750ms
  - do not retry more than once (avoid loops)

---

## 10. Error Handling & User Feedback

### 10.1 Status + Menu Enablement
- If no profile for current signature:
  - status: `Unknown Configuration`
  - restore/delete disabled (or restore shows a message)
- If profile exists:
  - status: `Active: <displayName>`

### 10.2 Common Failures
- **Count mismatch**: abort restore; message “Display count differs from saved profile”
- **Missing match** (mapping fails): abort restore; message “Unable to map displays for this setup”
- **Mirroring detected**: abort restore; message “Mirroring not supported in V1”
- **Configuration apply error**: abort; message “Restore failed. Check permissions.”

### 10.3 No Partial Apply
If anything doesn’t line up (count mismatch, mapping failure, invalid profile), do **not** attempt partial placement.

---

## 11. Permissions & Privacy

### 11.1 Accessibility Guidance
In many environments display reconfiguration works without asking, but failures can happen.

If restore fails repeatedly:
- Provide a menu item: `Help → Permissions`
- It should instruct the user to enable:
  - **System Settings → Privacy & Security → Accessibility → DisplayMemo**

### 11.2 Notifications
If using notifications:
- Request authorization lazily (on first attempt to notify).
- If denied, continue without notifications.

---

## 12. Logging & Diagnostics

### 12.1 Logging
Use `Logger` (os.log) with a stable subsystem/category, e.g.:
- `subsystem = "com.yourcompany.DisplayMemo"`
- categories:
  - `"Observer"`, `"Snapshot"`, `"Restore"`, `"Store"`

Log:
- observer event flags (raw bitmask)
- computed signatures
- profile save/overwrite
- restore mapping decisions (which live display matched which target)
- config transaction results and retry decision
- final verification results

### 12.2 Debug Aids (Optional)
Optional menu item (debug builds only):
- `Copy Debug Report`
  - includes current signature, live display list (vendor/model/bounds), and whether a profile exists.

---

## 13. Non-Goals (V1 Scope Limits)
- No resolution / refresh rate enforcement
- No rotation enforcement
- No mirroring configuration support
- No serial-number identity, no port identity
- No profile renaming UI
- No multi-profile per signature (exactly one per signature in V1)

---

## 14. Project Structure (Deliverables)

### 14.1 Required Files
- `AppDelegate.swift`
  - creates `NSStatusItem`, builds menu, wires actions
- `DisplayManager.swift`
  - observer registration, debounce + stability gate
  - snapshot + restore
  - serial queue, re-entrancy suppression
- `ProfileStore.swift`
  - load/save JSON, atomic writes, schemaVersion
  - CRUD: get/save/delete by signature
- `Models.swift`
  - Codable structs
- Optional:
  - `NotificationManager.swift`
  - `LoginItemManager.swift` (macOS 13+)

### 14.2 Build Settings / Entitlements
- Set `LSUIElement = true`
- If using Launch at Login:
  - implement using `SMAppService` (macOS 13+)
- Avoid sandboxing for V1 unless validated (system utility behavior can be constrained)

---

## 15. Acceptance Criteria

### 15.1 Core Scenarios
1. **Save + Auto-Restore**
   - Given monitors A+B are connected and arranged, when user saves,
   - then disconnect/reconnect (or dock connect),
   - app restores positions and main display after topology stabilizes.

2. **Manual Restore**
   - Given a saved profile exists, when user clicks Restore,
   - then arrangement is applied (or clearly fails with message).

3. **No Partial Apply**
   - Given saved profile has 3 displays but only 2 are connected,
   - restore must not apply anything and must show a clear message.

4. **Identical Monitors**
   - Given two identical external monitors,
   - restore should minimize swapping using proximity mapping.

5. **Event Storm Resilience**
   - Dock connection causes multiple callbacks,
   - debounce + stability gate ensures only one restore attempt.

### 15.2 UX Requirements
- App has no Dock icon.
- Quit is always accessible in the menu.
- Status reflects active vs unknown configuration.

---

## 16. Agent Coding Prompt (Drop-in)

Copy/paste the following into your coding agent:

> Build a macOS 13+ menu-bar-only app named “DisplayMemo” in Swift 5.9 using **AppKit** and Quartz Display Services.  
> 
> UI requirements:  
> - Set `LSUIElement = true` in Info.plist (no Dock icon).  
> - Use `NSStatusItem` with a menu (no main window).  
> - Menu items: status row (Active/Unknown), Save, Restore, Auto-Restore toggle (default ON), Delete profile for this setup, Quit. Optional: Launch at Login toggle.  
> 
> Core behavior:  
> - Observe display changes with `CGDisplayRegisterReconfigurationCallback`.  
> - Filter to topology-affecting events (add/remove/desktop shape/mirror changes).  
> - Debounce 2.0 seconds; then run a stability gate: compute signature twice 250ms apart; proceed only if identical.  
> - Suppress re-entrant callbacks during restore (`isApplyingConfiguration` + 1s cooldown).  
> 
> Identity constraint:  
> - Do NOT use serial numbers. Identify displays only by VendorID + ModelID (`vendor:model`).  
> - Signature is sorted multiset join with duplicates preserved (e.g. `"610:2201|610:2201|1552:9923"`).  
> 
> Snapshot:  
> - Use `CGGetActiveDisplayList`, `CGDisplayBounds`, `CGDisplayVendorNumber`, `CGDisplayModelNumber`, `CGMainDisplayID`.  
> - Normalize display origins relative to main display origin; store main as (0,0).  
> - Save JSON to `~/Library/Application Support/DisplayMemo/profiles.json` with atomic writes and `schemaVersion`.  
> 
> Restore:  
> - Abort if saved profile not found, mirroring detected, or display count mismatch (no partial apply).  
> - Map saved nodes to live displays by `modelSignature` with greedy-by-proximity tie-breaker among identical monitors (distance = abs(dx)+abs(dy)).  
> - Apply arrangement transactionally: `CGBeginDisplayConfiguration` → `CGConfigureDisplayOrigin` for all displays → commit. Ensure saved-main mapped display is (0,0).  
> - Commit with `.permanently`, fallback once to `.forSession` on failure.  
> - Verify positions after commit and retry once after ~750ms if mismatch.  
> 
> Deliverables:  
> - Full Xcode project structure with AppDelegate.swift, DisplayManager.swift, ProfileStore.swift, Models.swift (and optional Notification/LoginItem managers).  
> - Code should be production-quality: clear comments, error handling, no global state, and all display operations on a dedicated serial queue.

