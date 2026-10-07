// AtmosControlApp/UpmixView.swift — the Upmix section of Full Control.
//
// Everything here except ON/OFF, Target layout and FFT size is live; those three change
// the shape of the graph, so they rebuild it (a ~200 ms gap, §4.7). The kernel picker is
// live as well: both kernels share one analysis engine, so Classic ↔ Natural is an
// instant A/B — the fastest way to hear what the quality pass actually did.

import SwiftUI
import SpatialEngine

struct UpmixSection: View {
    @Environment(EngineController.self) private var controller

    private var up: UpmixConfig { controller.config.upmix }

    var body: some View {
        Section {
            Toggle("Upmix stereo to surround", isOn: Binding(get: { up.enabled },
                                                             set: { controller.setUpmixEnabled($0) }))
                .disabled(!controller.upmixAvailable)

            if !controller.upmixAvailable {
                Label(controller.captureChoice == .surround
                      ? "The 7.1.4 capture is already multichannel — nothing to upmix."
                      : "Upmix needs spatial audio switched on.",
                      systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Group {
                Picker("Target layout", selection: Binding(get: { up.layout },
                                                           set: { controller.setUpmixLayout($0) })) {
                    ForEach(UpmixLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                // The master control, Auro-Matic style: 0 = the stereo signal passes
                // through untouched, 1 = the full effect.
                liveSlider("Strength", Param.upStrength, value: up.strength) {
                    controller.setUpmix(strength: $0)
                }

                liveSlider("Center strength", Param.upCenter, value: up.centerStrength) {
                    controller.setUpmix(center: $0)
                }
                liveSlider("Surround level", Param.upSurround, value: up.surroundLevel) {
                    controller.setUpmix(surroundLevel: $0)
                }
                if up.layout == .surround714 {
                    liveSlider("Height level", Param.upHeight, value: up.heightLevel) {
                        controller.setUpmix(heightLevel: $0)
                    }
                }
                liveSlider("Ambience spread", Param.upAmbienceSpread, value: up.spread) {
                    controller.setUpmix(spread: $0)
                }
                liveSlider("Decorrelation", Param.upDecorr, value: up.decorrelation) {
                    controller.setUpmix(decorrelation: $0)
                }
                liveSlider("Ambient bias", Param.upAmbient, value: up.ambientBias) {
                    controller.setUpmix(ambientBias: $0)
                }
                liveSlider("Surround spread", Param.upSpread, value: up.surroundSpread) {
                    controller.setUpmix(surroundSpread: $0)
                }

                Picker("LFE", selection: Binding(get: { up.lfeMode },
                                                 set: { controller.setUpmix(lfe: $0) })) {
                    ForEach(LFEMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Kernel", selection: Binding(get: { up.quality },
                                                            set: { controller.setUpmix(quality: $0) })) {
                            ForEach(UpmixQuality.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(up.quality.blurb)
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    liveSlider("Transient preservation", Param.upTransient, value: up.transients) {
                        controller.setUpmix(transients: $0)
                    }
                    liveSlider("Reflections", Param.upReflections, value: up.reflectionsLevel) {
                        controller.setUpmix(reflectionsLevel: $0)
                    }
                    Toggle("Bass management on the sends", isOn: Binding(get: { up.bassManagement },
                                                                        set: { controller.setUpmix(bassManagement: $0) }))
                    Toggle("Auto level", isOn: Binding(get: { up.autoLevel },
                                                       set: { controller.setUpmix(autoLevel: $0) }))

                    Picker("FFT size", selection: Binding(get: { up.fftSize },
                                                          set: { controller.setUpmixFFTSize($0) })) {
                        Text("1024").tag(1024)
                        Text("2048").tag(2048)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Added latency") {
                        Text(String(format: "%.0f ms", controller.upmixLatencyMS))
                            .font(.system(.callout, design: .monospaced)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button("Reset upmix") { controller.resetUpmix() }
                }

                if controller.config.headTracking {
                    Label("Head tracking follows about \(Int(controller.upmixLatencyMS)) ms later while upmixing.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(!up.enabled || !controller.upmixAvailable)
            .opacity(up.enabled && controller.upmixAvailable ? 1 : 0.45)
        } header: {
            Text("Upmix")
        } footer: {
            SectionFootnote("Splits the stereo signal into direct sound and ambience with a short-time Fourier transform, then places them on \(up.layout == .surround714 ? "twelve" : "six") virtual speakers before binaural rendering. Natural keeps the direct path untouched, bass-manages the sends and synthesises the height layer from delayed reflections; Classic is the original kernel. Turning it on or off rebuilds the audio graph, so expect a brief gap.")
        }
    }

    /// Same idiom as SettingsView's live sliders: monospaced readout, double-click resets.
    @ViewBuilder
    private func liveSlider(_ label: String, _ spec: ParamSpec, value: Float,
                            live: @escaping (Float) -> Void) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                StepSlider(value: Double(value), range: spec.range, step: spec.step) { live(Float($0)) }
                Text(spec.text(value))
                    .font(.system(.callout, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { live(Float(spec.def)) }
                    .help("Double-click to reset to default (\(spec.text(spec.def)))")
            }
        }
    }
}
