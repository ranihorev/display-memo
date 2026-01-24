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
        guard let profile = ProfileStore.shared.defaultArrangement else {
            logger.error("Restore failed: no default arrangement")
            return .noDefaultArrangement
        }

        let signature = currentSignature

        if ProfileStore.shared.hasCustomOverride(for: signature) {
            logger.info("Restore skipped: custom override active")
            return .customOverrideActive
        }

        if isMirroringActive() {
            logger.error("Restore aborted: mirroring detected")
            return .mirroringDetected
        }

        let liveDisplays = getActiveDisplays()
        logger.info("Restoring \(profile.displayName): \(liveDisplays.count) live, \(profile.displays.count) saved")

        guard profile.displays.filter({ $0.isMain }).count == 1 else {
            logger.error("Invalid profile: no single main display")
            return .mappingFailed
        }

        guard let mapping = mapDisplays(savedNodes: profile.displays, liveDisplays: liveDisplays) else {
            logger.error("Display mapping failed")
            return .mappingFailed
        }

        isApplyingConfiguration = true
        defer {
            isApplyingConfiguration = false
            cooldownEndTime = Date().addingTimeInterval(cooldownDuration)
        }

        let result = applyConfiguration(mapping: mapping)

        switch result {
        case .success:
            logger.info("Configuration applied")

            // Track for manual change detection
            var appliedPositions: [CGDirectDisplayID: (x: Int32, y: Int32)] = [:]
            for map in mapping {
                appliedPositions[map.displayID] = (map.targetX, map.targetY)
            }
            lastAppliedPositions = appliedPositions
            lastAppliedSignature = signature

            if !verifyPositions(mapping: mapping) && !isRetry {
                logger.info("Verification failed, scheduling retry")
                displayQueue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                    _ = self?.restoreInternal(isRetry: true)
                }
            }
            return .success

        case .failure(let error):
            logger.error("Configuration failed: \(error.localizedDescription)")
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
        var nodeToLive: [Int: LiveDisplay] = [:]

        // First pass: match by exact resolution
        for (idx, savedNode) in savedNodes.enumerated() {
            if let matchIdx = unusedLive.firstIndex(where: {
                Int32($0.bounds.width) == savedNode.pixelWidth &&
                Int32($0.bounds.height) == savedNode.pixelHeight
            }) {
                nodeToLive[idx] = unusedLive.remove(at: matchIdx)
            }
        }

        // Second pass: assign remaining displays to unmatched nodes
        for (idx, _) in savedNodes.enumerated() {
            guard nodeToLive[idx] == nil, !unusedLive.isEmpty else { continue }
            nodeToLive[idx] = unusedLive.removeFirst()
        }

        // Verify we have a main display mapped
        guard let savedMainIdx = savedNodes.firstIndex(where: { $0.isMain }),
              nodeToLive[savedMainIdx] != nil else {
            logger.error("Could not map main display")
            return nil
        }

        // Build mappings using saved positions directly
        return savedNodes.enumerated().compactMap { (idx, savedNode) -> DisplayMapping? in
            guard let liveDisplay = nodeToLive[idx] else { return nil }
            return DisplayMapping(
                displayID: liveDisplay.displayID,
                targetX: savedNode.originX,
                targetY: savedNode.originY,
                isTargetMain: savedNode.isMain
            )
        }
    }

    // MARK: - Configuration Apply

    private func applyConfiguration(mapping: [DisplayMapping]) -> Result<Void, Error> {
        var configRef: CGDisplayConfigRef?

        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            return .failure(NSError(domain: "DisplayMemo", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to begin configuration"]))
        }

        for map in mapping {
            let result = CGConfigureDisplayOrigin(config, map.displayID, map.targetX, map.targetY)
            if result != .success {
                CGCancelDisplayConfiguration(config)
                return .failure(NSError(domain: "DisplayMemo", code: Int(result.rawValue),
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to configure display"]))
            }
        }

        // Try permanent commit, fall back to session commit
        if CGCompleteDisplayConfiguration(config, .permanently) != .success {
            var retryConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&retryConfig) == .success, let retry = retryConfig else {
                return .failure(NSError(domain: "DisplayMemo", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to retry configuration"]))
            }
            for map in mapping {
                _ = CGConfigureDisplayOrigin(retry, map.displayID, map.targetX, map.targetY)
            }
            if CGCompleteDisplayConfiguration(retry, .forSession) != .success {
                return .failure(NSError(domain: "DisplayMemo", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to commit configuration"]))
            }
        }

        return .success(())
    }

    private func verifyPositions(mapping: [DisplayMapping]) -> Bool {
        let liveDisplays = getActiveDisplays()
        guard let liveMain = liveDisplays.first(where: { $0.isMain }) else { return false }
        let mainOrigin = liveMain.bounds.origin

        for map in mapping {
            guard let live = liveDisplays.first(where: { $0.displayID == map.displayID }) else {
                return false
            }
            let actualX = Int32(live.bounds.origin.x - mainOrigin.x)
            let actualY = Int32(live.bounds.origin.y - mainOrigin.y)
            // Allow tolerance since macOS may adjust positions
            if abs(actualX - map.targetX) > 5 || abs(actualY - map.targetY) > 100 {
                return false
            }
        }
        return true
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
