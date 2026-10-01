// AtmosControlApp/EQView.swift — the 10-band equalizer section of Full Control.
//
// SwiftUI has no vertical Slider on macOS, and rotating a horizontal one misbehaves
// inside a grouped Form (hit-testing and layout both fight the rotation), so the faders
// are drawn by hand. Everything here is live: no graph rebuilds, no audio dropout.

import SwiftUI
import SpatialEngine

// MARK: - Section

struct EqualizerSection: View {
    @Environment(EngineController.self) private var controller

    @State private var showSaveAs = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var nameField = ""

    private var eq: EQConfig { controller.config.eq }

    var body: some View {
        Section {
            Toggle("Equalizer", isOn: Binding(get: { eq.enabled },
                                              set: { controller.setEQEnabled($0) }))

            presetBar

            EQCurveView(gains: eq.normalizedGains,
                        preamp: controller.eqPreampDB,
                        sampleRate: 48_000,
                        active: eq.enabled)
                .frame(height: 96)
                .padding(.vertical, 2)

            HStack(alignment: .top, spacing: 6) {
                ForEach(0..<EQConfig.bandCount, id: \.self) { i in
                    VerticalGainSlider(
                        value: eq.normalizedGains[i],
                        limit: EQConfig.gainLimit,
                        caption: Self.freqLabel(EQConfig.frequencies[i]),
                        onChange: { controller.setEQGain(band: i, $0) },
                        onReset:  { controller.setEQGain(band: i, 0) })
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 168)
            .opacity(eq.enabled ? 1 : 0.45)
            .disabled(!eq.enabled)
            .padding(.vertical, 2)

            preampRow

            HStack {
                Button("Flatten") { controller.resetEQ() }
                    .disabled(eq.isFlat)
                Spacer()
                Text(peakReadout)
                    .font(.system(.footnote, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Equalizer")
        } footer: {
            Text("Ten fixed bands (1 octave wide, ±\(Int(EQConfig.gainLimit)) dB) applied to the stereo signal before spatialization. Drag a fader, or double-click it to zero that band.")
        }
    }

    // MARK: Preset bar

    @ViewBuilder
    private var presetBar: some View {
        let selected = controller.selectedEQPreset
        let builtIn = selected?.isBuiltIn ?? true
        LabeledContent("Preset") {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { controller.selectedEQPresetID ?? EQPreset.flatID },
                                              set: { controller.applyEQPreset($0) })) {
                    ForEach(controller.eqPresets) { p in
                        Text(controller.eqPresetLabel(p)).tag(p.id)
                    }
                }
                .labelsHidden()

                Button("Save") { controller.saveSelectedEQPreset() }
                    .disabled(builtIn || !controller.eqDirty)
                    .help(builtIn ? "Flat is built in — use Save as… to keep your changes"
                                  : "Overwrite this preset with the current curve")
                Button("Save as…") { nameField = suggestedName(); showSaveAs = true }
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
        .disabled(!eq.enabled)
        .opacity(eq.enabled ? 1 : 0.45)
        .alert("Save preset as", isPresented: $showSaveAs) {
            TextField("Name", text: $nameField)
            Button("Cancel", role: .cancel) {}
            Button("Save") { controller.saveEQPresetAs(nameField) }
        } message: {
            Text("The current curve and pre-amp are stored under this name.")
        }
        .alert("Rename preset", isPresented: $showRename) {
            TextField("Name", text: $nameField)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = controller.selectedEQPresetID { controller.renameEQPreset(id, to: nameField) }
            }
        }
        .alert("Delete preset?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = controller.selectedEQPresetID { controller.deleteEQPreset(id) }
            }
        } message: {
            Text("\"\(controller.selectedEQPreset?.name ?? "")\" will be removed. This cannot be undone.")
        }
    }

    /// "Rock" → "Rock copy" when saving a modified built-in/selected preset.
    private func suggestedName() -> String {
        guard let s = controller.selectedEQPreset, !s.isBuiltIn else { return "My preset" }
        return "\(s.name) copy"
    }

    // MARK: Pre-amp

    @ViewBuilder
    private var preampRow: some View {
        let manual = eq.preampMode == .manual
        // Two lines rather than one LabeledContent row: the slider then gets the full
        // width of the section instead of fighting the label column and the mode picker.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Pre-amp")
                Picker("", selection: Binding(get: { eq.preampMode },
                                              set: { controller.setPreampMode($0) })) {
                    ForEach(PreampMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 124)
                Spacer()
                Text(String(format: "%+.1f dB", controller.eqPreampDB))
                    .font(.system(.callout, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if manual { controller.setManualPreamp(0) } }
                    .help(manual ? "Double-click to reset to 0 dB"
                                 : "Set automatically so the loudest point of the curve stays at 0 dB")
            }
            StepSlider(value: Double(manual ? eq.manualPreamp : controller.eqPreampDB),
                       range: Double(-EQConfig.preampLimit)...Double(EQConfig.gainLimit),
                       step: 0.5) { controller.setManualPreamp(Float($0)) }
                .disabled(!manual)
                .opacity(manual ? 1 : 0.5)
                .help(manual ? "Drag, or click either side of the knob to nudge by 0.5 dB"
                             : "Switch to Manual to set the pre-amp yourself")
        }
        .disabled(!eq.enabled)
        .opacity(eq.enabled ? 1 : 0.45)
    }

    private var peakReadout: String {
        let peak = controller.eqPeakDB
        return peak <= 0.05 ? "curve peak 0.0 dB"
                            : String(format: "curve peak +%.1f dB", peak)
    }

    static func freqLabel(_ f: Float) -> String {
        f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }
}

// MARK: - Vertical fader

struct VerticalGainSlider: View {
    let value: Float
    let limit: Float
    let caption: String
    let onChange: (Float) -> Void
    let onReset: () -> Void

