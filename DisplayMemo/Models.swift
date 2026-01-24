import Foundation

// MARK: - Display Node

/// Represents a single display's position and properties within a saved profile
struct DisplayNode: Codable {
    /// Deprecated: kept for backward compatibility with saved profiles
    var modelSignature: String

    /// Whether this display is the main display (origin 0,0)
    var isMain: Bool

    /// Normalized X origin relative to main display
    var originX: Int32

    /// Normalized Y origin relative to main display
    var originY: Int32

    /// Display width in pixels (for debug/validation)
    var pixelWidth: Int32

    /// Display height in pixels (for debug/validation)
    var pixelHeight: Int32

    /// Whether this is the built-in display
    var isBuiltin: Bool
}

// MARK: - Display Layout Profile

/// A saved display arrangement for a specific configuration of monitors
struct DisplayLayoutProfile: Codable {
    /// Configuration signature (sorted multiset of monitor signatures)
    var signature: String

    /// Human-readable name for this configuration
    var displayName: String

    /// When this profile was first created
    var createdAt: Date

    /// When this profile was last updated
    var updatedAt: Date

    /// The display nodes in this configuration
    var displays: [DisplayNode]
}

// MARK: - Storage File

/// Container for the single default arrangement with schema versioning
struct StorageFile: Codable {
    /// Schema version for future migrations
    var schemaVersion: Int = 1

    /// The single default arrangement (nil if none saved)
    var defaultArrangement: DisplayLayoutProfile?

    /// Signatures that have custom overrides (user manually changed after restore)
    var customOverrideSignatures: Set<String>

    init(schemaVersion: Int = 1, defaultArrangement: DisplayLayoutProfile? = nil, customOverrideSignatures: Set<String> = []) {
        self.schemaVersion = schemaVersion
        self.defaultArrangement = defaultArrangement
        self.customOverrideSignatures = customOverrideSignatures
    }
}

// MARK: - Restore Result

/// Result of a restore operation
enum RestoreResult {
    case success
    case noDefaultArrangement
    case customOverrideActive
    case mappingFailed
    case mirroringDetected
    case configurationFailed(Error)
    case verificationFailed

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success:
            return "Layout restored"
        case .noDefaultArrangement:
            return "No default arrangement saved"
        case .customOverrideActive:
            return "Custom arrangement active (manual changes detected)"
        case .mappingFailed:
            return "Unable to map displays for this setup"
        case .mirroringDetected:
            return "Mirroring not supported"
        case .configurationFailed(let error):
            return "Restore failed: \(error.localizedDescription)"
        case .verificationFailed:
            return "Layout verification failed after restore"
        }
    }
}

// MARK: - Snapshot Result

/// Result of a snapshot operation
enum SnapshotResult {
    case success(DisplayLayoutProfile)
    case noDisplays
    case noMainDisplay
    case multipleMainDisplays

    var profile: DisplayLayoutProfile? {
        if case .success(let profile) = self { return profile }
        return nil
    }

    var message: String {
        switch self {
        case .success:
            return "Layout saved"
        case .noDisplays:
            return "No displays detected"
        case .noMainDisplay:
            return "Could not determine main display"
        case .multipleMainDisplays:
            return "Multiple main displays detected"
        }
    }
}
