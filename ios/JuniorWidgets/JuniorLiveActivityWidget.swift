import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct JuniorWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JuniorLiveActivityWidget()
    }
}

/// Junior'ın Dynamic Island ve kilit ekranı görünümü.
///
/// Masaüstündeki dinamik adanın telefondaki karşılığı: Junior dinlerken,
/// gözlükten bakarken, düşünürken ve konuşurken noktalı kedi renk değiştirir;
/// açılmış adada son soru/yanıt görünür.
struct JuniorLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JuniorActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            // Onayın süresi dolduysa (etkinlik eskidi) düğmeler ve "Onay bekliyor" gösterilmez.
            let phase = JuniorConfirmDisplay.phase(raw: context.state.phase, isStale: context.isStale)
            let confirmID = JuniorConfirmDisplay.buttonsID(confirmID: context.state.confirmID, isStale: context.isStale)
            // Uygulamadaki kediyle aynı ifade (mutlu, üzgün, konuşuyor …).
            let expression = JuniorConfirmDisplay.expression(raw: context.state.expression, phase: phase,
                                                             isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DotCatView(color: phase.color, eyesClosed: expression.eyesClosed, expression: expression)
                        .frame(width: 46, height: 46)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: phase.symbol)
                        .font(.title3)
                        .foregroundStyle(phase.color)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        if context.state.glasses {
                            Label("Gözlük", systemImage: "eyeglasses")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if !context.state.detail.isEmpty {
                            Text(context.state.detail)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let confirmID {
                            ConfirmButtons(confirmID: confirmID)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                DotCatView(color: phase.color, eyesClosed: expression.eyesClosed, expression: expression)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                Text(phase.badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phase.color)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            } minimal: {
                DotCatView(color: phase.color, eyesClosed: expression.eyesClosed, expression: expression)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(phase.color)
        }
    }
}

private struct LockScreenView: View {
    let state: JuniorActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let phase = JuniorConfirmDisplay.phase(raw: state.phase, isStale: isStale)
        let confirmID = JuniorConfirmDisplay.buttonsID(confirmID: state.confirmID, isStale: isStale)
        let expression = JuniorConfirmDisplay.expression(raw: state.expression, phase: phase, isStale: isStale)
        HStack(spacing: 14) {
            DotCatView(color: phase.color, eyesClosed: expression.eyesClosed, expression: expression)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: phase.symbol)
                        .foregroundStyle(phase.color)
                    Text(phase.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
                if let confirmID {
                    ConfirmButtons(confirmID: confirmID)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// Bilgisayardaki Junior'ın onay isteği: Reddet hemen gider, Onayla uygulamayı açar
/// (kilitliyse iOS önce kilit açmayı ister).
private struct ConfirmButtons: View {
    let confirmID: String

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: JuniorDenyConfirmIntent(confirmID: confirmID)) {
                Label("Reddet", systemImage: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            Button(intent: JuniorApproveConfirmIntent(confirmID: confirmID)) {
                Label("Onayla", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(red: 0.20, green: 0.83, blue: 0.60)))
            }
            .buttonStyle(.plain)
        }
    }
}
