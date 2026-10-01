import ActivityKit
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
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let phase = JuniorActivityPhase(raw: context.state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DotCatView(color: phase.color, eyesClosed: phase.eyesClosed)
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
                    if !context.state.detail.isEmpty {
                        Text(context.state.detail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                }
            } compactLeading: {
                DotCatView(color: phase.color, eyesClosed: phase.eyesClosed)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                Text(phase.badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phase.color)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            } minimal: {
                DotCatView(color: phase.color, eyesClosed: phase.eyesClosed)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(phase.color)
        }
    }
}

private struct LockScreenView: View {
    let state: JuniorActivityAttributes.ContentState

    var body: some View {
        let phase = JuniorActivityPhase(raw: state.phase)
        HStack(spacing: 14) {
            DotCatView(color: phase.color, eyesClosed: phase.eyesClosed)
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
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
