import SwiftUI

/// "Kamerayla say": ön kamera önizlemesi, büyük sayı, isteğe bağlı sesli sayma. Bitirince sayı
/// şınav kaydı olarak sunucuya yazılır. Görüntü cihazda işlenir, ağa gitmez.
struct PushupCameraView: View {
    @ObservedObject var model: SkillsModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = PushupCameraSession()
    @State private var saving = false
    @State private var saveFailure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.status == .running || camera.status == .starting {
                CameraPreview(session: camera.session).ignoresSafeArea()
            }
            VStack {
                topBar
                Spacer()
                counterPanel
            }
            .padding()
            if camera.status == .denied {
                message("Kamera izni verilmemiş. Ayarlar > Junior > Kamera'dan izin ver, sonra yeniden aç.")
            }
            if case .unavailable(let text) = camera.status {
                message(text)
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    private var topBar: some View {
        HStack {
            Button("Vazgeç") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
            Spacer()
            Toggle(isOn: Binding(get: { camera.speakCounts }, set: { camera.setSpeaking($0) })) {
                Label("Sesli say", systemImage: "speaker.wave.2.fill")
            }
            .toggleStyle(.button)
            .tint(JuniorTheme.green)
        }
    }

    private var counterPanel: some View {
        VStack(spacing: 10) {
            Text("\(camera.count)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(camera.tracking ? camera.hint : "Seni göremiyorum: telefonu yere, yan görünecek biçimde dayayıp kollarını kadraja al.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(camera.tracking ? .white : JuniorTheme.orange)
            HStack {
                Button("Sıfırla") { camera.resetCount() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(camera.count == 0)
                Button {
                    Task { await finish() }
                } label: {
                    SkillButtonLabel(title: saveFailure != nil ? "Yeniden dene" : (camera.count > 0 ? "Bitir ve \(camera.count) şınavı kaydet" : "Bitir"),
                                     systemImage: "checkmark.circle.fill", busy: saving)
                }
                .buttonStyle(.borderedProminent)
                .tint(JuniorTheme.green)
                .disabled(saving)
            }
            if let saveFailure {
                Text("Kaydedilemedi: \(saveFailure) Sayı korunuyor; \"Yeniden dene\" ile tekrar kaydedebilirsin.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(JuniorTheme.orange)
            }
            Text("Görüntü yalnız telefonda işlenir; hiçbir yere gönderilmez.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding()
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(24)
    }

    private func finish() async {
        camera.stop()
        let total = camera.count
        guard total > 0 else {
            dismiss()
            return
        }
        saving = true
        saveFailure = nil
        let saved = await model.logPushups(total)
        saving = false
        if saved {
            dismiss()
        } else {
            // Kayıt yazılmadı (ağ hatası ya da Şınav paketi kapalı): ekran açık kalır, sayı korunur.
            saveFailure = model.notes[.pushups] ?? "Sunucuya ulaşılamadı."
        }
    }
}
