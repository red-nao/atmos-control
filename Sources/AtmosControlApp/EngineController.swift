// EngineController — @MainActor view-model bridging SwiftUI ↔ SpatialEngine.
// Owns the power on/off orchestration (default-output routing) and a poll timer
// that publishes live engine telemetry (peaks, 3116, ring fill) to the UI.
//
// Uses the Observation framework (@Observable) rather than ObservableObject so SwiftUI
// tracks per-property reads: a meter-rate write no longer invalidates the whole tree,
// only the views that actually read the changed property.

import SwiftUI
import AppKit
import CoreAudio
import Observation
import SpatialEngine

/// How the engine captures system audio.
enum CaptureMode: String, CaseIterable, Identifiable {
    case processTap      // muting process tap; AirPods stay default → personalized HRTF + no black-hole
    case loopbackDriver  // hijack the default to the atmos-control loopback; generic HRTF only
    var id: String { rawValue }
    var label: String { self == .processTap ? "Personalized (tap)" : "Loopback driver" }
}

@MainActor
@Observable
final class EngineController {
    var isOn = false
    var config = SpatialConfig()
    var lastError: String?
    var atmosPresent = false
    var blackHolePresent = false
    /// True when any loopback is present (bundled driver or BlackHole 16ch).
    var loopbackPresent = false
    /// Name of the device backing Surround 7.1.4 ("—" when none). UI copy so it is
    /// honest about whether atmos-control or BlackHole is in use (Issue #1 §4).
    var surroundCaptureName = "—"
    var outputName = "—"

    /// True when the tap start failed on (likely) audio-capture consent. We surface an
    /// explicit permission state and do NOT auto-fall-back to loopback (which would mutate
    /// the system default output). Cleared on a successful start / mode switch / retry.
    var permissionNeeded = false

    /// The tap started and is delivering buffers, but every sample has been 0.0 for over
    /// ten seconds. That is what a DENIED System Audio Recording grant looks like from the
    /// inside (every Core Audio call returns noErr), and also what the macOS 26 all-zero
    /// tap bug looks like. It is ALSO what a genuinely quiet Mac looks like, so the notice
    /// is worded as a hint, never as an error. Clears the moment real audio arrives.
    var silentCaptureSuspected = false

    /// Non-fatal warning from the tap layer (e.g. we could not exclude our own process,
    /// so muting was disabled and you will hear the original audio alongside ours).
    var tapWarning: String?

    /// Trace of what the tap layer did on the last start (topology used, channel counts,
    /// self-exclusion). Shown under Levels ▸ Tap diagnostics when debug readouts are on.
    var tapDiagnostics: [String] = []

    /// The installed loopback exposes the full 12-channel 7.1.4 surface (enables Surround).
    var surroundDriverInstalled = false

    /// Per-capture-channel peaks (Atmos_7_1_4 order) for the settings Levels surround meter;
    /// [L,R] in stereo modes. Read only by SettingsView when surround is active.
    var channelPeaks: [Float] = []

    // Live engine telemetry — individual tracked properties (was one EngineState struct)
    // so per-property observation pays off: PanelView reads only personalizedHRTFEngaged,
    // while ringFill/totals (SettingsView-only) no longer invalidate the panel each tick.
    var personalizedHRTFEngaged = false   // AUSpatialMixer property 3116
    var ringFill: UInt64 = 0
    var totalCaptured: UInt64 = 0
    var totalPlayed: UInt64 = 0

    // Output routing (settings window): the discovered real sinks + the user's choice.
    var outputs: [AudioOutputDevice] = []
    var selectedOutputID: AudioDeviceID?   // nil = follow current system default
    var captureMode: CaptureMode = .processTap   // default: personalized, no black-hole

    // Smoothed peak-hold for the meters (linear 0…1).
    var meterL: Float = 0
    var meterR: Float = 0
    var peakHoldL: Float = 0
    var peakHoldR: Float = 0

    // Live head pose (radians yaw) for the radar; mirrors AirPods head tracking.
    var headYaw: Double = 0
    var headPoseLive = false

    // Persisted state (see SettingsStore). `eqPresets` always begins with the built-in Flat.
    var eqPresets: [EQPreset] = [EQPreset.flat]
    var selectedEQPresetID: UUID? = EQPreset.flatID
    var launchAtLogin = false
    var launchAtLoginNote: String?

    var spatialPresets: [SpatialPreset] = [SpatialPreset.builtInDefault]
    var selectedSpatialPresetID: UUID? = SpatialPreset.defaultID
    var deviceProfiles: [DeviceProfile] = []
    var fallbackProfile: DeviceProfile = DeviceProfile.fallback

    /// The current output device's profile says "don't process this device". The engine is
    /// stopped and audio reaches the device untouched.
    var bypassed = false
    /// Name of the device the active profile was resolved for (UI copy).
    var profiledDeviceName = "—"

    @ObservationIgnored private var lastProfiledDeviceID: AudioDeviceID?
    /// The user powered on anyway while a bypass profile was active (session-scoped).
    @ObservationIgnored private var bypassOverride = false
    /// We stopped the engine because of a bypass profile — so we may start it again by
    /// ourselves when a processed device comes back.
    @ObservationIgnored private var poweredOffByBypass = false

    @ObservationIgnored private let store = SettingsStore()
    @ObservationIgnored private let engine = SpatialEngine()
    @ObservationIgnored private let deviceMonitor = DeviceMonitor()
    @ObservationIgnored private let motion = HeadphoneMotion()
    @ObservationIgnored private let tap = ProcessTap()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var silenceProbe: Timer?
    @ObservationIgnored private var silenceTicks = 0
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var lastIO: (captured: UInt64, played: UInt64) = (0, 0)
    @ObservationIgnored private var stallTicks = 0
    @ObservationIgnored private var captureStallTicks = 0
    @ObservationIgnored private var watchdogRecoveries = 0
    @ObservationIgnored private var healthyTicks = 0
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var pollInterval: TimeInterval = 0
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var savedDefault: AudioDeviceID?
    @ObservationIgnored private var activeSinkID: AudioDeviceID?   // real device the graph renders to
    @ObservationIgnored private var activeCaptureID: AudioDeviceID?  // tap aggregate (tap mode) or nil
    @ObservationIgnored private var handlingChange = false

    // Surface visibility. The MenuBarExtra(.window) popover's visibility is taken from its
    // NSWindow (bindPanelWindow) because SwiftUI .onDisappear is not reliably delivered when
    // that popover dismisses; the Settings Window's onAppear/onDisappear ARE reliable.
    @ObservationIgnored private var panelOnScreen = false
    @ObservationIgnored private var settingsOnScreen = false
    @ObservationIgnored private weak var panelWindow: NSWindow?   // weak: don't pin the hidden popover window
    @ObservationIgnored private var panelOcclusionObserver: NSObjectProtocol?

    /// The engine can run for the CURRENT capture choice. Personalized (tap) needs no driver;
    /// the virtual-device options need a loopback (Surround needs the 12-channel surface:
    /// bundled driver or BlackHole 16ch, Issue #1 §4).
    /// The panel never collapses on this — a false value only disables the power toggle and
    /// shows an inline notice (F11).
    var canRun: Bool {
        switch captureChoice {
        case .personalized:  return true
        case .virtualStereo: return loopbackPresent
        case .surround:      return surroundDriverInstalled
        }
    }

    /// The user-facing capture choice derived from the engine's capture mode + source mode.
    var captureChoice: CaptureChoice {
        if captureMode == .processTap { return .personalized }
        return (config.sourceMode == .surround714 || config.sourceMode == .surroundBed714) ? .surround : .virtualStereo
    }

