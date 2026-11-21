import AVKit
import Combine
import SwiftUI

/// Sohbetteki video bağlantısı için oynatıcı sayfası.
///
/// Akış adresi bilgisayardaki sunucudan istenir (`/v1/media/resolve`, sunucuda yt-dlp).
/// Oynatıcı **sessiz** başlar; ses açılınca "Hey Junior" dinlemesi duraklar, kapanınca ya da
/// sayfa kapanınca sürer (`VideoAudioGate`).
struct VideoPlayerSheet: View {
    let source: URL
    let config: Config
    /// Uyandırma dinlemesini duraklat / sürdür (RootView eller serbest döngüsüne iletir).
    var onAudio: (VideoAudioGate.Effect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var media: ResolvedMedia?
    @State private var errorText: String?
    @State private var gate = VideoAudioGate()
    /// Akış çözülemedi (ör. bilgisayarda yt-dlp yok): sitenin resmî gömülü oynatıcısı.
    @State private var embedURL: URL?
    /// Sesli komut kaydının sahibi (VideoPlaybackCenter).
    @State private var owner = UUID()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if let player {
                        VideoPlayer(player: player)
                            .onReceive(player.publisher(for: \.isMuted).removeDuplicates()) { muted in
                                apply(gate.setMuted(muted))
                            }
                    } else if let embedURL {
                        EmbeddedVideoView(url: embedURL)
                    } else if let errorText {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JuniorTheme.orange)
                            Text(errorText).font(.footnote).multilineTextAlignment(.center)
                        }
                        .padding()
                    } else {
                        ProgressView("Video hazırlanıyor…")
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let media, !media.title.isEmpty {
                    Text(media.title).font(.headline).lineLimit(3)
                }
                if embedURL != nil, let errorText {
                    // Dürüst not: neden gömülü oynatıcıda açıldı, sesle sarma neden yok.
                    Text("\(errorText) Video gömülü oynatıcıda açıldı; sesle sarma ve ses ayarı bu oynatıcıda çalışmaz.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if player != nil {
                    Button {
                        player?.isMuted.toggle()
                    } label: {
                        Label(gate.muted ? "Sesi aç" : "Sesi kapat",
                              systemImage: gate.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    Text(gate.muted
                         ? "Video sessiz başladı. Ses açılınca \"Hey Junior\" dinlemesi duraklar."
                         : "Ses açık: \"Hey Junior\" dinlemesi duraklatıldı; ses kapanınca sürer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Link(destination: source) {
                    Label("Tarayıcıda aç", systemImage: "safari")
                }
                .font(.footnote)
                Spacer()
            }
            .padding(16)
            .background(JuniorTheme.background.ignoresSafeArea())
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear {
            player?.pause()
            apply(gate.close())
            VideoPlaybackCenter.shared.detach(owner: owner)
        }
    }

    private func load() async {
        guard player == nil, embedURL == nil else { return }
        let close = dismiss
        do {
            let resolved = try await MediaResolver.resolve(source, config: config)
            media = resolved
            let item = AVPlayer(url: resolved.streamURL)
            item.isMuted = true
            player = item
            // Sesle sarma ("30 saniye ileri") bu oynatıcıya telefonda yerelde uygulanır.
            VideoPlaybackCenter.shared.attach(item, owner: owner) { close() }
            item.play()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Video açılamadı."
            if let embed = VideoEmbed.embedURL(for: source) {
                embedURL = embed
                VideoPlaybackCenter.shared.attachEmbedded(owner: owner) { close() }
            }
        }
    }

    private func apply(_ effect: VideoAudioGate.Effect) {
        if effect != .none { onAudio(effect) }
    }
}
