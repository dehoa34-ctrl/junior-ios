import SwiftUI

/// Bilgisayardaki Junior'ın telefondan istediği onay: sohbetin altında Onayla / Reddet.
struct RemoteConfirmCard: View {
    @ObservedObject var center: RemoteConfirmCenter

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.pending) { confirm in
                row(confirm)
            }
            if let notice = center.notice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(JuniorTheme.cyan)
                    Text(notice).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { center.notice = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Kapat")
                }
                .padding(12)
                .card(radius: 18)
            }
        }
    }

    private func row(_ confirm: RemoteConfirm) -> some View {
        let busy = center.deciding.contains(confirm.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JuniorTheme.orange)
                    .frame(width: 30, height: 30)
                    .background(JuniorTheme.orange.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(confirm.title).font(.subheadline.weight(.semibold))
                    if !confirm.detail.isEmpty {
                        Text(confirm.detail).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Kalan süre saniye saniye azalır; dolunca istek kendiliğinden düşer.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(confirm.expiresAt.timeIntervalSince(context.date)))
                        Text("\(left) sn içinde yanıtlanmazsa reddedilir")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await center.decide(id: confirm.id, approve: false) }
                } label: {
                    Text("Reddet").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await center.decide(id: confirm.id, approve: true) }
                } label: {
                    Text("Onayla").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(JuniorTheme.green)
            }
            .disabled(busy)
        }
        .padding(12)
        .card(radius: 18, tint: JuniorTheme.orange)
    }
}

/// Çevrimdışı kuyruk: kaç komut beklediği ve zamana bağlı eskimiş komut için soru.
struct OfflineQueueCard: View {
    @ObservedObject var store: ConversationStore

    var body: some View {
        let queue = store.offlineQueue
        VStack(spacing: 8) {
            ForEach(queue.held) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock.badge.questionmark")
                            .foregroundStyle(JuniorTheme.orange)
                            .frame(width: 30, height: 30)
                            .background(JuniorTheme.orange.opacity(0.16), in: Circle())
                        Text(OfflineQueue.staleQuestion(item))
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        Button { store.dropQueued(item) } label: { Text("Sil").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                        Button { store.sendStale(item) } label: { Text("Gönder").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .card(radius: 18, tint: JuniorTheme.orange)
            }
            let waiting = queue.waiting
            if !waiting.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JuniorTheme.cyan)
                        .frame(width: 30, height: 30)
                        .background(JuniorTheme.cyan.opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sırada \(waiting.count) komut bekliyor")
                            .font(.footnote.weight(.semibold))
                        Text("Bilgisayara bağlanınca sırayla göndereceğim.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(waiting.prefix(3)) { item in
                            HStack(spacing: 6) {
                                Text("• \(item.text)").font(.caption).lineLimit(1)
                                Spacer(minLength: 0)
                                Button { store.dropQueued(item) } label: { Image(systemName: "xmark.circle.fill") }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Sıradan sil")
                            }
                        }
                        if waiting.count > 3 {
                            Text("ve \(waiting.count - 3) komut daha").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .card(radius: 18, tint: JuniorTheme.cyan)
            }
        }
    }
}

/// Ayarlar → Bildirimler: kategoriler tek tek açılıp kapatılır.
struct NotificationSettingsSection: View {
    @State private var enabled = NotificationPreferences.enabledSet()

    var body: some View {
        Section {
            ForEach(NotificationCategory.allCases) { category in
                Toggle(isOn: binding(category)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                            Text(category.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        SettingIcon(systemName: category.symbol, color: color(category))
                    }
                }
            }
        } header: {
            Text("Bildirimler")
        } footer: {
            Text("Kapalı türden bildirim gelmez. Sessiz saatlerde (Rutinler ve sessiz saatler) yoklama ve yeni başlık "
                 + "izleme bildirimleri susar; kendi kurduğun saatli hatırlatma yine gelir. Zamanlayıcı, dokununca "
                 + "yapılacak telefon eylemleri ve bilgisayardan açıkça gönderilen not ya da bağlantılar her zaman gelir.")
        }
    }

    private func binding(_ category: NotificationCategory) -> Binding<Bool> {
        Binding(get: { enabled.contains(category) }, set: { on in
            NotificationPreferences.set(category, enabled: on)
            enabled = NotificationPreferences.enabledSet()
            // Gün boyu kaydın "kayıt durmuş olabilir" bildirimi önceden kurulmuştur; hemen silinsin.
            if category == .system, !on { MicrophoneHub.cancelAliveAlert() }
        })
    }

    private func color(_ category: NotificationCategory) -> Color {
        switch category {
        case .task: return JuniorTheme.green
        case .routine: return JuniorTheme.violet
        case .checkin: return JuniorTheme.cyan
        case .watch: return JuniorTheme.blue
        case .system: return JuniorTheme.red
        case .remote: return JuniorTheme.orange
        }
    }
}
