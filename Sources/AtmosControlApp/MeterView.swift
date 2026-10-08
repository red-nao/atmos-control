// MeterView — twin post-render output peak meters with peak-hold and a dBFS scale.

import SwiftUI

struct MeterView: View {
    @Environment(EngineController.self) private var controller

    private let floorDb: Float = -60

    var body: some View {
        // Read the tracked values in the body's observation scope (NOT inside the Canvas
        // closure) so a meter-rate change re-runs only this body, not PanelView's.
        let levelL = controller.meterL, levelR = controller.meterR
        let holdL = controller.peakHoldL, holdR = controller.peakHoldR
        return Canvas { ctx, size in
            let top: CGFloat = 8, bot = size.height - 14, H = bot - top
            let scaleW: CGFloat = 24
            let barW: CGFloat = 13, gap: CGFloat = 6
            let x0 = scaleW + 6
            let grid = Color.secondary

            func y(_ db: Float) -> CGFloat { bot - CGFloat((max(floorDb, min(0, db)) - floorDb) / -floorDb) * H }
            func yLin(_ x: Float) -> CGFloat { y(x > 0 ? 20 * log10(x) : floorDb) }

            // scale ticks + labels
            for db in [Float(0), -6, -12, -24, -48, -60] {
                let yy = y(db)
                var t = Path(); t.move(to: CGPoint(x: scaleW - 4, y: yy)); t.addLine(to: CGPoint(x: scaleW, y: yy))
                ctx.stroke(t, with: .color(grid.opacity(0.5)), lineWidth: 1)
                let label = Text(db == 0 ? "0" : "\(Int(db))")
                    .font(.system(size: 8, design: .monospaced)).foregroundColor(grid)
                ctx.draw(label, at: CGPoint(x: scaleW - 6, y: yy), anchor: .trailing)
            }

            // bars
            for (i, lvl, hold, ch) in [(0, levelL, holdL, "L"), (1, levelR, holdR, "R")] as [(Int, Float, Float, String)] {
                let bx = x0 + CGFloat(i) * (barW + gap)
                let frame = CGRect(x: bx, y: top, width: barW, height: H)
                ctx.stroke(Path(roundedRect: frame, cornerRadius: 2), with: .color(grid.opacity(0.4)), lineWidth: 1)

                let lvlY = yLin(lvl)
                // zoned fill: instrument < -6, orange -6…-1, red ≥ -1
                func seg(_ fromDb: Float, _ toDb: Float, _ color: Color) {
                    let yTop = max(lvlY, y(toDb)), yBot = y(fromDb)
                    if yBot > yTop {
                        ctx.fill(Path(CGRect(x: bx + 1, y: yTop, width: barW - 2, height: yBot - yTop)), with: .color(color))
                    }
                }
                seg(floorDb, -6, .instrument)
                seg(-6, -1, .orange)
                seg(-1, 0, .red)

                // peak-hold marker
                if hold > 0 {
                    let hy = yLin(hold)
                    let hcol: Color = hold > 0.89 ? .red : (hold > 0.5 ? .orange : .instrument)
                    ctx.fill(Path(CGRect(x: bx + 1, y: hy - 1, width: barW - 2, height: 1.6)), with: .color(hcol))
                }

                ctx.draw(Text(ch).font(.system(size: 9, design: .monospaced)).foregroundColor(grid),
                         at: CGPoint(x: bx + barW / 2, y: bot + 7), anchor: .center)
            }
        }
        .accessibilityLabel("Post-processing output levels")
    }
}
