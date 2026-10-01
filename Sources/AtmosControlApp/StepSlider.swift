// AtmosControlApp/StepSlider.swift — a slider you can actually land a value on.
//
// macOS's stock slider jumps the knob to wherever you click, which makes a 0.01-precision
// parameter in a 300 pt track a game of chance. This one keeps dragging continuous but
// turns a *click* into a single step: click right of the knob = +1 step, left = −1 step.
// (Direct "jump to the clicked position" is gone on purpose.)

import SwiftUI

struct StepSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Called on every change (drag or click step).
    let onChange: (Double) -> Void
    /// Called once when an interaction finishes — for rebuild-class parameters that
    /// shouldn't restart the graph on every intermediate value.
    var onCommit: (() -> Void)? = nil

    @State private var dragging = false

    private let trackHeight: CGFloat = 4
    private let knobSize: CGFloat = 15

    private var span: Double { max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let usable = max(w - knobSize, 1)
            let frac = CGFloat((clamp(value) - range.lowerBound) / span)
            let x = knobSize / 2 + usable * frac

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(x, trackHeight), height: trackHeight)
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.5)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: x - knobSize / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // A click is a drag that never really moved.
                        if !dragging && abs(g.translation.width) > 2.5 { dragging = true }
                        if dragging { set(fromX: g.location.x, usable: usable) }
                    }
                    .onEnded { g in
                        if dragging {
                            set(fromX: g.location.x, usable: usable)
                            dragging = false
                        } else {
                            bump(g.location.x >= x ? 1 : -1)
                        }
                        onCommit?()
                    }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityValue(Text("\(value)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: bump(1)
            case .decrement: bump(-1)
            @unknown default: break
            }
            onCommit?()
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    /// Snap to the step grid, anchored at the range's lower bound so the endpoints are
    /// always reachable exactly.
    private func snap(_ v: Double) -> Double {
        guard step > 0 else { return clamp(v) }
        let n = ((v - range.lowerBound) / step).rounded()
        return clamp(range.lowerBound + n * step)
    }

    private func set(fromX x: CGFloat, usable: CGFloat) {
        let t = Double(min(max((x - knobSize / 2) / usable, 0), 1))
        let v = snap(range.lowerBound + t * span)
        if v != value { onChange(v) }
    }

    private func bump(_ direction: Double) {
        let v = snap(snap(value) + direction * step)
        if v != value { onChange(v) }
    }
}
