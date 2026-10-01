import SwiftUI

/// Noktalardan oluşan kedi yüzü. Dynamic Island ve kilit ekranında kullanılır.
/// Boyut küçüldükçe ızgara seyrekleşir ki noktalar birbirine yapışıp lekeye dönmesin.
struct DotCatView: View {
    var color: Color
    var eyesClosed: Bool = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }
            // Küçük boyutta (Dynamic Island kompakt ~20 pt) 9 nokta, büyükte 15 nokta genişlik.
            let columns = side < 28 ? 9 : side < 48 ? 12 : 15
            let step = 2.0 / Double(columns - 1)
            let originX = (size.width - side) / 2
            let originY = (size.height - side) / 2
            let baseRadius = side / Double(columns) * 0.36
            for row in 0..<columns {
                for col in 0..<columns {
                    let gx = -1.0 + Double(col) * step
                    let gy = -1.0 + Double(row) * step
                    let w = JuniorDots.weight(x: gx, y: gy + 0.08, eyesClosed: eyesClosed)
                    guard w > 0 else { continue }
                    let cx = originX + (gx + 1) / 2 * side
                    let cy = originY + (gy + 1) / 2 * side
                    let r = baseRadius * (w > 1 ? 1.2 : 1)
                    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(min(1, w))))
                }
            }
        }
        .accessibilityLabel("Junior")
    }
}

extension JuniorActivityPhase {
    var color: Color {
        let c = rgb
        return Color(red: c.0, green: c.1, blue: c.2)
    }
}