    /// Switch the user-facing capture choice (maps onto CaptureMode + SourceRenderMode).
    /// Restarts the engine if it was running.
    func setCaptureChoice(_ choice: CaptureChoice) {
        guard choice != captureChoice else { return }
        permissionNeeded = false
        let wasOn = isOn
        if wasOn { powerOff() }
        switch choice {
        case .personalized:
            captureMode = .processTap
            if config.sourceMode == .surround714 || config.sourceMode == .surroundBed714 { config.sourceMode = .dualPointStereo }
        case .virtualStereo:
            captureMode = .loopbackDriver
            if config.sourceMode == .surround714 || config.sourceMode == .surroundBed714 { config.sourceMode = .dualPointStereo }
        case .surround:
            captureMode = .loopbackDriver
            config.sourceMode = .surround714
        }
        syncUpmixMode()
        engine.config = config
        scheduleSave()
        if wasOn { powerOn() }
    }

    /// The live controller. Production creates exactly one (the App's @State model); the
    /// app delegate uses this to run cleanup on quit / logout / shutdown without building a
    /// second engine. (Preview mode's throwaway controller may overwrite it — harmless,
    /// since preview never powers on.)
    static weak var shared: EngineController?

    init() {
        EngineController.shared = self
        refreshLoopbackFlags()
        let cur = SpatialEngine.currentDefaultOutput()
        outputName = cur.name
        outputs = engine.outputDevices()

        motion.onYaw = { [weak self] y in
            guard let self else { return }
            if abs(y - self.headYaw) > 0.008 { self.headYaw = y }   // ~0.5°: limit redraw churn
            if !self.headPoseLive { self.headPoseLive = true }
        }
        deviceMonitor.onChange = { [weak self] in self?.handleDeviceChange() }
        deviceMonitor.start()
        observeSleepWake()

        // The capture device renegotiated its sample rate and the engine rebuilt the graph.
        // ok == false means the rebuild failed and the engine is stopped: we MUST power off
        // so the muting process tap is torn down (otherwise all system audio stays silenced).
        engine.onFormatChange = { [weak self] ok in
            guard let self else { return }
            if ok {
                self.lastError = nil
                self.updateActivity()
            } else {
                self.lastError = "Audio format changed and the engine could not restart — stopped."
                self.powerOff()
            }
        }

        loadSettings()
    }

    // MARK: Persistence

    private func loadSettings() {
        let s = store.load()
        store.whileLoading {
            config = s.spatial
            eqPresets = [EQPreset.flat] + s.eqPresets
            spatialPresets = [SpatialPreset.builtInDefault] + s.spatialPresets
            selectedSpatialPresetID = s.lastSelectedSpatialPresetID.flatMap { id in
                spatialPresets.contains(where: { $0.id == id }) ? id : nil
            } ?? SpatialPreset.defaultID
            deviceProfiles = s.deviceProfiles
            fallbackProfile = s.fallbackProfile
            selectedEQPresetID = s.lastSelectedEQPresetID.flatMap { id in
                eqPresets.contains(where: { $0.id == id }) ? id : nil
            } ?? EQPreset.flatID
            if let m = CaptureMode(rawValue: s.captureMode) { captureMode = m }
            syncUpmixMode()
            // Surround needs the 12-channel driver; fall back rather than start broken.
            if captureChoice == .surround && !surroundDriverInstalled {
                captureMode = .processTap
                config.sourceMode = .dualPointStereo
            }
            if let uid = s.selectedOutputUID, let id = SpatialEngine.device(withUID: uid),
               outputs.contains(where: { $0.id == id }) {
                selectedOutputID = id
                outputName = deviceDisplayName(id) ?? outputName
            }
            engine.config = config
        }
        // The real source of truth for the login item is SMAppService, not our file.
        launchAtLogin = LoginItem.isEnabled
        primeProfileAtLaunch()
    }

    /// At launch we restore the state the user left behind — we do NOT overwrite it with
    /// the device profile (that would throw away their last session every time). We only
    /// note which device we're pointed at, and honour a bypass profile before powering on.
    private func primeProfileAtLaunch() {
        guard let id = currentSinkID() else { return }
        lastProfiledDeviceID = id
        profiledDeviceName = outputs.first(where: { $0.id == id })?.name ?? SpatialEngine.currentDefaultOutput().name
        let p = resolveProfile(for: id)
        bypassed = p.autoSwitch && p.mode == .bypass
        resolveAlgorithmAtLaunch()
    }

    private func resolveAlgorithmAtLaunch() {
        guard config.algorithmMode == .automaticByDevice else { return }
        let want = automaticAlgorithm
        if config.algorithm != want { config.algorithm = want; engine.config = config }
    }

    private func deviceDisplayName(_ id: AudioDeviceID) -> String? {
        outputs.first(where: { $0.id == id })?.name
    }

    /// Snapshot everything persistable and hand it to the debounced writer.
    func scheduleSave() {
        var s = AppSettings()
        s.eqPresets = eqPresets.filter { !$0.isBuiltIn }
        s.lastSelectedEQPresetID = selectedEQPresetID
        s.spatialPresets = spatialPresets.filter { !$0.isBuiltIn }
        s.lastSelectedSpatialPresetID = selectedSpatialPresetID
        s.deviceProfiles = deviceProfiles
        s.fallbackProfile = fallbackProfile
        s.upmixEnabled = config.upmix.enabled
        s.spatial = config
        s.captureMode = captureMode.rawValue
        s.selectedOutputUID = selectedOutputID.map { SpatialEngine.uid(of: $0) }
        s.launchAtLogin = launchAtLogin
        store.schedule(s)
    }

    /// Called on quit: the debounce timer must not eat the last edit.
    func saveNow() { scheduleSave(); store.flushSynchronously() }

