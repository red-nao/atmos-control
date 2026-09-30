// PanelView — the compact menu-bar panel: power, truthful status, and the three
// switches you actually reach for (EQ, spatial audio, upmix) with their presets.
//
// Everything that is a *setting* rather than a *choice* lives in Full Control: the
// radar, the meters, the output-type picker and the head-tracking switch were all
// removed from here (F8). What's left answers one question — "what is happening to my
// audio right now, and how do I change it in one click?"

import SwiftUI
import AppKit
import SpatialEngine

struct PanelView: View {
    @Environment(EngineController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    /// Never let the panel run past the screen edge: cap at the visible frame
    /// (already excludes menu bar + Dock), leaving a little breathing room.
    private var maxPanelHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 24 }

    /// Deterministic per-state height — no measure⇄resize loop and no second render pass
    /// (a MenuBarExtra(.window) landmine). Each optional inline row adds a fixed amount; the
    /// ScrollView absorbs any residual overflow. The panel NEVER collapses (F11): a mode that
    /// can't run shows an inline notice, not a stripped-down surface.
    private var panelHeight: CGFloat {
        var h: CGFloat = 384
        if controller.profileDirty { h += 58 }
        if controller.bypassed { h += 62 }
        if controller.permissionNeeded { h += 78 }
        if controller.silentCaptureSuspected { h += 78 }
        if controller.tapWarning != nil { h += 44 }
        if runNotice != nil { h += 46 }
        if controller.musicAtmosAdvisory != nil { h += 30 }
        if controller.lastError != nil { h += 30 }
        return min(h, maxPanelHeight)
    }

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)   // static when it fits, scrolls only when clamped
        .frame(width: 332, height: panelHeight)
        .tint(.instrument)   // unify on the single accent (segmented controls, switch, sliders)
        // Authoritative popover visibility for stopping the poll/motion (see bindPanelWindow);
        // onAppear/onDisappear remain a fallback in case the window signal is unavailable.
        .background(WindowAccessor { controller.bindPanelWindow($0) })
        .onAppear { controller.panelAppeared() }
        .onDisappear { controller.panelDisappeared() }
    }

    // The panel body — rendered once, live, inside the ScrollView.
    private var content: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            Divider()

            statusStrip
            Divider()
            quickControls

            if controller.profileDirty { deviceProfileRow }
            if controller.bypassed { bypassNotice }
            if controller.permissionNeeded { permissionNotice }
            if controller.silentCaptureSuspected { silentCaptureNotice }
            if let w = controller.tapWarning { tapWarningRow(w) }
            if let notice = runNotice { runNoticeRow(notice) }
            if let hint = controller.musicAtmosAdvisory { advisoryRow(hint) }
            if let err = controller.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            MenuBarGlyph(on: controller.isOn).frame(width: 16, height: 16)
            Text("atmos-control").font(.system(size: 15, weight: .semibold))
            Spacer()
            Toggle("", isOn: Binding(get: { controller.isOn }, set: { _ in controller.toggle() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!controller.canRun)
                .help(controller.isOn ? "Stop routing system audio through the spatializer"
                                       : "Route all system audio through the spatializer")
        }
    }

    // MARK: Status

    private var statusStrip: some View {
        let hrtf = controller.hrtfStatus
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                StatusChip(icon: controller.isOn ? "waveform" : "pause", label: "Engine",
                           value: controller.isOn ? "On" : "Off", active: controller.isOn)
                StatusChip(icon: "headphones", label: "Output",
                           value: shortName(controller.outputName), active: controller.isOn)
            }
            HStack(spacing: 14) {
                StatusChip(icon: hrtf.engaged ? "person.fill.viewfinder" : "person.crop.circle",
                           label: "Personalized", value: hrtf.short, active: hrtf.engaged,
                           trailing: {
                               Button { openSettings() } label: {
                                   Image(systemName: "questionmark.circle").font(.system(size: 10))
                               }
                               .buttonStyle(.borderless)
                               .foregroundStyle(.secondary)
                               .help("Why? Open Personalization settings")
                           })
                StatusChip(icon: "gyroscope", label: "Head track",
                           value: controller.headTrackStatus, active: controller.headTrackActive)
            }
        }
    }

    // MARK: Controls — the three switches, each with its preset

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            switchRow("Equalizer", isOn: Binding(get: { controller.config.eq.enabled },
                                                 set: { controller.setEQEnabled($0) }))
            presetRow(selection: Binding(get: { controller.selectedEQPresetID ?? EQPreset.flatID },
                                         set: { controller.applyEQPreset($0) }),
                      items: controller.eqPresets.map { ($0.id, controller.eqPresetLabel($0)) },
                      enabled: controller.config.eq.enabled)

            Divider()

            switchRow("Spatial audio", isOn: Binding(get: { controller.config.spatialize },
                                                     set: { controller.setSpatialize($0) }))
            presetRow(selection: Binding(get: { controller.selectedSpatialPresetID ?? SpatialPreset.defaultID },
                                         set: { controller.applySpatialPreset($0) }),
                      items: controller.spatialPresets.map { ($0.id, controller.spatialPresetLabel($0)) },
                      enabled: controller.config.spatialize)

            HStack(spacing: 8) {
                Text("Upmix to surround")
                    .foregroundStyle(controller.upmixAvailable ? .primary : .secondary)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { controller.upmixEnabled },
                                         set: { controller.setUpmixEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .disabled(!controller.upmixAvailable)
            }
            .padding(.leading, 12)
            .help(controller.upmixAvailable
                  ? "Spread stereo across \(controller.config.upmix.layout.label) virtual speakers (adds \(Int(controller.upmixLatencyMS)) ms)"
                  : "Upmix needs spatial audio on and a stereo capture")
        }
        .font(.system(size: 12))
    }

    /// Bold-ish label + switch: the top line of a block.
    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
    }

    /// Indented "Preset  [ … ▾ ]" line under a switch row.
    private func presetRow(selection: Binding<UUID>, items: [(UUID, String)], enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Preset").foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(items, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .disabled(!enabled)
        }
        .padding(.leading, 12)
        .opacity(enabled ? 1 : 0.5)
    }

    /// Manual changes are session-scoped (§5.4) — offer to pin them to this device.
    private var deviceProfileRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(controller.profiledDeviceName) — unsaved changes")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Button("Save for this device") { controller.saveCurrentToDeviceProfile() }
                    .controlSize(.small)
                Button("Revert") { controller.revertToDeviceProfile() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Inline notices

    /// A one-line notice when the CURRENT capture choice can't run (F11) — never collapses
    /// the panel; offers the no-driver escape hatch.
    private var runNotice: String? {
        guard !controller.canRun else { return nil }
        switch controller.captureChoice {
        case .surround:      return "Surround needs the 12-channel driver — switch to Personalized (no driver needed)."
        case .virtualStereo: return "Virtual device not installed — switch to Personalized (no driver needed)."
        case .personalized:  return nil
        }
    }

    private func runNoticeRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use Personalized capture") { controller.setCaptureChoice(.personalized) }
                .controlSize(.small)
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Audio capture permission needed to route system audio.",
                  systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Privacy Settings") { controller.openPrivacySettings() }
                    .controlSize(.small)
                Button("Retry") { controller.retryCapture() }
                    .controlSize(.small)
            }
        }
    }

    /// Buffers are arriving but every sample is zero. Most often a denied
    /// "System Audio Recording" grant (every Core Audio call still returns noErr);
    /// also perfectly normal when nothing is playing, so the wording stays a hint.
    private var silentCaptureNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No system audio detected for 10s. If something is playing, the "
                + "System Audio Recording permission is probably missing.",
                  systemImage: "waveform.slash")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Privacy Settings") { controller.openPrivacySettings() }
                    .controlSize(.small)
                Button("Retry") { controller.retryCapture() }
                    .controlSize(.small)
            }
        }
    }

    /// This output device's profile says "don't process me" (F7). Not an error — the
    /// original audio is reaching the device untouched, which is the point.
    private var bypassNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Bypassed — \(controller.profiledDeviceName) is set to pass audio through untouched.",
                  systemImage: "arrow.turn.down.right")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Process anyway") { controller.toggle() }
                .controlSize(.small)
        }
    }

    private func tapWarningRow(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 10)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func advisoryRow(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { openSettings() } label: {
                Label("Open Full Controls…", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12))
            }
            .buttonStyle(.link)
            .help("Open the full control surface")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    // MARK: Bindings

    /// Strip a leading possessive owner prefix ("Alex's ", "Мария’s ") for any user/device;
    /// the StatusChip truncates whatever remains with a native tail ellipsis.
    private func shortName(_ s: String) -> String {
        for sep in ["’s ", "'s "] {
            if let r = s.range(of: sep) { return String(s[r.upperBound...]) }
        }
        return s
    }
}

// MARK: - Status chip (icon + label + value; accent only when active, never color-alone)

struct StatusChip<Trailing: View>: View {
    let icon: String
    let label: String
    let value: String
    let active: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(active ? Color.instrument : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(value).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension StatusChip where Trailing == EmptyView {
    init(icon: String, label: String, value: String, active: Bool) {
        self.init(icon: icon, label: label, value: value, active: active, trailing: { EmptyView() })
    }
}

// MARK: - Window accessor (hands the popover's hosting NSWindow to the controller)

/// Reports its hosting NSWindow whenever the view enters/leaves a window. Used to drive
/// authoritative visibility for the MenuBarExtra(.window) popover: viewDidMoveToWindow(nil)
/// fires on dismissal even when SwiftUI never delivers .onDisappear. All callbacks happen on
/// the main thread (AppKit), so no cross-actor sending is involved.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let v = WindowReportingView()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onWindow = onWindow
    }
}

final class WindowReportingView: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}
