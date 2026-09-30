// AtmosControlApp/ProfilesView.swift — Spatial presets + Device profiles sections.
//
// Device profiles are the answer to "I keep turning this app off when I switch to the TV":
// each output device remembers whether we process it at all, and with which presets.
// Manual changes stay session-scoped until you press "Save to this device" (§5.4).

import SwiftUI
import SpatialEngine

// MARK: - Spatial presets

struct SpatialPresetSection: View {
    @Environment(EngineController.self) private var controller

    @State private var showSaveAs = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var nameField = ""

    var body: some View {
        Section {
            let selected = controller.selectedSpatialPreset
            let builtIn = selected?.isBuiltIn ?? true
            LabeledContent("Preset") {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { controller.selectedSpatialPresetID ?? SpatialPreset.defaultID },
                                                  set: { controller.applySpatialPreset($0) })) {
                        ForEach(controller.spatialPresets) { p in
                            Text(controller.spatialPresetLabel(p)).tag(p.id)
                        }
                    }
                    .labelsHidden()

                    Button("Save") { controller.saveSelectedSpatialPreset() }
                        .disabled(builtIn || !controller.spatialDirty)
                    Button("Save as…") { nameField = suggestedName(selected); showSaveAs = true }
                    Menu {
                        Button("Rename…") { nameField = selected?.name ?? ""; showRename = true }
                            .disabled(builtIn)
                        Button("Delete…", role: .destructive) { showDelete = true }
                            .disabled(builtIn)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).frame(width: 24)
                }
            }
            .alert("Save spatial preset as", isPresented: $showSaveAs) {
                TextField("Name", text: $nameField)
                Button("Cancel", role: .cancel) {}
                Button("Save") { controller.saveSpatialPresetAs(nameField) }
            } message: {
                Text("Soundstage, personalization, rendering and reverb are stored under this name.")
            }
            .alert("Rename preset", isPresented: $showRename) {
                TextField("Name", text: $nameField)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let id = controller.selectedSpatialPresetID { controller.renameSpatialPreset(id, to: nameField) }
                }
            }
            .alert("Delete preset?", isPresented: $showDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let id = controller.selectedSpatialPresetID { controller.deleteSpatialPreset(id) }
                }
            } message: {
                Text("\"\(controller.selectedSpatialPreset?.name ?? "")\" will be removed. Device profiles using it fall back to Default.")
            }
        } header: {
            Text("Spatial presets")
        } footer: {
            Text("A spatial preset stores everything above except the equalizer and the capture mode. Edits show a • until you save them.")
        }
    }

    private func suggestedName(_ s: SpatialPreset?) -> String {
        guard let s, !s.isBuiltIn else { return "My soundstage" }
        return "\(s.name) copy"
    }
}

// MARK: - Device profiles

struct DeviceProfilesSection: View {
    @Environment(EngineController.self) private var controller

    var body: some View {
        Section {
            currentDeviceRow

            ForEach(controller.deviceProfiles) { p in
                profileEditor(p, removable: true)
            }
            profileEditor(controller.fallbackProfile, removable: false)
        } header: {
            Text("Device profiles")
        } footer: {
            Text("When the output device changes, atmos-control applies that device's profile. Bypass means the engine stops entirely, so an AV receiver or TV gets the original multichannel audio untouched.")
        }
    }

    // MARK: Current device

    @ViewBuilder
    private var currentDeviceRow: some View {
        LabeledContent("Current device") {
            HStack(spacing: 8) {
                Text(controller.profiledDeviceName)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if controller.bypassed {
                    Text("Bypassed").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
                if controller.profileDirty {
                    Button("Revert") { controller.revertToDeviceProfile() }
                }
                Button(controller.currentDeviceHasProfile ? "Save to this device" : "Add profile") {
                    controller.saveCurrentToDeviceProfile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.profileDirty && controller.currentDeviceHasProfile)
            }
        }
        if controller.profileDirty {
            Label("Unsaved changes for this device — they apply to this session only.",
                  systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: One profile

    @ViewBuilder
    private func profileEditor(_ profile: DeviceProfile, removable: Bool) -> some View {
        let binding = Binding<DeviceProfile>(
            get: { profile },
            set: { controller.updateProfile($0) })

        DisclosureGroup {
            Picker("Mode", selection: binding.mode) {
                ForEach(DeviceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if profile.mode == .process {
                Toggle("Equalizer", isOn: binding.eqEnabled)
                Picker("EQ preset", selection: Binding(
                    get: { profile.eqPresetID ?? EQPreset.flatID },
                    set: { var p = profile; p.eqPresetID = $0; controller.updateProfile(p) })) {
                    ForEach(controller.eqPresets) { Text($0.name).tag($0.id) }
                }
                Toggle("Spatial audio", isOn: binding.spatialEnabled)
                Picker("Spatial preset", selection: Binding(
                    get: { profile.spatialPresetID ?? SpatialPreset.defaultID },
                    set: { var p = profile; p.spatialPresetID = $0; controller.updateProfile(p) })) {
                    ForEach(controller.spatialPresets) { Text($0.name).tag($0.id) }
                }
            }

            Toggle("Apply automatically", isOn: binding.autoSwitch)
                .help("Off: remember this device's settings, but never change anything when it appears.")

            if removable {
                HStack {
                    Spacer()
                    Button("Remove profile", role: .destructive) { controller.removeProfile(profile.id) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: profile.isFallback ? "questionmark.circle" : "hifispeaker")
                    .foregroundStyle(.secondary)
                Text(profile.isFallback ? "Any other device" : profile.deviceName)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(summary(profile))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ p: DeviceProfile) -> String {
        guard p.autoSwitch else { return "manual" }
        guard p.mode == .process else { return "Bypass" }
        let eq = p.eqEnabled ? (controller.eqPresets.first { $0.id == p.eqPresetID }?.name ?? "Flat") : "EQ off"
        let sp = p.spatialEnabled ? (controller.spatialPresets.first { $0.id == p.spatialPresetID }?.name ?? "Default") : "Spatial off"
        return "\(eq) · \(sp)"
    }
}
