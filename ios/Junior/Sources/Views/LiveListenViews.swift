import SwiftUI

/// Durum rengi: kayıtta kırmızı, duraklatılmışta turuncu, kesintide sarımsı.
private extension LiveListenService.State {
    var color: Color {
        switch self {
        case .recording: return JuniorTheme.red
        case .paused: return JuniorTheme.orange
        case .interrupted, .needsPermission: return JuniorTheme.orange
        case .off: return Color.gray
        }
    }
}

/// Ana ekranın başlığındaki küçük gösterge: kayıt sürüyor mu, kaç konuşma bekliyor.
/// Dokununca duraklatır/devam ettirir.
struct LiveIndicator: View {
    @ObservedObject var live: LiveListenService
    @State private var pulse = false

    var body: some View {
        if live.state != .off {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                live.togglePause()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(live.state.color)
                        .frame(width: 8, height: 8)
                        .opacity(live.state == .recording && pulse ? 0.35 : 1)
                    if live.queueCount > 0 {
                        Text("\(live.queueCount)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: live.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(JuniorTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(JuniorTheme.stroke))
            }
            .buttonStyle(PressScale())
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityLabel("Sürekli dinleme: \(live.statusTitle). \(live.queueSummary).")
            .accessibilityHint(live.state == .paused ? "Devam ettirmek için dokun" : "Duraklatmak için dokun")
        }
    }
}

/// Ayarlar'daki "Sürekli dinleme" bölümü.
struct LiveSettingsSection: View {
    @ObservedObject var config: Config
    @ObservedObject var live: LiveListenService

    var body: some View {
        Section {
            Toggle(isOn: $config.phoneLiveEnabled) {
                Label { Text("Telefonda sürekli dinle") } icon: {
                    SettingIcon(systemName: "waveform.circle.fill", color: JuniorTheme.red)
                }
            }
            .id("liveSection")
            if config.phoneLiveEnabled {
                LabeledContent("Durum") {
                    HStack(spacing: 6) {
                        Circle().fill(live.state.color).frame(width: 8, height: 8)
                        Text(live.statusTitle)
                    }
                }
                if let detail = live.statusDetail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("Bekleyen", value: live.queueSummary)
                LabeledContent("Son yükleme", value: live.lastUploadSummary)
                if live.uploadedCount > 0 {
                    LabeledContent("Bu oturumda yüklenen", value: "\(live.uploadedCount)")
                }
                if live.serverReachable == false, live.queueCount > 0 {
                    Label("Bilgisayara ulaşılamıyor; konuşmalar telefonda bekliyor.", systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(JuniorTheme.orange)
                }
                Button {
                    live.togglePause()
                } label: {
                    Label(live.state == .paused ? "Dinlemeye devam et" : "Duraklat",
                          systemImage: live.state == .paused ? "play.fill" : "pause.fill")
                }
                if let warning = live.warning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JuniorTheme.orange)
                        Text(warning).font(.footnote)
                        Spacer(minLength: 0)
                        Button("Tamam") { live.dismissWarning() }.font(.footnote.weight(.semibold))
                    }
                }
            }
        } header: {
            Text("Sürekli dinleme")
        } footer: {
            Text("Açıkken telefon gün boyu dinler (pil tüketimi artar). Konuşma algılanınca 0,6–25 saniyelik "
                 + "parçalar kesilir, telefonda bekletilir ve bilgisayara yüklenir; yazıya çevirme, konuşmacı "
                 + "ayrımı ve arşiv bilgisayarda yapılır, ses başka hiçbir yere gönderilmez. Bilgisayar kapalıysa "
                 + "parçalar telefonda birikir (en çok 1,5 GB; dolunca en eskiler silinir). Telefon görüşmesi ya da "
                 + "Siri mikrofonu keser, bitince kendiliğinden devam eder. Konuştuğun kişilerin kaydedildiğini "
                 + "bilmesi gerekebilir; yasalar ülkeden ülkeye değişir.")
        }
    }
}
