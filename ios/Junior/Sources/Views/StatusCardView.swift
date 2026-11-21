import SwiftUI

/// Durum kartının verisi: sunucudan 15 sn'de bir okunur (yalnız kart ekrandayken).
@MainActor
final class PcStatusModel: ObservableObject {
    @Published private(set) var status: PcStatus?
    @Published private(set) var fetchedAt = Date()
    /// Son okuma başarısız: eldeki değer eski olabilir.
    @Published private(set) var failed = false

    private let config: Config
    private let client = JuniorClient()
    static let interval: TimeInterval = 15

    init(config: Config) {
        self.config = config
    }

    func refresh() async {
        guard let token = config.token, !token.isEmpty, let url = config.url(path: "/v1/status/pc") else { return }
        do {
            let data = try await client.json(method: "GET", url: url, token: token, timeout: 10)
            guard let parsed = PcStatus.parse(data) else {
                failed = true
                return
            }
            status = parsed
            fetchedAt = Date()
            failed = false
        } catch {
            failed = true
        }
    }

    /// Kart ekrandayken döngü; görünüm kaybolunca görev iptal olur.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
        }
    }
}

/// Ana ekrandaki "Durum" kartı: açık görev/rutin, son rapor, bilgisayarın CPU/RAM/GPU/sıcaklığı ve ulaşılabilirlik.
struct StatusCardView: View {
    @ObservedObject var model: PcStatusModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            card(now: context.date)
        }
        .task { await model.run() }
    }

    @ViewBuilder
    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = model.status {
                let reach = StatusFormat.reachability(status, now: now, fetchedAt: model.fetchedAt)
                HStack(spacing: 8) {
                    Circle().fill(reach.ok ? JuniorTheme.green : JuniorTheme.orange).frame(width: 8, height: 8)
                    Text(reach.text).font(.subheadline.weight(.semibold))
                    Spacer()
                }
                HStack(spacing: 10) {
                    counter("\(status.tasksOpen)", "açık görev", "checklist", JuniorTheme.green)
                    counter("\(status.routinesOpen)", "açık rutin", "alarm.fill", JuniorTheme.violet)
                }
                if reach.ok {
                    HStack(spacing: 10) {
                        meter("İşlemci", StatusFormat.percent(status.cpu), StatusFormat.load(status.cpu))
                        meter("Bellek", StatusFormat.percent(status.ramPercent), StatusFormat.load(status.ramPercent))
                        meter("Sıcaklık", StatusFormat.temperature(status.temp), StatusFormat.heat(status.temp))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "display").font(.caption).foregroundStyle(.secondary)
                        Text(StatusFormat.gpuLine(status.gpu)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let report = status.report {
                    Divider().overlay(JuniorTheme.stroke)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Son rapor").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(StatusFormat.reportTime(report.finished, now: now)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(report.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if !report.summary.isEmpty {
                            Text(report.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                if model.failed {
                    Text("Sunucuya ulaşılamıyor; gösterilen bilgi eski olabilir.")
                        .font(.caption2).foregroundStyle(JuniorTheme.orange)
                }
            } else {
                HStack(spacing: 8) {
                    if model.failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JuniorTheme.orange)
                        Text("Durum okunamadı").font(.subheadline)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Durum okunuyor…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 18)
        .accessibilityElement(children: .combine)
    }

    private func counter(_ value: String, _ label: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(JuniorTheme.rounded(.title3, .bold))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func meter(_ label: String, _ value: String, _ level: StatusFormat.Level) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(color(level))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ level: StatusFormat.Level) -> Color {
        switch level {
        case .normal: return .primary
        case .warm: return JuniorTheme.orange
        case .hot: return JuniorTheme.red
        case .unknown: return .secondary
        }
    }
}