    private let trackWidth: CGFloat = 5
    private let knobHeight: CGFloat = 10

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%+.1f", value))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(abs(value) < 0.05 ? .secondary : .primary)

            GeometryReader { geo in
                let h = geo.size.height
                let usable = max(h - knobHeight, 1)
                let frac = CGFloat((limit - value) / (2 * limit))       // 0 = top (+limit)
                let y = knobHeight / 2 + usable * frac
                let mid = h / 2

                ZStack(alignment: .top) {
                    // Track
                    Capsule().fill(Color.primary.opacity(0.10))
                        .frame(width: trackWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 0 dB reference
                    Rectangle().fill(Color.primary.opacity(0.22))
                        .frame(height: 1)
                        .offset(y: mid - 0.5)
                    // Fill from centre to the knob
                    Capsule().fill(Color.accentColor.opacity(0.85))
                        .frame(width: trackWidth, height: max(abs(y - mid), 1))
                        .offset(y: min(y, mid))
                        .frame(maxWidth: .infinity, alignment: .center)
                    // Knob
                    RoundedRectangle(cornerRadius: knobHeight / 2)
                        .fill(Color(nsColor: .controlColor))
                        .overlay(RoundedRectangle(cornerRadius: knobHeight / 2)
                            .strokeBorder(Color.primary.opacity(0.28), lineWidth: 0.8))
                        .shadow(radius: 0.5, y: 0.5)
                        .frame(width: 20, height: knobHeight)
                        .offset(y: y - knobHeight / 2)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = (g.location.y - knobHeight / 2) / usable
                            var v = limit - Float(min(max(f, 0), 1)) * 2 * limit
                            v = (v / 0.5).rounded() * 0.5                 // 0.5 dB detents
                            if abs(v) < 0.6 { v = 0 }                     // snap to flat
                            onChange(v)
                        }
                )
                .onTapGesture(count: 2) { onReset() }
            }

            Text(caption)
                .font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("\(caption) Hz — double-click to reset")
    }
}

// MARK: - Response curve

struct EQCurveView: View {
    let gains: [Float]
    let preamp: Float
    let sampleRate: Double
    let active: Bool

    private let fLo = 20.0, fHi = 20_000.0
    private let dbSpan: Float = 15            // ±15 dB vertical window

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func y(_ db: Float) -> CGFloat {
                CGFloat(0.5 - Double(min(max(db, -dbSpan), dbSpan)) / Double(2 * dbSpan)) * h
            }

            // Grid: octave marks + 0 dB
            var grid = Path()
            for f in EQConfig.frequencies {
                let x = CGFloat(log(Double(f) / fLo) / log(fHi / fLo)) * w
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: h))
            }
            ctx.stroke(grid, with: .color(.primary.opacity(0.07)), lineWidth: 1)

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: w, y: y(0)))
            ctx.stroke(zero, with: .color(.primary.opacity(0.22)), lineWidth: 1)

            // The curve, with the pre-amp folded in — this is what actually comes out.
            let steps = 160
            var curve = Path()
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let f = Float(fLo * pow(fHi / fLo, t))
                let db = EQConfig.responseDB(gains: gains, sampleRate: sampleRate, frequency: f) + preamp
                let p = CGPoint(x: CGFloat(t) * w, y: y(db))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }
            var fill = curve
            fill.addLine(to: CGPoint(x: w, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(.accentColor.opacity(active ? 0.14 : 0.06)))
            ctx.stroke(curve, with: .color(active ? .accentColor : .secondary),
                       style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
        .overlay(alignment: .topTrailing) {
            Text("±\(Int(dbSpan)) dB")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary).padding(4)
        }
        .opacity(active ? 1 : 0.5)
        .accessibilityHidden(true)
    }
}