    func revealSettingsFile() { scheduleSave(); store.revealInFinder() }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginNote = LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
        scheduleSave()
    }

    /// Re-read the live SMAppService status (the user can change it in System Settings).
    func refreshLaunchAtLogin() {
        let live = LoginItem.isEnabled
        if live != launchAtLogin { launchAtLogin = live }
        if live { launchAtLoginNote = nil }
    }

    // MARK: EQ presets

    var selectedEQPreset: EQPreset? { eqPresets.first { $0.id == selectedEQPresetID } }

    /// The current curve no longer matches the selected preset (shown as a `•`).
    var eqDirty: Bool {
        guard let p = selectedEQPreset else { return !config.eq.isFlat }
        return !p.matches(config.eq)
    }

    func eqPresetLabel(_ p: EQPreset) -> String {
        (p.id == selectedEQPresetID && eqDirty) ? "\(p.name) •" : p.name
    }

    func applyEQPreset(_ id: UUID) {
        guard let p = eqPresets.first(where: { $0.id == id }) else { return }
        selectedEQPresetID = id
        config.eq = p.applied(to: config.eq)
        pushEQ()
    }

    /// Overwrite the selected preset with the current curve (disabled for Flat).
    func saveSelectedEQPreset() {
        guard let idx = eqPresets.firstIndex(where: { $0.id == selectedEQPresetID }),
              !eqPresets[idx].isBuiltIn else { return }
        eqPresets[idx].gains = config.eq.normalizedGains
        eqPresets[idx].preampMode = config.eq.preampMode
        eqPresets[idx].manualPreamp = config.eq.manualPreamp
        eqPresets[idx].modifiedAt = Date()
        scheduleSave()
    }

    /// Save the current curve as a new preset and select it.
    @discardableResult
    func saveEQPresetAs(_ rawName: String) -> Bool {
        let name = uniqueEQPresetName(rawName)
        guard !name.isEmpty else { return false }
        let p = EQPreset(name: name, gains: config.eq.normalizedGains,
                         preampMode: config.eq.preampMode, manualPreamp: config.eq.manualPreamp)
        eqPresets.append(p)
        selectedEQPresetID = p.id
        scheduleSave()
        return true
    }

    func renameEQPreset(_ id: UUID, to rawName: String) {
        guard let idx = eqPresets.firstIndex(where: { $0.id == id }), !eqPresets[idx].isBuiltIn else { return }
        let name = uniqueEQPresetName(rawName, excluding: id)
        guard !name.isEmpty else { return }
        eqPresets[idx].name = name
        eqPresets[idx].modifiedAt = Date()
        scheduleSave()
    }

    func deleteEQPreset(_ id: UUID) {
        guard let idx = eqPresets.firstIndex(where: { $0.id == id }), !eqPresets[idx].isBuiltIn else { return }
        eqPresets.remove(at: idx)
        if selectedEQPresetID == id { selectedEQPresetID = EQPreset.flatID }
        scheduleSave()
    }

    /// Trim, and disambiguate a clashing name as "Rock 2" — two presets with the same
    /// name in a Picker are indistinguishable.
    private func uniqueEQPresetName(_ raw: String, excluding: UUID? = nil) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        let taken = Set(eqPresets.filter { $0.id != excluding }.map { $0.name })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Output devices

    /// Re-enumerate the available real sinks; drop a selection that has vanished.
    func refreshDevices() {
        refreshLoopbackFlags()
        outputs = engine.outputDevices()
        if let sel = selectedOutputID, !outputs.contains(where: { $0.id == sel }) {
            selectedOutputID = nil
        }
    }

    /// Single place that mirrors the engine's loopback discovery into published flags.
    private func refreshLoopbackFlags() {
        atmosPresent = engine.atmosControlPresent()
        blackHolePresent = engine.blackHolePresent()
        loopbackPresent = engine.loopbackPresent()
        surroundDriverInstalled = engine.surroundDriverInstalled()
        surroundCaptureName = engine.surroundCaptureName()
    }

    /// Sensible output-type default for a sink (used on power-on and device switch).
    private func outputType(for dev: AudioOutputDevice) -> OutputType {
        if dev.isAirPods { return .headphones }
        return dev.name.localizedCaseInsensitiveContains("headphone") ? .headphones : .builtInSpeakers
    }

    /// Pick which real sink to route through. nil = follow the system default.
    /// Swaps the playback graph live when running (atmos-control stays the default).
    func selectOutput(_ dev: AudioOutputDevice?) {
        selectedOutputID = dev?.id
        scheduleSave()
        if let d = dev { applyProfile(for: d.id) }
        if let d = dev { outputName = d.name; config.outputType = outputType(for: d) }
        guard isOn else { engine.config = config; return }
        engine.stop()
        engine.config = config
        do { try engine.start(outputDeviceID: dev?.id, captureDeviceID: activeCaptureID); activeSinkID = dev?.id; lastError = nil }
        catch { lastError = "\(error)"; powerOff() }
    }

    // MARK: Device hot-swap

    /// CoreAudio device list or default-output changed. Keep the picker fresh and,
    /// if running, fail over when our real sink has vanished (e.g. AirPods unplugged).
    private func handleDeviceChange() {
        guard !handlingChange else { return }
        handlingChange = true
        defer { handlingChange = false }

        refreshLoopbackFlags()
        let devices = engine.outputDevices()
        outputs = devices
        if let sel = selectedOutputID, !devices.contains(where: { $0.id == sel }) { selectedOutputID = nil }

        followDefaultOutputChange()

        guard isOn else {
            let cur = SpatialEngine.currentDefaultOutput()
            if !SpatialEngine.isLoopbackDevice(cur.id) { outputName = cur.name }
            return
        }
        if let sink = activeSinkID, !devices.contains(where: { $0.id == sink }) {
            recoverFromLostSink(devices)
        }
    }

    /// The system default output changed (Control Centre, headphones plugged in, …).
    /// Apply that device's profile and, if we're running and not pinned to a sink, move
    /// the render there. In loopback mode the default IS our virtual device, so skip.
    private func followDefaultOutputChange() {
        guard selectedOutputID == nil else { return }
        let cur = SpatialEngine.currentDefaultOutput()
        if SpatialEngine.isLoopbackDevice(cur.id) { return }
        guard cur.id != kAudioObjectUnknown, cur.id != lastProfiledDeviceID else { return }

        applyProfile(for: cur.id)
        outputName = cur.name
        if isOn && !bypassed && activeSinkID != cur.id { switchSink(to: cur.id) }
    }

    /// Move the running graph to a different real sink (same capture source).
    private func switchSink(to id: AudioDeviceID) {
        guard isOn else { return }
        engine.stop()
        if let d = outputs.first(where: { $0.id == id }) {
            config.outputType = outputType(for: d)
            outputName = d.name
        }
        resolveAlgorithm()
        engine.config = config
        do {
            try engine.start(outputDeviceID: id, captureDeviceID: activeCaptureID)
            activeSinkID = id
            lastError = nil
            updateActivity()
        } catch {
            lastError = "Could not follow the output change — \(error)"
            powerOff()
        }
    }

    /// Our render sink disappeared mid-session — fail over to another real device if one
    /// exists (atmos-control stays the capture default), else power down safely.
    private func recoverFromLostSink(_ devices: [AudioOutputDevice]) {
        selectedOutputID = nil
        guard let fallback = devices.first(where: { $0.isAirPods }) ?? devices.first(where: { !$0.isAirPods }) ?? devices.first else {
            lastError = "Output device disconnected — engine stopped."
            powerOff()
            return
        }
        engine.stop()
        config.outputType = outputType(for: fallback)
        engine.config = config
        do {
            try engine.start(outputDeviceID: fallback.id, captureDeviceID: activeCaptureID)
            activeSinkID = fallback.id
            outputName = fallback.name
            lastError = "Output changed — now routing to \(fallback.name)."
            updateActivity()
        } catch {
            lastError = "Output device lost — \(error)"
            powerOff()
        }
    }

    // MARK: Surface visibility

    /// Poll meters + run head-motion only while a window is actually on screen — the
    /// engine keeps spatializing when closed, but nobody's looking at the live readouts.
    /// (Counted because the panel and settings window can be open independently.)
    /// Panel (MenuBarExtra popover) visibility — the authoritative signal is the popover
    /// NSWindow (see bindPanelWindow). onAppear/onDisappear are kept only as a fallback.
    func panelAppeared()    { panelOnScreen = true;  updateActivity() }
    func panelDisappeared() { panelOnScreen = false; updateActivity() }
    /// Settings is a normal Window scene whose onAppear/onDisappear are reliable.
    func settingsAppeared()    { settingsOnScreen = true;  updateActivity() }
    func settingsDisappeared() { settingsOnScreen = false; updateActivity() }

    private var anySurfaceVisible: Bool { panelOnScreen || settingsOnScreen }

    /// Bind the panel popover's hosting NSWindow (handed over by WindowAccessor when the
    /// view moves in/out of a window). Drives visibility from the window leaving the
    /// hierarchy AND from occlusion — so polling/motion stop the instant the popover is
    /// dismissed, even though SwiftUI does not reliably deliver .onDisappear for it.
    func bindPanelWindow(_ window: NSWindow?) {
        guard window !== panelWindow else { return }
        if let obs = panelOcclusionObserver {
            NotificationCenter.default.removeObserver(obs)
            panelOcclusionObserver = nil
        }
        panelWindow = window
        guard let window else { panelOnScreen = false; updateActivity(); return }
        // OR so a transient not-yet-on-screen occlusion read at bind time can't clobber a
        // `true` just set by onAppear; the observer below corrects it within a frame anyway.
        panelOnScreen = panelOnScreen || window.occlusionState.contains(.visible)
        panelOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Registered for this window only; read it back on the main actor (avoids
                // sending the non-Sendable Notification across the isolation boundary).
                let visible = self.panelWindow?.occlusionState.contains(.visible) ?? false
                if self.panelOnScreen != visible { self.panelOnScreen = visible; self.updateActivity() }
            }
        }
        updateActivity()
    }

    private func updateActivity() {
        // The panel no longer draws meters or the soundstage radar (F8), so it only needs
        // a slow tick for the status chips; the full 15 Hz is for the settings window's
        // meters and radar. Idle menu-bar use therefore costs ~2 wake-ups a second.
        if isOn && anySurfaceVisible && !asleep {
            startPolling(interval: settingsOnScreen ? 1.0 / 15.0 : 1.0 / 2.0)
        } else {
            stopPolling()
        }
        syncMotion()
    }

    // MARK: Head-pose motion

    /// Run head-pose updates only while on, head-tracking enabled, AND a surface visible.
    /// (Real audio head-tracking is AUSpatialMixer property 3111 — independent of this.)
    private func syncMotion() {
        if isOn && config.headTracking && anySurfaceVisible && motion.isAvailable {
            motion.start()
        } else {
            motion.stop()
            headPoseLive = false
            headYaw = 0
        }
    }

    // MARK: Power

    func toggle() {
        if isOn { powerOff(); return }
        watchdogRecoveries = 0      // a deliberate power-on is a fresh start

        // Powering on while a bypass profile is active is an explicit override for this
        // session (the stored profile is untouched — §5.4).
        if bypassed { bypassOverride = true; bypassed = false; poweredOffByBypass = false }
        powerOn()
    }

    func powerOn() {
        refreshLoopbackFlags()
        permissionNeeded = false
        // Honour this device's profile before we touch any audio.
        if let sink = currentSinkID() { applyProfile(for: sink) }
        resolveAlgorithm()
        if bypassed && !bypassOverride {
            lastError = nil
            return                      // profile says: leave this device alone
        }
        if captureMode == .processTap { startTapMode(); return }
        startLoopbackMode()   // explicit virtual-device (loopback) mode — never an auto-fallback
    }

    /// Deep-link into System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording.
    /// The process-tap grant (kTCCServiceAudioCapture, "System Audio Recording Only") lives
    /// there — NOT under Microphone, which is a different TCC service entirely.
    func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Explicit, user-initiated retry after a permission failure (does NOT change routing).
    func retryCapture() { permissionNeeded = false; powerOn() }

    /// Explicit, user-initiated switch to the virtual-device path (this one DOES change the
    /// default output — so it only happens on a deliberate tap, never as a silent fallback).
    func switchToVirtualDevice() {
        permissionNeeded = false
        setCaptureChoice(.virtualStereo)
        if !isOn { powerOn() }
    }

    /// Personalized capture via a muting process tap. AirPods stay the default output so
    /// property 3116 engages; we never hijack the default → no black-hole, nothing to restore.
    private func startTapMode() {
        let devices = engine.outputDevices()
        outputs = devices
        let current = SpatialEngine.currentDefaultOutput()
        // Render to the current default (where 3116 keys) unless the user picked a sink.
        let real: AudioOutputDevice?
        if let sel = selectedOutputID, let d = devices.first(where: { $0.id == sel }) { real = d }
        else { real = devices.first(where: { $0.id == current.id }) ?? devices.first(where: { $0.isAirPods }) }

        do {
            // Hand the tap the sink we are about to render to: it is used to prime our HAL
            // process object (so we can be excluded from the tap) and, in `.anchored`
            // aggregate mode, as the aggregate's main sub-device.
            let aggID = try tap.start(muted: true, outputDeviceID: real?.id)
            if let r = real { config.outputType = outputType(for: r); outputName = r.name }
            engine.config = config
            try engine.start(outputDeviceID: real?.id, captureDeviceID: aggID)
            activeCaptureID = aggID
            activeSinkID = real?.id
            savedDefault = nil
            isOn = true
            startWatchdog()
            lastError = nil
            permissionNeeded = false
            tapDiagnostics = tap.diagnostics
            tapWarning = tap.selfExcluded ? nil
                : "Could not exclude this app from the tap, so muting is off — you may hear the "
                + "original audio alongside the spatialized one. Restart the app."
            startSilenceProbe()
            updateActivity()
        } catch {
            tapDiagnostics = tap.diagnostics
            tap.stop()
            // Distinguish a (likely) consent denial from any other tap failure. Tap CREATION
            // failing is overwhelmingly the audio-capture TCC gate; aggregate/UID failures are
            // infrastructure errors. Never auto-fall-back to loopback (that mutates routing).
            if let e = error as? ProcessTapError, case .createTapFailed = e {
                permissionNeeded = true
                lastError = nil
            } else {
                permissionNeeded = false
                lastError = "Personalized capture unavailable: \(error)."
            }
        }
    }

    /// Loopback capture: hijack the system default to the surround loopback device
    /// (bundled atmos-control driver preferred, else BlackHole 16ch — Issue #1 §4).
    /// Generic HRTF only (personalization blocked by the virtual default); restores on off.
    private func startLoopbackMode() {
        guard let loop = SpatialEngine.surroundCaptureDeviceID() else {
            lastError = "Surround loopback not found — install the HAL driver (./install.sh --with-driver), install BlackHole 16ch, or use Personalized (tap) mode."
            return
        }
        let loopName = engine.surroundCaptureName()
        let current = SpatialEngine.currentDefaultOutput()
        savedDefault = current.id
        let devices = engine.outputDevices()
        outputs = devices
        let real: AudioOutputDevice?
        if let sel = selectedOutputID, let d = devices.first(where: { $0.id == sel }) {
            real = d
        } else if SpatialEngine.isLoopbackDevice(current.id) {
            real = devices.first(where: { $0.isAirPods }) ?? devices.first
        } else {
            real = devices.first(where: { $0.id == current.id })
        }
        if let r = real { config.outputType = outputType(for: r); outputName = r.name }
        engine.config = config

        SpatialEngine.setDefaultOutput(loop)
        do {
            try engine.start(outputDeviceID: real?.id, captureDeviceID: loop)
            activeCaptureID = loop
            activeSinkID = real?.id ?? (SpatialEngine.isLoopbackDevice(current.id) ? nil : current.id)
            isOn = true
            startWatchdog()
            lastError = nil
            surroundCaptureName = loopName
            updateActivity()
        } catch {
            lastError = "\(error)"
            restoreSafeDefault()   // never leave the system default on the virtual sink
        }
    }

    func powerOff() {
        stopSilenceProbe()
        stopWatchdog()
        tapWarning = nil
        engine.stop()
        if tap.isActive { tap.stop() }
        // Restore the system default ONLY if loopback mode actually hijacked it (savedDefault
        // set while in loopback mode). Idle/tap quit (no hijack) must NOT touch routing —
        // otherwise the terminate hook would yank the user's output to speakers on every
        // quit even if we never powered on.
        if captureMode == .loopbackDriver && savedDefault != nil { restoreSafeDefault() } else { savedDefault = nil }
        isOn = false
        activeSinkID = nil
        activeCaptureID = nil
        personalizedHRTFEngaged = false
        ringFill = 0; totalCaptured = 0; totalPlayed = 0
        meterL = 0; meterR = 0; peakHoldL = 0; peakHoldR = 0
        if !channelPeaks.isEmpty { channelPeaks = [] }
        updateActivity()
    }

    /// Switch the capture path (restarts the engine if running).
    func setCaptureMode(_ m: CaptureMode) {
        guard captureMode != m else { return }
        captureMode = m
        scheduleSave()
        if isOn { powerOff(); powerOn() }
    }

    /// Restore the system default to a present, real (non-virtual) device. Prefers the
    /// saved pre-power-on default; falls back to built-in speakers / any real sink so we
    /// never strand the default on a loopback (which black-holes audio).
    private func restoreSafeDefault() {
        let present = engine.outputDevices()
        if let s = savedDefault, !SpatialEngine.isLoopbackDevice(s), present.contains(where: { $0.id == s }) {
            SpatialEngine.setDefaultOutput(s)
        } else if let speakers = present.first(where: { $0.name.localizedCaseInsensitiveContains("speaker") })
                    ?? present.first(where: { !$0.isAirPods }) ?? present.first {
            SpatialEngine.setDefaultOutput(speakers.id)
        }
        savedDefault = nil
    }

    // MARK: Config changes

    /// Apply a rebuild-class config change (output type, HRTF, algorithm, source mode,
    /// head tracking). Brief audio gap while running.
    func applyConfig() {
        scheduleSave()
        guard isOn else { engine.config = config; return }
        do { try engine.reconfigure(config); updateActivity() }
        catch { lastError = "\(error)"; powerOff() }
    }

    /// Live source position/gain/width (no rebuild).
    func setSource(azimuth: Float? = nil, elevation: Float? = nil, distance: Float? = nil,
                   gain: Float? = nil, width: Float? = nil) {
        if let a = azimuth { config.azimuth = a }
        if let e = elevation { config.elevation = e }
        if let d = distance { config.distance = d }
        if let g = gain { config.gain = g }
        if let w = width { config.stereoWidth = w }
        engine.updateSource(azimuth: azimuth, elevation: elevation, distance: distance, gain: gain, width: width)
        scheduleSave()
    }

    // MARK: Equalizer (all live — the EQ never rebuilds the graph)

    /// The pre-amp actually in force (auto-computed from the curve, or the manual value).
    var eqPreampDB: Float { config.eq.effectivePreamp(sampleRate: engine.currentSampleRate) }

    /// Composite response peak of the current curve, before the pre-amp (UI readout).
    var eqPeakDB: Float { EQConfig.peakResponseDB(gains: config.eq.normalizedGains,
                                                  sampleRate: engine.currentSampleRate) }

    func setEQEnabled(_ on: Bool) {
        guard config.eq.enabled != on else { return }
        config.eq.enabled = on
        pushEQ()
    }

    func setEQGain(band: Int, _ value: Float) {
        var g = config.eq.normalizedGains
        guard band >= 0, band < g.count else { return }
        let v = min(max(value, -EQConfig.gainLimit), EQConfig.gainLimit)
        guard abs(g[band] - v) > 0.001 else { return }
        g[band] = v
        config.eq.gains = g
        pushEQ()
    }

    func setEQGains(_ gains: [Float]) {
        config.eq.gains = gains
        config.eq = EQConfig(enabled: config.eq.enabled, gains: config.eq.normalizedGains,
                             preampMode: config.eq.preampMode, manualPreamp: config.eq.manualPreamp)
        pushEQ()
    }

    func resetEQ() {
        guard !config.eq.isFlat else { return }
        config.eq.gains = Array(repeating: 0, count: EQConfig.bandCount)
        pushEQ()
    }

    func setPreampMode(_ mode: PreampMode) {
        guard config.eq.preampMode != mode else { return }
        // Switching auto -> manual hands over the value that was in force, so nothing jumps.
        if mode == .manual { config.eq.manualPreamp = config.eq.effectivePreamp(sampleRate: engine.currentSampleRate) }
        config.eq.preampMode = mode
        pushEQ()
    }

    func setManualPreamp(_ value: Float) {
        let v = min(max(value, -EQConfig.preampLimit), EQConfig.gainLimit)
        guard abs(config.eq.manualPreamp - v) > 0.001 else { return }
        config.eq.manualPreamp = v
        pushEQ()
    }

    private func pushEQ() { engine.updateEQ(config.eq); scheduleSave() }

    /// Master spatial-audio switch (panel). Turning it off drops the whole mixer — and
    /// with it the upmixer, whose output has nowhere to go.
    func setSpatialize(_ on: Bool) {
        guard config.spatialize != on else { return }
        config.spatialize = on
        syncUpmixMode()
        applyConfig()
    }

    // MARK: Upmix (F4)

    /// The upmixer only exists on the stereo capture paths, and only when we're
    /// spatializing (its output is a virtual speaker rig for the spatial mixer).
    var upmixAvailable: Bool { config.spatialize && captureChoice != .surround }

    var upmixEnabled: Bool { config.upmix.enabled }

    /// Theoretical added latency of the STFT (one analysis window) — shown, not measured.
    var upmixLatencyMS: Double {
        config.upmix.latencyMS(sampleRate: isOn ? engine.currentSampleRate : 48_000)
    }

    /// Structural switch: the source render mode changes, so the graph is rebuilt
    /// (100–300 ms of silence — documented and accepted, §4.7).
    func setUpmixEnabled(_ on: Bool) {
        guard config.upmix.enabled != on else { return }
        config.upmix.enabled = on
        syncUpmixMode()
        applyConfig()
    }

    func setUpmixLayout(_ layout: UpmixLayout) {
        guard config.upmix.layout != layout else { return }
        config.upmix.layout = layout
        syncUpmixMode()
        applyConfig()
    }

    func setUpmixFFTSize(_ size: Int) {
        guard config.upmix.fftSize != size else { return }
        config.upmix.fftSize = size
        applyConfig()
    }

    /// Continuous upmix parameters — applied live, no rebuild.
    func setUpmix(center: Float? = nil, surroundLevel: Float? = nil, heightLevel: Float? = nil,
                  decorrelation: Float? = nil, ambientBias: Float? = nil,
                  surroundSpread: Float? = nil, lfe: LFEMode? = nil,
                  strength: Float? = nil, spread: Float? = nil, transients: Float? = nil,
                  reflectionsLevel: Float? = nil, bassManagement: Bool? = nil,
                  autoLevel: Bool? = nil) {
        if let v = center { config.upmix.centerStrength = v }
        if let v = surroundLevel { config.upmix.surroundLevel = v }
        if let v = heightLevel { config.upmix.heightLevel = v }
        if let v = decorrelation { config.upmix.decorrelation = v }
        if let v = ambientBias { config.upmix.ambientBias = v }
        if let v = surroundSpread { config.upmix.surroundSpread = v }
        if let v = lfe { config.upmix.lfeMode = v }
        if let v = strength { config.upmix.strength = v }
        if let v = spread { config.upmix.spread = v }
        if let v = transients { config.upmix.transients = v }
        if let v = reflectionsLevel { config.upmix.reflectionsLevel = v }
        if let v = bassManagement { config.upmix.bassManagement = v }
        if let v = autoLevel { config.upmix.autoLevel = v }
        engine.updateUpmix(config.upmix)
        // surroundSpread moves the virtual speakers themselves: that's a mixer parameter,
        // so push it through reconfigure (no rebuild — it lands in applySourceParams).
        if surroundSpread != nil { applyConfig() } else { scheduleSave() }
    }

    func resetUpmix() {
        var u = UpmixConfig()
        u.enabled = config.upmix.enabled
        u.layout = config.upmix.layout
        u.fftSize = config.upmix.fftSize
        config.upmix = u
        engine.updateUpmix(u)
        applyConfig()
    }

    /// Keep `sourceMode` consistent with the upmix switch. The upmix modes are not user
    /// selectable in the Source mode picker — this is the only thing that sets them.
    private func syncUpmixMode() {
        if config.upmix.enabled && upmixAvailable {
            let want: SourceRenderMode = config.upmix.layout == .surround714 ? .upmix714 : .upmix51
            if config.sourceMode != want { config.sourceMode = want }
        } else if config.sourceMode.isUpmix {
            config.sourceMode = .dualPointStereo
        }
    }

    // MARK: Spatial presets

    var selectedSpatialPreset: SpatialPreset? { spatialPresets.first { $0.id == selectedSpatialPresetID } }

    var spatialDirty: Bool {
        guard let p = selectedSpatialPreset else { return false }
        return !p.matches(config)
    }

    func spatialPresetLabel(_ p: SpatialPreset) -> String {
        (p.id == selectedSpatialPresetID && spatialDirty) ? "\(p.name) •" : p.name
    }

    func applySpatialPreset(_ id: UUID) {
        guard let p = spatialPresets.first(where: { $0.id == id }) else { return }
        selectedSpatialPresetID = id
        config = p.applied(to: config)
        // The preset carries its own upmix settings, but `sourceMode` is what actually
        // switches the upmixer in and out of the graph — re-derive it, or the UI reads
        // "Upmix off" while the engine keeps rendering the old topology.
        syncUpmixMode()
        resolveAlgorithm()
        applyConfig()
    }

    func saveSelectedSpatialPreset() {
        guard let idx = spatialPresets.firstIndex(where: { $0.id == selectedSpatialPresetID }),
              !spatialPresets[idx].isBuiltIn else { return }
        spatialPresets[idx].spatial = SpatialPreset.staging(of: config)
        spatialPresets[idx].modifiedAt = Date()
        scheduleSave()
    }

    @discardableResult
    func saveSpatialPresetAs(_ rawName: String) -> Bool {
        let name = uniqueName(rawName, taken: spatialPresets.map(\.name))
        guard !name.isEmpty else { return false }
        let p = SpatialPreset.capture(from: config, name: name)
        spatialPresets.append(p)
        selectedSpatialPresetID = p.id
        scheduleSave()
        return true
    }

    func renameSpatialPreset(_ id: UUID, to rawName: String) {
        guard let idx = spatialPresets.firstIndex(where: { $0.id == id }), !spatialPresets[idx].isBuiltIn else { return }
        let name = uniqueName(rawName, taken: spatialPresets.filter { $0.id != id }.map(\.name))
        guard !name.isEmpty else { return }
        spatialPresets[idx].name = name
        spatialPresets[idx].modifiedAt = Date()
        scheduleSave()
    }

    func deleteSpatialPreset(_ id: UUID) {
        guard let idx = spatialPresets.firstIndex(where: { $0.id == id }), !spatialPresets[idx].isBuiltIn else { return }
        spatialPresets.remove(at: idx)
        if selectedSpatialPresetID == id { selectedSpatialPresetID = SpatialPreset.defaultID }
        // A profile pointing at a deleted preset falls back to Default.
        for i in deviceProfiles.indices where deviceProfiles[i].spatialPresetID == id {
            deviceProfiles[i].spatialPresetID = SpatialPreset.defaultID
        }
        if fallbackProfile.spatialPresetID == id { fallbackProfile.spatialPresetID = SpatialPreset.defaultID }
        scheduleSave()
    }

    private func uniqueName(_ raw: String, taken: [String]) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        let set = Set(taken)
        if !set.contains(base) { return base }
        var n = 2
        while set.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Algorithm auto-selection (§5.6)

    /// Reverb is inert under Use Output Type, and under Automatic we can't promise which
    /// algorithm a given device will get — so the reverb controls grey out in both cases.
    var reverbControlsDisabled: Bool {
        config.algorithmMode == .automaticByDevice || config.algorithm == .useOutputType
    }

    /// What Automatic resolves to for the current sink (UI copy + the actual decision).
    var automaticAlgorithm: SpatAlgorithm { currentSinkIsAirPods ? .useOutputType : .hrtfHQ }

    private var currentSinkIsAirPods: Bool {
        if let id = currentSinkID(), let d = outputs.first(where: { $0.id == id }) { return d.isAirPods }
        return outputName.localizedCaseInsensitiveContains("airpods")
    }

    /// Write the resolved algorithm into the config. No-op when the user picked one.
    private func resolveAlgorithm() {
        guard config.algorithmMode == .automaticByDevice else { return }
        let want = automaticAlgorithm
        if config.algorithm != want { config.algorithm = want }
    }

    func setAlgorithmMode(_ mode: AlgorithmMode, fixed: SpatAlgorithm? = nil) {
        config.algorithmMode = mode
        if let f = fixed { config.algorithm = f }
        resolveAlgorithm()
        applyConfig()
    }

    // MARK: Device profiles (F7)

    /// The sink audio is (or would be) rendered to: the explicit choice, else the system
    /// default — never a virtual loopback itself.
    private func currentSinkID() -> AudioDeviceID? {
        if let sel = selectedOutputID { return sel }
        if let active = activeSinkID { return active }
        let cur = SpatialEngine.currentDefaultOutput()
        if SpatialEngine.isLoopbackDevice(cur.id) { return nil }
        return cur.id
    }

    /// UID → name → fallback (§5.3).
    func resolveProfile(for device: AudioDeviceID) -> DeviceProfile {
        let uid = SpatialEngine.uid(of: device)
        if let p = deviceProfiles.first(where: { !$0.deviceUID.isEmpty && $0.deviceUID == uid }) { return p }
        let name = outputs.first(where: { $0.id == device })?.name ?? SpatialEngine.currentDefaultOutput().name
        if let p = deviceProfiles.first(where: { $0.deviceName == name }) { return p }
        return fallbackProfile
    }

    /// Profile for the device we're currently pointed at (fallback when nothing matches).
    var activeProfile: DeviceProfile? {
        guard let id = currentSinkID() else { return nil }
        return resolveProfile(for: id)
    }

    /// True when the live state differs from what the active profile says — the cue for
    /// the "Save to this device" button (manual changes are session-scoped, §5.4).
    var profileDirty: Bool {
        guard let p = activeProfile else { return false }
        return !p.matches(eqEnabled: config.eq.enabled, eqPreset: selectedEQPresetID,
                          spatialEnabled: config.spatialize, spatialPreset: selectedSpatialPresetID,
                          upmixEnabled: config.upmix.enabled, bypassed: bypassed && !bypassOverride)
    }

    /// Apply the profile matching a device. Called on output change and before power-on.
    func applyProfile(for device: AudioDeviceID, force: Bool = false) {
        guard force || device != lastProfiledDeviceID else { return }
        lastProfiledDeviceID = device
        bypassOverride = false
        profiledDeviceName = outputs.first(where: { $0.id == device })?.name ?? SpatialEngine.currentDefaultOutput().name

        let p = resolveProfile(for: device)
        guard p.autoSwitch else { bypassed = false; resolveAlgorithm(); return }

        if p.mode == .bypass {
            bypassed = true
            if isOn { poweredOffByBypass = true; powerOff() }
            return
        }

        let wasBypassed = bypassed
        bypassed = false
        if let eqID = p.eqPresetID, eqPresets.contains(where: { $0.id == eqID }) { applyEQPreset(eqID) }
        setEQEnabled(p.eqEnabled)
        if let spID = p.spatialPresetID, spatialPresets.contains(where: { $0.id == spID }),
           let preset = spatialPresets.first(where: { $0.id == spID }) {
            selectedSpatialPresetID = spID
            config = preset.applied(to: config)
        }
        config.spatialize = p.spatialEnabled
        config.upmix.enabled = p.upmixEnabled
        syncUpmixMode()
        resolveAlgorithm()
        applyConfig()

        // We stopped for a bypassed device; this one is processed, so come back up.
        if wasBypassed && poweredOffByBypass && !isOn {
            poweredOffByBypass = false
            powerOn()
        }
    }

    /// Write the current live state into (or create) the profile for the current device.
    func saveCurrentToDeviceProfile() {
        guard let id = currentSinkID() else { return }
        let uid = SpatialEngine.uid(of: id)
        let name = outputs.first(where: { $0.id == id })?.name ?? profiledDeviceName
        var p: DeviceProfile
        if let idx = deviceProfiles.firstIndex(where: { !$0.deviceUID.isEmpty && $0.deviceUID == uid }) {
            p = deviceProfiles[idx]
        } else {
            p = DeviceProfile.suggested(forName: name, uid: uid,
                                        transportIsDisplay: SpatialEngine.isDisplayTransport(id))
        }
        p.deviceUID = uid
        p.deviceName = name
        p.mode = (bypassed && !bypassOverride) ? .bypass : .process
        p.eqEnabled = config.eq.enabled
        p.eqPresetID = selectedEQPresetID
        p.spatialEnabled = config.spatialize
        p.spatialPresetID = selectedSpatialPresetID
        p.upmixEnabled = config.upmix.enabled
        p.autoSwitch = true
        if let idx = deviceProfiles.firstIndex(where: { $0.id == p.id }) { deviceProfiles[idx] = p }
        else { deviceProfiles.append(p) }
        lastProfiledDeviceID = id
        scheduleSave()
    }

    /// Discard session-scoped changes and re-apply the stored profile.
    func revertToDeviceProfile() {
        guard let id = currentSinkID() else { return }
        applyProfile(for: id, force: true)
    }

    /// Add a profile for the current device without changing anything about it.
    func addProfileForCurrentDevice() {
        guard let id = currentSinkID() else { return }
        let uid = SpatialEngine.uid(of: id)
        guard !deviceProfiles.contains(where: { $0.deviceUID == uid }) else { return }
        let name = outputs.first(where: { $0.id == id })?.name ?? profiledDeviceName
        deviceProfiles.append(DeviceProfile.suggested(forName: name, uid: uid,
                                                      transportIsDisplay: SpatialEngine.isDisplayTransport(id)))
        scheduleSave()
    }

    func removeProfile(_ id: UUID) {
        deviceProfiles.removeAll { $0.id == id }
        lastProfiledDeviceID = nil
        scheduleSave()
    }

    func updateProfile(_ p: DeviceProfile) {
        if p.isFallback { fallbackProfile = p }
        else if let idx = deviceProfiles.firstIndex(where: { $0.id == p.id }) { deviceProfiles[idx] = p }
        scheduleSave()
        // Re-apply if we just edited the profile in force for the current device.
        if let id = currentSinkID(), resolveProfile(for: id).id == p.id { applyProfile(for: id, force: true) }
    }

    /// True when this device already has its own profile (vs. riding the fallback).
    var currentDeviceHasProfile: Bool {
        guard let id = currentSinkID() else { return false }
        return !resolveProfile(for: id).isFallback
    }

    /// Live reverb wet/dry blend (no rebuild; no-op in the engine unless the reverb path is
    /// active, i.e. HRTF / HRTF-HQ).
    func setReverbBlend(_ v: Float) {
        config.reverbBlend = v
        engine.updateReverb(blend: v)
        scheduleSave()
    }

    /// Reset the soundstage to the front-and-centre default (F13 / amendment B).
    func resetSoundstage() {
        setSource(azimuth: 0, elevation: 0, distance: Float(Param.distance.def),
                  gain: 0, width: Float(Param.width.def))
    }

    /// Reset the advanced rendering block to its defaults (amendment B).
    func resetRendering() {
        config.interauralDelay = true
        config.distanceAttenuation = true
        config.attenuationCurve = .inverse
        config.distanceRef = Float(Param.distanceRef.def)
        config.distanceMax = Float(Param.distanceMax.def)
        config.distanceMaxAtten = Float(Param.distanceAtten.def)
        config.reverbEnabled = true
        config.reverbRoomType = .small
        config.reverbBlend = Float(Param.reverbBlend.def)
        config.globalReverbGain = Float(Param.reverbGain.def)
        config.algorithmMode = .automaticByDevice
        resolveAlgorithm()
        applyConfig()
    }

    // MARK: Polling

    private func startPolling(interval: TimeInterval) {
        // Idempotent: only rebuild the timer when the rate actually has to change.
        guard timer == nil || pollInterval != interval else { return }
        stopPolling()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval / 2   // let the OS coalesce wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
        pollInterval = interval
    }

    private func stopPolling() { timer?.invalidate(); timer = nil; pollInterval = 0 }

    // MARK: IO watchdog (spec §8 P6)

    /// Fires every 2 s while the engine is on, independently of any window being visible.
    /// It answers one question: are frames still moving? A graph that is "running" but has
    /// stopped calling its IO procs is the failure mode behind every "it just went silent"
    /// report — the device reset under us, the aggregate lost a sub-device, or the tap died.
    /// The engine can't notice (no callback = no error); only an outside clock can.
    private func startWatchdog() {
        stopWatchdog()
        lastIO = engine.ioCounters()
        stallTicks = 0; captureStallTicks = 0; healthyTicks = 0
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.invalidate(); watchdog = nil
        stallTicks = 0; captureStallTicks = 0; healthyTicks = 0
        // NB: watchdogRecoveries deliberately survives stop/start — a recovery that goes
        // through powerOff/powerOn must still count against the budget, or a device that
        // fails on every start would have us restarting it forever.
    }

    private func watchdogTick() {
        guard isOn, !asleep else { return }
        let io = engine.ioCounters()
        defer { lastIO = io }

        // Output stalled: nothing is being rendered to the device at all. ~6 s of silence
        // before acting, because a rebuild is audible and a false positive is worse than
        // two extra seconds of waiting.
        if io.played == lastIO.played {
            stallTicks += 1
            if stallTicks >= 3 { recoverFromStall("output"); return }
        } else {
            stallTicks = 0
        }

        // Capture stalled while output keeps running: the tap/loopback source died, so the
        // graph is faithfully rendering an empty ring. Give this one longer (10 s) — a
        // sub-device can take its time coming back on its own after a device change.
        if io.captured == lastIO.captured && io.played != lastIO.played {
            captureStallTicks += 1
            if captureStallTicks >= 5 { recoverFromStall("capture"); return }
        } else {
            captureStallTicks = 0
        }

        // 30 s of clean flow means whatever went wrong is behind us: let the recovery
        // budget refill, so a glitch now and a glitch next week don't add up to a power-off.
        if io.played != lastIO.played && io.captured != lastIO.captured {
            healthyTicks += 1
            if healthyTicks >= 15 { healthyTicks = 0; watchdogRecoveries = 0 }
        } else {
            healthyTicks = 0
        }
    }

    private func recoverFromStall(_ side: String) {
        stallTicks = 0; captureStallTicks = 0
        // Don't sit in a restart loop: after three attempts the problem isn't transient.
        guard watchdogRecoveries < 3 else {
            lastError = "Audio stopped flowing and restarting didn't help — engine powered off."
            powerOff()
            return
        }
        watchdogRecoveries += 1
        do {
            try engine.restartInPlace()
            lastIO = engine.ioCounters()
            healthyTicks = 0
            lastError = "Audio stalled (\(side)) — the engine restarted itself."
            updateActivity()
        } catch {
            // In tap mode a stopped engine plus a live tap = the whole system stays muted,
            // so this can never be left half-up. Rebuild the whole path (new tap, re-resolved
            // sink); powerOn reports its own error if that fails too.
            powerOff()
            lastError = "Audio stalled — rebuilding the audio path."
            powerOn()
        }
    }

    // MARK: Sleep / wake

    /// Sleep stops all IO, which would look exactly like a stall; and on wake the devices
    /// are often not back yet. Park the watchdog across the transition and rebuild once,
    /// after a settling delay, instead of fighting the HAL while it reinitialises.
    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.asleep = true
                self.stopPolling()
            }
        })
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.asleep = false
                self.updateActivity()
                guard self.isOn else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isOn, !self.asleep else { return }
                        // Re-evaluate the sink first (the default output often changes over
                        // sleep), then let the watchdog resume from a clean baseline.
                        self.handleDeviceChange()
                        self.lastIO = self.engine.ioCounters()
                        self.stallTicks = 0; self.captureStallTicks = 0
                        self.watchdogRecoveries = 0
                    }
                }
            }
        })
    }

    // MARK: Silent-capture probe

    /// Watch the capture side for "buffers arrive, every sample is 0.0". Runs independently
    /// of the UI poll timer (which only runs while a window is visible) because the whole
    /// point is to catch a silently denied grant while the user is staring at a quiet Mac.
    private func startSilenceProbe() {
        stopSilenceProbe()
        silenceTicks = 0
        silentCaptureSuspected = false
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.silenceTick() }
        }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        silenceProbe = t
    }

    private func stopSilenceProbe() {
        silenceProbe?.invalidate()
        silenceProbe = nil
        silenceTicks = 0
        if silentCaptureSuspected { silentCaptureSuspected = false }
    }

    private func silenceTick() {
        guard isOn else { stopSilenceProbe(); return }
        if engine.peakSinceStart() > 0 {
            // Real audio has flowed at least once: the grant is in place. Stop watching.
            if silentCaptureSuspected { silentCaptureSuspected = false }
            silenceProbe?.invalidate()
            silenceProbe = nil
            return
        }
        silenceTicks += 1
        if silenceTicks >= 2 && !silentCaptureSuspected { silentCaptureSuspected = true }
    }

    private func tick() {
        let s = engine.pollState()
        // Fan the poll struct out into individual tracked properties, each guarded against
        // no-op writes. ringFill/totalCaptured/totalPlayed change every tick during playback
        // but are read ONLY by SettingsView, so they invalidate the panel only when it's open.
        if personalizedHRTFEngaged != s.personalizedHRTFEngaged { personalizedHRTFEngaged = s.personalizedHRTFEngaged }
        // Surround Levels meter (settings only): publish the full per-channel peak vector when
        // in a 12-channel mode, else keep it empty so stereo modes never carry the extra array.
        if s.peaks.count > 2 {
            if channelPeaks != s.peaks { channelPeaks = s.peaks }
        } else if !channelPeaks.isEmpty {
            channelPeaks = []
        }
        if ringFill != s.ringFill { ringFill = s.ringFill }
        if totalCaptured != s.totalCaptured { totalCaptured = s.totalCaptured }
        if totalPlayed != s.totalPlayed { totalPlayed = s.totalPlayed }
        let nm = s.outputDeviceName
        if !nm.isEmpty && nm != outputName { outputName = nm }   // guard: avoid no-op publishes
        // Meter: fast attack to the new peak, gentle release; hold the peak marker.
        // Snap sub-perceptual levels to exactly 0 and skip unchanged writes so the UI
        // QUIESCES in silence. Otherwise *0.82 / *0.985 only underflow to 0 after tens of
        // seconds, and every @Published write in between redraws the whole observing tree.
        let nL = settle(max(s.peakL, meterL * 0.82))
        let nR = settle(max(s.peakR, meterR * 0.82))
        let hL = settle(max(peakHoldL * 0.985, s.peakL))
        let hR = settle(max(peakHoldR * 0.985, s.peakR))
        if nL != meterL { meterL = nL }
        if nR != meterR { meterR = nR }
        if hL != peakHoldL { peakHoldL = hL }
        if hR != peakHoldR { peakHoldR = hR }
    }

    /// Snap a meter level below the −60 dBFS visual floor to exactly 0 so the decay
    /// reaches a fixed point in one tick instead of asymptotically republishing forever.
    @inline(__always) private func settle(_ x: Float) -> Float { x < 1e-3 ? 0 : x }

    // MARK: Derived UI state

    /// Single truthful personalization status (spec §1): a chip short-form, a settings long-form
    /// with a plain-language reason, and whether the accent "engaged" treatment applies.
    struct HRTFStatus { let short: String; let long: String; let engaged: Bool }

    var hrtfStatus: HRTFStatus {
        if !isOn { return HRTFStatus(short: "—", long: "Inactive — engine off", engaged: false) }
        if personalizedHRTFEngaged {
            return HRTFStatus(short: "Personalized", long: "Personalized — Apple profile active", engaged: true)
        }
        if captureMode == .loopbackDriver {
            return HRTFStatus(short: "Generic", long: "Generic — virtual-device output can’t carry a personalized profile", engaged: false)
        }
        if config.outputType != .headphones {
            return HRTFStatus(short: "Generic", long: "Generic — personalized applies to headphones only", engaged: false)
        }
        if config.algorithm != .useOutputType {
            return HRTFStatus(short: "Generic", long: "Generic — personalized needs the Automatic algorithm", engaged: false)
        }
        return HRTFStatus(short: "Generic", long: "Generic — set AirPods with an Apple personalized profile as the system output", engaged: false)
    }

    /// Head-tracking status (F14): Off (disabled) · Idle (enabled, not tracking) · Tracking
    /// (enabled, engine running AND live pose). Never claim "Tracking" without live pose.
    var headTrackStatus: String {
        guard config.headTracking else { return "Off" }
        return (isOn && headPoseLive) ? "Tracking" : "Idle"
    }
    var headTrackActive: Bool { config.headTracking && isOn && headPoseLive }

    /// True when personalized HRTF (property 3116) can never engage in the current config, so
    /// the HRTF-mode picker should be disabled with a reason (F4).
    var personalizationDisabledReason: String? {
        if captureMode == .loopbackDriver { return "Unavailable with the virtual device." }
        if config.outputType != .headphones { return "Personalized applies to headphones only." }
        if config.algorithm != .useOutputType { return "Needs the Automatic algorithm." }
        return nil
    }

    /// Advisory about Apple Music's Dolby Atmos setting (r4/t4). Only while running; never
    /// written back. In personalized/stereo the ideal is Off; in surround it is Automatic.
    var musicAtmosAdvisory: String? {
        guard isOn else { return nil }
        guard let raw = CFPreferencesCopyAppValue("preferredDolbyAtmosPlaySetting" as CFString,
                                                  "com.apple.Music" as CFString) else { return nil }
        let setting = (raw as? NSNumber)?.intValue ?? -1   // 10=Automatic 20=Always On 30=Off
        if captureChoice == .surround {
            return setting == 10 ? nil : "For true multichannel, set Music ▸ Settings ▸ Playback ▸ Dolby Atmos to Automatic."
        }
        if captureMode == .processTap {
            return setting == 30 ? nil : "For best results set Music ▸ Settings ▸ Playback ▸ Dolby Atmos to Off."
        }
        return nil
    }
}

// dBFS helpers shared by the meters/readouts.
func linearToDb(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }
