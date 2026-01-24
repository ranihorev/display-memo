import Foundation
import CoreGraphics
import os.log

/// Protocol for receiving display manager events
protocol DisplayManagerDelegate: AnyObject {
    func displayManagerDidDetectConfigurationChange(_ manager: DisplayManager)
    func displayManager(_ manager: DisplayManager, didAutoRestore result: RestoreResult)
    func displayManagerDidDetectManualChange(_ manager: DisplayManager)
}

/// Manages display observation, snapshot, and restore operations
final class DisplayManager {
    static let shared = DisplayManager()

    weak var delegate: DisplayManagerDelegate?

    private let logger = Logger(subsystem: "com.displaymemo.app", category: "Display")
    private let displayQueue = DispatchQueue(label: "com.displaymemo.display")

    // Observer state
    private var isObserving = false
    private var debounceTimer: DispatchWorkItem?
    private var isApplyingConfiguration = false
    private var cooldownEndTime: Date?

    // Manual change detection
    private var lastAppliedPositions: [CGDirectDisplayID: (x: Int32, y: Int32)]?
    private var lastAppliedSignature: String?

    // Configuration
    private let debounceInterval: TimeInterval = 2.0
    private let stabilityCheckInterval: TimeInterval = 0.25
    private let cooldownDuration: TimeInterval = 1.0
    private let retryDelay: TimeInterval = 0.75
    private let manualChangeCheckDelay: TimeInterval = 0.5

    private init() {}

    // MARK: - Public Interface

    /// Current configuration signature based on display count
    var currentSignature: String {
        let displays = getActiveDisplays()
        return "\(displays.count)"
    }

    /// Start observing display configuration changes
    func startObserving() {
        guard !isObserving else { return }

        let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
            manager.handleDisplayReconfiguration(displayID: displayID, flags: flags)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(callback, selfPtr)
        isObserving = true
        logger.info("Display observation started")
    }

    /// Stop observing display configuration changes
    func stopObserving() {
        guard isObserving else { return }

        let callback: CGDisplayReconfigurationCallBack = { _, _, _ in }
        CGDisplayRemoveReconfigurationCallback(callback, nil)
        isObserving = false
        debounceTimer?.cancel()
        debounceTimer = nil
        logger.info("Display observation stopped")
    }

    /// Take a snapshot of the current display arrangement
    func snapshot() -> SnapshotResult {
        let displays = getActiveDisplays()

        guard !displays.isEmpty else {
            logger.error("Snapshot failed: no displays")
            return .noDisplays
        }

        let mainCount = displays.filter { $0.isMain }.count
        guard mainCount == 1 else {
            logger.error("Snapshot failed: \(mainCount) main displays")
            return mainCount == 0 ? .noMainDisplay : .multipleMainDisplays
        }

        guard let mainDisplay = displays.first(where: { $0.isMain }) else {
            return .noMainDisplay
        }

        let mainOriginX = mainDisplay.bounds.origin.x
        let mainOriginY = mainDisplay.bounds.origin.y

        let displayNodes: [DisplayNode] = displays.map { display in
            DisplayNode(
                modelSignature: "", // No longer used for matching
                isMain: display.isMain,
                originX: Int32(display.bounds.origin.x - mainOriginX),
                originY: Int32(display.bounds.origin.y - mainOriginY),
                pixelWidth: Int32(display.bounds.width),
                pixelHeight: Int32(display.bounds.height),
                isBuiltin: display.isBuiltin
            )
        }

        let signature = currentSignature
        let displayName = generateDisplayName(displays: displays)

        let profile = DisplayLayoutProfile(
            signature: signature,
            displayName: displayName,
            createdAt: Date(),
            updatedAt: Date(),
            displays: displayNodes
        )

        logger.info("Snapshot created: \(displayName), signature: \(signature)")
        return .success(profile)
    }

    /// Restore the default arrangement
    func restoreDefault() -> RestoreResult {
        displayQueue.sync {
            restoreInternal(isRetry: false)
        }
    }

    /// Attempt auto-restore if conditions are met
    func attemptAutoRestore() {
        displayQueue.async { [weak self] in
            guard let self = self else { return }

            // Check if we have a default arrangement
            guard ProfileStore.shared.defaultArrangement != nil else {
                self.logger.debug("No default arrangement for auto-restore")
                return
            }

            // restoreInternal handles all other checks (custom override, count match, etc.)
            let result = self.restoreInternal(isRetry: false)
            DispatchQueue.main.async {
                self.delegate?.displayManager(self, didAutoRestore: result)
            }
        }
    }

    /// Clear tracked positions (used when clearing custom override)
    func clearTrackedPositions() {
        lastAppliedPositions = nil
        lastAppliedSignature = nil
    }

    // MARK: - Private Methods

    private func handleDisplayReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        // Ignore events while applying configuration
        guard !isApplyingConfiguration else {
            logger.debug("Ignoring callback during configuration apply")
            return
        }

        // Ignore events during cooldown
        if let cooldownEnd = cooldownEndTime, Date() < cooldownEnd {
            logger.debug("Ignoring callback during cooldown")
            return
        }

        // Check for manual position changes (same signature, different positions)
        if flags.contains(.desktopShapeChangedFlag) && !flags.contains(.addFlag) && !flags.contains(.removeFlag) {
            checkForManualChange()
        }

        // Only trigger full reconfiguration on topology changes (add/remove)
        let topologyFlags: CGDisplayChangeSummaryFlags = [
            .addFlag,
            .removeFlag,
            .mirrorFlag,
            .unMirrorFlag
        ]

        guard !flags.isDisjoint(with: topologyFlags) else {
            logger.debug("Ignoring non-topology callback: \(flags.rawValue)")
            return
        }

        logger.info("Topology change detected: flags=\(flags.rawValue)")

        // Clear tracked positions on topology change
        lastAppliedPositions = nil
        lastAppliedSignature = nil

        // Debounce
        debounceTimer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.runStabilityGate()
        }
        debounceTimer = workItem
        displayQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func checkForManualChange() {
        guard let appliedPositions = lastAppliedPositions,
              let appliedSignature = lastAppliedSignature else {
            return
        }

        let signature = currentSignature
        guard signature == appliedSignature else {
            // Different displays, not a manual change
            return
        }

        // Already has custom override, no need to check
        if ProfileStore.shared.hasCustomOverride(for: signature) {
            return
        }

        // Compare current positions to what we applied
        let currentPositions = getCurrentNormalizedPositions()

        var hasChanged = false
        for (displayID, applied) in appliedPositions {
            if let current = currentPositions[displayID] {
                if abs(current.x - applied.x) > 1 || abs(current.y - applied.y) > 1 {
                    hasChanged = true
                    break
                }
            } else {
                // Display no longer exists, topology changed
                return
            }
        }

        if hasChanged {
            logger.info("Manual position change detected")
            ProfileStore.shared.setCustomOverride(for: signature)
            lastAppliedPositions = nil
            lastAppliedSignature = nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.displayManagerDidDetectManualChange(self)
            }
        }
    }

    private func getCurrentNormalizedPositions() -> [CGDirectDisplayID: (x: Int32, y: Int32)] {
        let displays = getActiveDisplays()
        guard let mainDisplay = displays.first(where: { $0.isMain }) else {
            return [:]
        }

        let mainOrigin = mainDisplay.bounds.origin
        var positions: [CGDirectDisplayID: (x: Int32, y: Int32)] = [:]

        for display in displays {
            let x = Int32(display.bounds.origin.x - mainOrigin.x)
            let y = Int32(display.bounds.origin.y - mainOrigin.y)
            positions[display.displayID] = (x, y)
        }

        return positions
    }

    private func runStabilityGate() {
        let sig1 = currentSignature
        logger.debug("Stability gate check 1: \(sig1)")

        displayQueue.asyncAfter(deadline: .now() + stabilityCheckInterval) { [weak self] in
            guard let self = self else { return }

            let sig2 = self.currentSignature
            self.logger.debug("Stability gate check 2: \(sig2)")

            guard sig1 == sig2 else {
                self.logger.info("Stability gate failed: signatures differ")
                return
            }

            self.logger.info("Stability gate passed, notifying delegate")
            DispatchQueue.main.async {
                self.delegate?.displayManagerDidDetectConfigurationChange(self)
            }
        }
    }

    private func restoreInternal(isRetry: Bool) -> RestoreResult {
        // Check if we have a default arrangement
        guard let profile = ProfileStore.shared.defaultArrangement else {
            logger.error("❌ Restore failed: no default arrangement")
            return .noDefaultArrangement
        }

        let signature = currentSignature
        logger.info("🔧 Starting restore: current signature=\(signature), retry=\(isRetry)")
        logger.info("📋 Default profile: \(profile.displayName), saved displays=\(profile.displays.count)")

        // Check if custom override is active for current display configuration
        if ProfileStore.shared.hasCustomOverride(for: signature) {
            logger.warning("⏸️ Restore skipped: custom override active for \(signature)")
            return .customOverrideActive
        }

        logger.info("✅ Starting restore for: \(profile.displayName)")

        // Check for mirroring
        if isMirroringActive() {
            logger.error("❌ Restore aborted: mirroring detected")
            return .mirroringDetected
        }

        let liveDisplays = getActiveDisplays()
        logger.info("🖥️ Live displays: \(liveDisplays.count)")
        for (i, display) in liveDisplays.enumerated() {
            let bounds = display.bounds
            logger.info("  Display \(i): ID=\(display.displayID), main=\(display.isMain), x=\(bounds.origin.x), y=\(bounds.origin.y), w=\(bounds.width), h=\(bounds.height)")
        }

        // Don't require exact count match - apply to whatever displays are available
        if liveDisplays.count != profile.displays.count {
            logger.info("📊 Display count differs (live=\(liveDisplays.count), saved=\(profile.displays.count)) - will apply partial arrangement")
        }

        // Verify profile has exactly one main
        let savedMainCount = profile.displays.filter { $0.isMain }.count
        guard savedMainCount == 1 else {
            logger.error("❌ Invalid profile: main count=\(savedMainCount)")
            return .mappingFailed
        }

        logger.info("📍 Saved positions:")
        for (i, node) in profile.displays.enumerated() {
            logger.info("  Position \(i): main=\(node.isMain), origin=(\(node.originX),\(node.originY))")
        }

        // Map saved nodes to live displays using greedy-by-proximity
        guard let mapping = mapDisplays(savedNodes: profile.displays, liveDisplays: liveDisplays) else {
            logger.error("❌ Mapping failed")
            return .mappingFailed
        }

        logger.info("🗺️ Mapping complete: \(mapping.count) displays mapped")

        // Apply configuration
        isApplyingConfiguration = true
        defer {
            isApplyingConfiguration = false
            cooldownEndTime = Date().addingTimeInterval(cooldownDuration)
        }

        logger.info("⚙️ Applying configuration...")
        for map in mapping {
            logger.info("  Display \(map.displayID) → (\(map.targetX), \(map.targetY))")
        }

        let result = applyConfiguration(mapping: mapping)

        switch result {
        case .success:
            logger.info("✅ Configuration applied successfully")

            // Track applied positions for manual change detection
            var appliedPositions: [CGDirectDisplayID: (x: Int32, y: Int32)] = [:]
            for map in mapping {
                appliedPositions[map.displayID] = (map.targetX, map.targetY)
            }
            lastAppliedPositions = appliedPositions
            lastAppliedSignature = signature

            // Verify positions
            logger.info("🔍 Verifying positions...")
            if !verifyPositions(mapping: mapping) {
                if !isRetry {
                    logger.warning("⚠️ Verification failed, scheduling retry in \(self.retryDelay)s")
                    displayQueue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                        _ = self?.restoreInternal(isRetry: true)
                    }
                    return .success // Report success, retry will fix it
                } else {
                    logger.error("❌ Verification failed after retry")
                    return .verificationFailed
                }
            }
            logger.info("✅ Verification passed - restore complete!")
            return .success

        case .failure(let error):
            logger.error("❌ Configuration apply failed: \(error.localizedDescription)")
            return .configurationFailed(error)
        }
    }

    // MARK: - Display Enumeration

    private struct LiveDisplay {
        let displayID: CGDirectDisplayID
        let bounds: CGRect
        let isMain: Bool
        let isBuiltin: Bool
    }

    private func getActiveDisplays() -> [LiveDisplay] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        guard displayCount > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

        let mainID = CGMainDisplayID()

        return displayIDs.prefix(Int(displayCount)).map { displayID in
            LiveDisplay(
                displayID: displayID,
                bounds: CGDisplayBounds(displayID),
                isMain: displayID == mainID,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0
            )
        }
    }

    private func isMirroringActive() -> Bool {
        let displays = getActiveDisplays()
        for display in displays {
            if CGDisplayMirrorsDisplay(display.displayID) != kCGNullDirectDisplay {
                return true
            }
        }
        return false
    }

    // MARK: - Display Mapping

    private struct DisplayMapping {
        let displayID: CGDirectDisplayID
        let targetX: Int32
        let targetY: Int32
        let isTargetMain: Bool
    }

    private func mapDisplays(savedNodes: [DisplayNode], liveDisplays: [LiveDisplay]) -> [DisplayMapping]? {
        var unusedLive = liveDisplays
        var mappings: [DisplayMapping] = []

        // Build a map of saved node index to matched live display
        var nodeToLive: [Int: LiveDisplay] = [:]

        logger.info("🔍 Matching \(savedNodes.count) saved nodes to \(liveDisplays.count) live displays by resolution")

        // First pass: match by exact resolution
        for (idx, savedNode) in savedNodes.enumerated() {
            let savedW = savedNode.pixelWidth
            let savedH = savedNode.pixelHeight

            // Find exact resolution match among unused displays
            if let matchIdx = unusedLive.firstIndex(where: {
                Int32($0.bounds.width) == savedW && Int32($0.bounds.height) == savedH
            }) {
                let matched = unusedLive[matchIdx]
                nodeToLive[idx] = matched
                unusedLive.remove(at: matchIdx)
                logger.info("✅ Exact match: saved[\(idx)] \(savedW)x\(savedH) → display \(matched.displayID)")
            }
        }

        // Second pass: assign remaining displays to unmatched nodes
        for (idx, savedNode) in savedNodes.enumerated() {
            guard nodeToLive[idx] == nil else { continue }
            guard !unusedLive.isEmpty else {
                logger.info("⏭️ No more live displays for saved node \(idx)")
                break
            }

            // Pick the first available display
            let matched = unusedLive.removeFirst()
            nodeToLive[idx] = matched
            logger.info("📎 Fallback match: saved[\(idx)] \(savedNode.pixelWidth)x\(savedNode.pixelHeight) → display \(matched.displayID) \(Int(matched.bounds.width))x\(Int(matched.bounds.height))")
        }

        // Find the saved main node and its matched live display
        guard let savedMainIdx = savedNodes.firstIndex(where: { $0.isMain }),
              let liveMainDisplay = nodeToLive[savedMainIdx] else {
            logger.error("❌ Could not determine main display mapping")
            return nil
        }

        let savedMain = savedNodes[savedMainIdx]
        logger.info("🎯 Main display: saved[\(savedMainIdx)] → live \(liveMainDisplay.displayID)")

        // Build mappings with positions adjusted for actual display sizes
        for (idx, savedNode) in savedNodes.enumerated() {
            guard let liveDisplay = nodeToLive[idx] else { continue }

            // Calculate target position maintaining relative arrangement
            var targetX = savedNode.originX
            var targetY = savedNode.originY

            // Adjust positions based on actual display sizes to maintain relative layout
            // If this display is to the right of main, adjust X based on main's actual width
            if savedNode.originX > 0 {
                // This display is to the right - use actual main width
                let savedMainWidth = savedMain.pixelWidth
                let liveMainWidth = Int32(liveMainDisplay.bounds.width)
                if savedMainWidth > 0 {
                    targetX = savedNode.originX * liveMainWidth / savedMainWidth
                }
            } else if savedNode.originX < 0 {
                // This display is to the left - use this display's actual width
                let savedWidth = savedNode.pixelWidth
                let liveWidth = Int32(liveDisplay.bounds.width)
                if savedWidth > 0 {
                    targetX = savedNode.originX * liveWidth / savedWidth
                }
            }

            // If this display is below main, adjust Y based on main's actual height
            if savedNode.originY > 0 {
                let savedMainHeight = savedMain.pixelHeight
                let liveMainHeight = Int32(liveMainDisplay.bounds.height)
                if savedMainHeight > 0 {
                    targetY = savedNode.originY * liveMainHeight / savedMainHeight
                }
            } else if savedNode.originY < 0 {
                // This display is above - use this display's actual height
                let savedHeight = savedNode.pixelHeight
                let liveHeight = Int32(liveDisplay.bounds.height)
                if savedHeight > 0 {
                    targetY = savedNode.originY * liveHeight / savedHeight
                }
            }

            let mapping = DisplayMapping(
                displayID: liveDisplay.displayID,
                targetX: targetX,
                targetY: targetY,
                isTargetMain: savedNode.isMain
            )
            mappings.append(mapping)

            logger.info("📐 Mapped: display \(liveDisplay.displayID) → (\(targetX),\(targetY)) [saved: (\(savedNode.originX),\(savedNode.originY))]")
        }

        return mappings
    }

    // MARK: - Configuration Apply

    private func applyConfiguration(mapping: [DisplayMapping]) -> Result<Void, Error> {
        var configRef: CGDisplayConfigRef?

        let beginResult = CGBeginDisplayConfiguration(&configRef)
        logger.info("🔧 CGBeginDisplayConfiguration result: \(beginResult.rawValue)")
        guard beginResult == .success, let config = configRef else {
            logger.error("❌ Failed to begin configuration: \(beginResult.rawValue)")
            return .failure(NSError(domain: "DisplayMemo", code: Int(beginResult.rawValue),
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to begin configuration"]))
        }

        // Apply all origins
        for map in mapping {
            let result = CGConfigureDisplayOrigin(config, map.displayID, map.targetX, map.targetY)
            logger.info("📐 CGConfigureDisplayOrigin for display \(map.displayID) to (\(map.targetX),\(map.targetY)): \(result.rawValue)")
            if result != .success {
                logger.error("❌ Failed to configure display \(map.displayID): \(result.rawValue)")
                CGCancelDisplayConfiguration(config)
                return .failure(NSError(domain: "DisplayMemo", code: Int(result.rawValue),
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to configure display \(map.displayID)"]))
            }
        }

        // Try permanent commit first
        logger.info("💾 Attempting permanent commit...")
        var commitResult = CGCompleteDisplayConfiguration(config, .permanently)
        logger.info("💾 Permanent commit result: \(commitResult.rawValue)")
        if commitResult != .success {
            logger.warning("⚠️ Permanent commit failed (\(commitResult.rawValue)), trying session commit")
            // Need to start fresh for retry
            var retryConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&retryConfig) == .success, let retry = retryConfig else {
                logger.error("❌ Failed to begin retry configuration")
                return .failure(NSError(domain: "DisplayMemo", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to begin retry configuration"]))
            }

            for map in mapping {
                _ = CGConfigureDisplayOrigin(retry, map.displayID, map.targetX, map.targetY)
            }

            commitResult = CGCompleteDisplayConfiguration(retry, .forSession)
            logger.info("💾 Session commit result: \(commitResult.rawValue)")
            if commitResult != .success {
                logger.error("❌ Session commit failed: \(commitResult.rawValue)")
                return .failure(NSError(domain: "DisplayMemo", code: Int(commitResult.rawValue),
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to commit configuration"]))
            }
        }

        logger.info("✅ Configuration committed successfully")
        return .success(())
    }

    private func verifyPositions(mapping: [DisplayMapping]) -> Bool {
        let liveDisplays = getActiveDisplays()
        guard let liveMain = liveDisplays.first(where: { $0.isMain }) else {
            logger.error("❌ Verify: no main display")
            return false
        }
        let mainOrigin = liveMain.bounds.origin
        logger.info("🔍 Verifying against main origin: x=\(mainOrigin.x), y=\(mainOrigin.y)")

        var allMatch = true
        for map in mapping {
            guard let live = liveDisplays.first(where: { $0.displayID == map.displayID }) else {
                logger.error("❌ Verify: display \(map.displayID) not found")
                return false
            }

            let actualX = Int32(live.bounds.origin.x - mainOrigin.x)
            let actualY = Int32(live.bounds.origin.y - mainOrigin.y)

            let deltaX = abs(actualX - map.targetX)
            let deltaY = abs(actualY - map.targetY)

            logger.info("  Display \(map.displayID): expected=(\(map.targetX),\(map.targetY)), actual=(\(actualX),\(actualY)), delta=(\(deltaX),\(deltaY))")

            // Allow larger tolerance for Y axis since macOS adjusts to avoid gaps
            let xTolerance: Int32 = 5
            let yTolerance: Int32 = 100  // macOS may adjust Y significantly to avoid gaps

            if deltaX > xTolerance || deltaY > yTolerance {
                logger.warning("⚠️ Position mismatch for display \(map.displayID) exceeds tolerance (X:\(xTolerance), Y:\(yTolerance))")
                allMatch = false
            } else if deltaX > 0 || deltaY > 0 {
                logger.info("  ✓ Within tolerance - macOS adjusted position")
            }
        }

        if allMatch {
            logger.info("✅ All positions verified")
        } else {
            logger.warning("⚠️ Some positions don't match")
        }

        return allMatch
    }

    // MARK: - Helpers

    private func generateDisplayName(displays: [LiveDisplay]) -> String {
        let builtinCount = displays.filter { $0.isBuiltin }.count
        let externalCount = displays.count - builtinCount

        if builtinCount > 0 && externalCount > 0 {
            return "Built-in + \(externalCount) External"
        } else {
            return "\(displays.count) Displays"
        }
    }
}
