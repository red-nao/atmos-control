// AtmosControlApp/SettingsStore.swift — on-disk state: EQ presets, the live settings
// snapshot, and the login-item flag.
//
//   ~/Library/Application Support/atmos-control/settings.json
//
// Writes are debounced (1 s) and atomic, so a burst of fader drags costs one write and a
// crash mid-save can never leave a half-written file. A file that won't parse is moved
// aside as settings.corrupt-<timestamp>.json rather than silently discarded.

import Foundation
import ServiceManagement
import AppKit
import SpatialEngine

// MARK: - Model

struct EQPreset: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var gains: [Float]
    var preampMode: PreampMode = .auto
    var manualPreamp: Float = 0
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    /// The one built-in preset. Not stored on disk, never deletable or overwritable.
    static let flatID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    static let flat = EQPreset(id: flatID, name: "Flat",
                               gains: Array(repeating: 0, count: EQConfig.bandCount))
    var isBuiltIn: Bool { id == EQPreset.flatID }

    /// Does this preset describe the given live EQ state? (`enabled` is deliberately not
    /// part of a preset — switching the EQ off shouldn't mark every preset dirty.)
    func matches(_ eq: EQConfig) -> Bool {
        let a = eq.normalizedGains, b = EQConfig(enabled: true, gains: gains).normalizedGains
        guard a.count == b.count else { return false }
        for i in 0..<a.count where abs(a[i] - b[i]) > 0.01 { return false }
        if preampMode != eq.preampMode { return false }
        if preampMode == .manual, abs(manualPreamp - eq.manualPreamp) > 0.01 { return false }
        return true
    }

    /// The live EQ state this preset represents, preserving the current on/off switch.
    func applied(to eq: EQConfig) -> EQConfig {
        EQConfig(enabled: eq.enabled, gains: gains, preampMode: preampMode, manualPreamp: manualPreamp)
    }
}

struct AppSettings: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = AppSettings.currentSchemaVersion
    var eqPresets: [EQPreset] = []
    var lastSelectedEQPresetID: UUID?
    /// The live spatial + EQ state (spatial *presets* and device profiles arrive in P3).
    var spatial: SpatialConfig = SpatialConfig()
    var captureMode: String = CaptureMode.processTap.rawValue
    /// Persisted by UID, not AudioDeviceID: IDs are reassigned on every boot.
    var selectedOutputUID: String?
    var launchAtLogin: Bool = false

    enum CodingKeys: String, CodingKey {
        case schemaVersion, eqPresets, lastSelectedEQPresetID, spatial
        case captureMode, selectedOutputUID, launchAtLogin
    }

    init() {}

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        schemaVersion          = lenient(c, .schemaVersion, schemaVersion)
        eqPresets              = lenient(c, .eqPresets, [])
        lastSelectedEQPresetID = ((try? c.decodeIfPresent(UUID.self, forKey: .lastSelectedEQPresetID)) ?? nil)
        spatial                = lenient(c, .spatial, spatial)
        captureMode            = lenient(c, .captureMode, captureMode)
        selectedOutputUID      = ((try? c.decodeIfPresent(String.self, forKey: .selectedOutputUID)) ?? nil)
        launchAtLogin          = lenient(c, .launchAtLogin, launchAtLogin)
        // Built-ins and duplicates never come from disk.
        eqPresets = eqPresets.filter { !$0.isBuiltIn }
    }

    /// Future schema bumps funnel through here (v1 only for now).
    mutating func migrate() {
        if schemaVersion < AppSettings.currentSchemaVersion {
            schemaVersion = AppSettings.currentSchemaVersion
        }
    }
}

// MARK: - Store

@MainActor
final class SettingsStore {
    /// ~/Library/Application Support/atmos-control/settings.json
    /// (the app keeps its existing name and bundle id, so the folder matches).
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("atmos-control", isDirectory: true)
    }()
    static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    private var saveTimer: Timer?
    private var pending: Data?
    /// Set while the controller is applying a loaded file, so the resulting property
    /// writes don't immediately schedule a save of what we just read.
    private(set) var isLoading = false

    private let ioQueue = DispatchQueue(label: "dev.atmoscontrol.settings-io", qos: .utility)

    // MARK: Load

    func load() -> AppSettings {
        let url = Self.fileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return AppSettings() }
        do {
            var s = try JSONDecoder().decode(AppSettings.self, from: data)
            s.migrate()
            return s
        } catch {
            quarantine(url, reason: error)
            return AppSettings()
        }
    }

    /// Run `body` with saves suppressed (used while applying a freshly loaded file).
    func whileLoading(_ body: () -> Void) {
        isLoading = true
        body()
        isLoading = false
    }

    private func quarantine(_ url: URL, reason: Error) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = Self.directory.appendingPathComponent("settings.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: dest)
        NSLog("atmos-control: settings.json could not be parsed (\(reason)); moved to \(dest.lastPathComponent)")
    }

    // MARK: Save

    /// Coalesce writes: a fader drag produces one file write a second after it settles.
    func schedule(_ settings: AppSettings) {
        guard !isLoading else { return }
        // ATMOS_PREVIEW spins up a throwaway controller for screenshots — it must never
        // overwrite the real settings file.
        guard ProcessInfo.processInfo.environment["ATMOS_PREVIEW"] == nil else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        pending = data
        saveTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        saveTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Write immediately (app termination, or "Save" in the UI).
    func flush() {
        saveTimer?.invalidate(); saveTimer = nil
        guard let data = pending else { return }
        pending = nil
        let dir = Self.directory, url = Self.fileURL
        ioQueue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do { try data.write(to: url, options: [.atomic]) }
            catch { NSLog("atmos-control: could not write settings.json — \(error)") }
        }
    }

    /// Termination path: the async write above may not survive the process, so do it here.
    func flushSynchronously() {
        saveTimer?.invalidate(); saveTimer = nil
        guard let data = pending else { return }
        pending = nil
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: [.atomic])
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) { flush() }
        NSWorkspace.shared.activateFileViewerSelecting([Self.fileURL])
    }
}

// MARK: - Login item

/// SMAppService wrapper (the modern replacement for the deprecated
/// SMLoginItemSetEnabled / LSSharedFileList dance). Registering the main app makes macOS
/// launch it at login; the user can also flip it in System Settings ▸ General ▸ Login Items,
/// which is why `isEnabled` always re-reads the live status instead of caching it.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True when the user has disabled us in System Settings — we can't override that,
    /// so the UI explains it instead of silently failing.
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns nil on success, or a human-readable reason it didn't take.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                return "Approve atmos-control in System Settings ▸ General ▸ Login Items."
            }
            return "Could not \(enabled ? "enable" : "disable") launch at login — \(error.localizedDescription)"
        }
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
