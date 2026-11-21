import SwiftUI
import UIKit

/// Sohbet ekranının mikrofon düğmesi: kısa dokunuş tıkla-konuş, basılı tutma bas-konuş.
///
/// Durum `PushToTalk` makinesindedir; bu görünüm yalnız dokunuş olaylarını verir ve dönen
/// eylemi `onAction` ile iletir (RootView eller serbest döngüsüne bağlar).
struct PushToTalkButton: View {
    var listening: Bool
    var speaking: Bool
    var enabled: Bool
    var onAction: (PushToTalk.Action) -> Void

    @State private var machine = PushToTalk()
    @State private var touching = false
    @State private var holdTask: Task<Void, Never>?
    @State private var pulse = false

    private var active: Bool { listening || machine.isHolding }

    var body: some View {
        ZStack {
            if active {
                ForEach(0..<2, id: \.self) { ring in
                    Circle()
                        .stroke(ringColor.opacity(0.55), lineWidth: 2)
                        .scaleEffect(pulse ? 1.7 : 1)
                        .opacity(pulse ? 0 : 0.9)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)
                            .delay(Double(ring) * 0.7), value: pulse)
                }
            }
            Circle()
                .fill(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(JuniorTheme.micGradient))
                .shadow(color: JuniorTheme.cyan.opacity(active ? 0.7 : 0.35), radius: active ? 18 : 10)
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(active ? (machine.phase == .cancelArmed ? JuniorTheme.red : Color.black) : Color.white)
        }
        .frame(width: 52, height: 52)
        .scaleEffect(touching ? (machine.isHolding ? 1.12 : 0.92) : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: touching)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: machine.phase)
        .overlay(alignment: .top) {
            if machine.isHolding {
                Text(machine.phase == .cancelArmed ? "Bırakırsan iptal" : "Bırak: gönder · ↑ iptal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(machine.phase == .cancelArmed ? JuniorTheme.red : .primary)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(y: -44)
                    .transition(.opacity)
            }
        }
        .contentShape(Circle())
        .gesture(press)
        .allowsHitTesting(enabled)
        .onAppear { pulse = active }
        .onChange(of: active) { pulse = active }
        // Basılıyken düğme kapanırsa (istek başladı) dokunuş bitiş olayı gelmeyebilir.
        .onChange(of: enabled) {
            guard !enabled, touching else { return }
            holdTask?.cancel()
            holdTask = nil
            touching = false
            emit(machine.interrupt())
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(listening ? "Dinlemeyi durdur" : "Konuş")
        .accessibilityHint("Dokun: dinlemeyi aç ya da kapat. Basılı tut: konuş, bırakınca gönderilir.")
        .accessibilityAction { onAction(speaking ? .silence : .tap) }
    }

    private var icon: String {
        if machine.phase == .cancelArmed { return "xmark" }
        if machine.isHolding { return "waveform" }
        if speaking { return "speaker.slash.fill" }
        return listening ? "stop.fill" : "mic.fill"
    }

    private var ringColor: Color {
        machine.phase == .cancelArmed ? JuniorTheme.red : JuniorTheme.cyan
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard enabled else { return }
                if !touching {
                    touching = true
                    emit(machine.press(speaking: speaking))
                    holdTask?.cancel()
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(PushToTalk.holdThreshold * 1_000_000_000))
                        guard !Task.isCancelled, touching else { return }
                        emit(machine.holdElapsed())
                    }
                } else {
                    emit(machine.move(dy: Double(value.translation.height)))
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                guard touching else { return }
                touching = false
                emit(machine.release())
            }
    }

    private func emit(_ action: PushToTalk.Action) {
        guard action != .none else { return }
        if action == .startRecording || action == .cancel {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        onAction(action)
    }
}
