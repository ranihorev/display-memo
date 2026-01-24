import Foundation
import os.log

/// Manages persistence of the default arrangement and custom overrides
final class ProfileStore {
    static let shared = ProfileStore()

    private let logger = Logger(subsystem: "com.displaymemo.app", category: "Store")
    private let fileManager = FileManager.default
    private var storage: StorageFile

    /// Directory for app data storage
    private var appSupportDirectory: URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return urls[0].appendingPathComponent("DisplayMemo", isDirectory: true)
    }

    /// Path to the storage JSON file
    private var storageURL: URL {
        appSupportDirectory.appendingPathComponent("storage.json")
    }

    /// Temporary file for atomic writes
    private var tempStorageURL: URL {
        appSupportDirectory.appendingPathComponent("storage.json.tmp")
    }

    private init() {
        storage = StorageFile()
        ensureDirectoryExists()
        load()
    }

    // MARK: - Default Arrangement

    /// The single default arrangement (nil if none saved)
    var defaultArrangement: DisplayLayoutProfile? {
        storage.defaultArrangement
    }

    /// Whether a default arrangement exists
    var hasDefaultArrangement: Bool {
        storage.defaultArrangement != nil
    }

    /// Save the current arrangement as the default
    func saveDefaultArrangement(_ profile: DisplayLayoutProfile) {
        storage.defaultArrangement = profile
        // Clear any custom override for this signature since we're saving a new default
        storage.customOverrideSignatures.remove(profile.signature)
        persist()
        logger.info("Default arrangement saved for signature: \(profile.signature)")
    }

    /// Clear the default arrangement
    func clearDefaultArrangement() {
        guard storage.defaultArrangement != nil else {
            logger.warning("Attempted to clear non-existent default arrangement")
            return
        }
        storage.defaultArrangement = nil
        storage.customOverrideSignatures.removeAll()
        persist()
        logger.info("Default arrangement cleared")
    }

    // MARK: - Custom Overrides

    /// Check if a custom override is active for the given signature
    func hasCustomOverride(for signature: String) -> Bool {
        storage.customOverrideSignatures.contains(signature)
    }

    /// Set custom override flag for a signature (user manually changed layout)
    func setCustomOverride(for signature: String) {
        guard !storage.customOverrideSignatures.contains(signature) else { return }
        storage.customOverrideSignatures.insert(signature)
        persist()
        logger.info("Custom override set for signature: \(signature)")
    }

    /// Clear custom override for a signature (user wants to use default again)
    func clearCustomOverride(for signature: String) {
        guard storage.customOverrideSignatures.contains(signature) else { return }
        storage.customOverrideSignatures.remove(signature)
        persist()
        logger.info("Custom override cleared for signature: \(signature)")
    }

    // MARK: - Private Methods

    /// Ensure the app support directory exists
    private func ensureDirectoryExists() {
        do {
            try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create app support directory: \(error.localizedDescription)")
        }
    }

    /// Load storage from disk
    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            logger.info("No storage file found, starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            storage = try decoder.decode(StorageFile.self, from: data)
            logger.info("Storage loaded, default: \(self.storage.defaultArrangement != nil), overrides: \(self.storage.customOverrideSignatures.count)")
        } catch {
            logger.error("Failed to decode storage: \(error.localizedDescription)")
            handleCorruptFile()
        }
    }

    /// Persist storage to disk with atomic write
    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(storage)

            // Write to temp file first
            try data.write(to: tempStorageURL, options: .atomic)

            // Rename to final location (atomic on POSIX)
            if fileManager.fileExists(atPath: storageURL.path) {
                try fileManager.removeItem(at: storageURL)
            }
            try fileManager.moveItem(at: tempStorageURL, to: storageURL)

            logger.debug("Storage persisted successfully")
        } catch {
            logger.error("Failed to persist storage: \(error.localizedDescription)")
        }
    }

    /// Handle corrupt storage file by renaming it and starting fresh
    private func handleCorruptFile() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let corruptURL = appSupportDirectory
            .appendingPathComponent("storage.json.corrupt.\(timestamp)")

        do {
            try fileManager.moveItem(at: storageURL, to: corruptURL)
            logger.warning("Corrupt storage file moved to: \(corruptURL.lastPathComponent)")
        } catch {
            logger.error("Failed to rename corrupt file: \(error.localizedDescription)")
        }

        storage = StorageFile()
    }
}
