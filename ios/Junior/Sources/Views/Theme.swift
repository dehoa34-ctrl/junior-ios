import SwiftUI

/// Junior'ın görünümü: koyu zemin, durum rengine göre ışıyan noktalı kedi.
/// Renkler Dynamic Island ve masaüstü adasındaki durum renkleriyle aynı aileden.
enum JuniorTheme {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.063)
    static let surface = Color.white.opacity(0.06)
    static let surfaceStrong = Color.white.opacity(0.11)
    static let stroke = Color.white.opacity(0.08)
    static let cyan = Color(red: 0.36, green: 0.84, blue: 1.0)
    static let blue = Color(red: 0.25, green: 0.52, blue: 1.0)
    static let violet = Color(red: 0.55, green: 0.45, blue: 0.98)
    static let green = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.26)
    static let red = Color(red: 0.96, green: 0.31, blue: 0.37)

    static let userBubble = LinearGradient(colors: [Color(red: 0.20, green: 0.55, blue: 1.0), violet],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
    static let micGradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func rounded(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

/// Ekranın arkası: üstten durum rengiyle hafifçe aydınlanan koyu zemin.
struct AmbientBackground: View {
    var tint: Color

    var body: some View {
        ZStack {
            JuniorTheme.background
            RadialGradient(colors: [tint.opacity(0.24), .clear], center: .top, startRadius: 0, endRadius: 460)
            RadialGradient(colors: [JuniorTheme.violet.opacity(0.10), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: tint)
    }
}

/// Noktalı kedi; ara sıra göz kırpar. Beklerken gözleri kapalı (uykulu).
struct JuniorCat: View {
    var phase: JuniorActivityPhase
    var size: CGFloat
    var glow = false
    @State private var blink = false

    var body: some View {
        DotCatView(color: phase.color, eyesClosed: phase.eyesClosed || blink)
            .frame(width: size, height: size)
            .shadow(color: glow ? phase.color.opacity(0.55) : .clear, radius: size * 0.18)
            .animation(.easeInOut(duration: 0.4), value: phase)
            .task(id: phase) {
                // Uyanıkken 3-6 saniyede bir kısa kırpış.
                guard !phase.eyesClosed else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 3_000_000_000...6_000_000_000))
                    blink = true
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    blink = false
                }
            }
    }
}

/// Kediyi yuvarlak bir rozetin içinde gösterir (başlık, yanıt balonu).
struct CatBadge: View {
    var phase: JuniorActivityPhase
    var size: CGFloat = 40

    var body: some View {
        JuniorCat(phase: phase, size: size * 0.78)
            .frame(width: size, height: size)
            .background(Circle().fill(phase.color.opacity(0.14)))
            .overlay(Circle().stroke(phase.color.opacity(0.35), lineWidth: 1))
    }
}

/// Dinlerken ve konuşurken oynayan ses çubukları. Mikrofon seviyesine
/// bağlı değil; yalnız "şu an ses alınıyor" duygusunu verir.
struct WaveBars: View {
    var active: Bool
    var color: Color = JuniorTheme.cyan
    var count = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: active ? 5 + 13 * abs(sin(t * 5.2 + Double(index) * 0.9)) : 5)
                }
            }
            .frame(height: 20)
        }
        .accessibilityHidden(true)
    }
}

/// Basınca hafifçe küçülen düğme.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Başlıktaki yuvarlak simge düğmesi.
struct CircleIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(JuniorTheme.surface, in: Circle())
                .overlay(Circle().stroke(JuniorTheme.stroke))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// Kart zemini: hafif saydam yüzey ve ince kenar.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 20
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background((tint ?? .white).opacity(tint == nil ? 0.06 : 0.12),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke((tint ?? .white).opacity(tint == nil ? 0.08 : 0.30), lineWidth: 1))
    }
}

extension View {
    func card(radius: CGFloat = 20, tint: Color? = nil) -> some View {
        modifier(CardBackground(radius: radius, tint: tint))
    }
}

/// Ayarlar satırlarının solundaki renkli kare simge (iOS Ayarlar'daki gibi).
struct SettingIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
