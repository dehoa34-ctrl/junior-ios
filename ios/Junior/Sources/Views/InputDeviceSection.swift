import AVFoundation
import SwiftUI

/// Ayarlar'daki giriş aygıtı seçimi ve TEST'i.
@MainActor
final class InputTestModel: ObservableObject {
    static let duration: TimeInterval = 5
    private static let sampleEvery: UInt64 = 100_000_000

    @Published private(set) var devices: [InputDevice] = []
    /// "" = otomatik (gözlük/kulaklık bağlıysa ondan, yoksa iPhone mikrofonu).
    @Published private(set) var selectedUID: String
    /// Şu an sesin alındığı giriş.
    @Published private(set) var currentInput = "bilinmiyor"
    @Published private(set) var level: Float = 0
    @Published private(set) var running = false
    @Published private(set) var remaining = 0
    @Published private(set) var verdict: InputTestVerdict?
    @Published private(set) var errorText: String?

    private var routeObserver: NSObjectProtocol?
    private var testTask: Task<Void, Never>?

    init() {
        selectedUID = UserDefaults.standard.string(forKey: InputDevices.preferredKey) ?? ""
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Yalnız listeyi tazeler; kategoriye dokunmaz (seslendirmenin .playback'ini bozmasın).
            Task { @MainActor in self?.refresh(userInitiated: false) }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// Bağlı girişleri okur. Girişler yalnız kayıt destekleyen kategoride listelenir; kullanıcının
    /// başlattığı okumada ve mikrofon kimse tarafından tutulmuyorsa kategori (etkinleştirmeden)
    /// kayıtlı olana çevrilir (`InputDevices.shouldPrepareRecordCategory`).
    func refresh(userInitiated: Bool = true) {
        let session = AVAudioSession.sharedInstance()
        if InputDevices.shouldPrepareRecordCategory(alreadyRecordCategory: session.category == .playAndRecord,
                                                    microphoneWanted: MicrophoneHub.shared.isWanted,
                                                    userInitiated: userInitiated) {
            try? session.setCategory(.playAndRecord, mode: .spokenAudio,
                                     options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        }
        devices = (session.availableInputs ?? []).map {
            InputDevices.make(uid: $0.uid, name: $0.portName, port: $0.portType)
        }
        if let input = session.currentRoute.inputs.first {
            currentInput = InputDevices.make(uid: input.uid, name: input.portName, port: input.portType).label
        } else if let preferred = InputDevices.choose(preferredUID: selectedUID, available: devices) {
            currentInput = preferred.label
        } else {
            currentInput = devices.first?.label ?? "bilinmiyor"
        }
    }

    func select(_ uid: String) {
        selectedUID = uid
        if uid.isEmpty {
            UserDefaults.standard.removeObject(forKey: InputDevices.preferredKey)
        } else {
            UserDefaults.standard.set(uid, forKey: InputDevices.preferredKey)
        }
        // Mikrofon açıksa giriş hemen değişir (motor yeni girişle yeniden kurulur); kapalıysa
        // bir sonraki açılışta uygulanır.
        MicrophoneHub.shared.preferHeadsetMicIfWanted()
        verdict = nil
        refresh()
    }

    /// 5 sn canlı seviye. Bitince ses gelip gelmediği söylenir.
    func runTest() {
        guard !running else { return }
        testTask = Task { [weak self] in await self?.measure() }
    }

    func stop() {
        testTask?.cancel()
    }

    private func measure() async {
        errorText = nil
        verdict = nil
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else {
            errorText = "Mikrofon izni yok. Ayarlar > Gizlilik > Mikrofon'dan Junior'a izin ver."
            return
        }
        let meter = LevelMeter()
        running = true
        level = 0
        do {
            try MicrophoneHub.shared.startLevelTest(meter)
        } catch {
            // Motor yol değişirken açılamadı; hub yeniden deniyor. Ölçüm yine 5 sn sürer:
            // ses gelmezse sonuç "ses gelmedi" olur.
        }
        refresh()
        var levels: [Float] = []
        var seenBuffers = 0
        let steps = Int(Self.duration * 10)
        for step in 0..<steps {
            if Task.isCancelled { break }
            remaining = Int((Double(steps - step) / 10).rounded(.up))
            try? await Task.sleep(nanoseconds: Self.sampleEvery)
            let snapshot = meter.snapshot
            if snapshot.buffers > seenBuffers {
                seenBuffers = snapshot.buffers
                let value = MicLevel.normalized(rms: snapshot.rms)
                levels.append(value)
                level = value
            } else {
                level = max(0, level - 0.08)
            }
        }
        MicrophoneHub.shared.stopLevelTest()
        running = false
        remaining = 0
        level = 0
        refresh()
        if !Task.isCancelled { verdict = InputTestVerdict.evaluate(levels: levels) }
    }
}

/// Ayarlar bölümü: giriş seçimi, canlı seviye çubuğu ve TEST.
struct InputDeviceSection: View {
    @StateObject private var model = InputTestModel()

    var body: some View {
        Section {
            Picker(selection: Binding(get: { model.selectedUID }, set: { model.select($0) })) {
                Text("Otomatik").tag("")
                ForEach(model.devices) { device in
                    Label(device.label, systemImage: device.kind.symbol).tag(device.id)
                }
                // Seçili aygıt şu an bağlı değilse de listede görünsün (bağlanınca kullanılır).
                if !model.selectedUID.isEmpty, !model.devices.contains(where: { $0.id == model.selectedUID }) {
                    Text("Seçili aygıt (bağlı değil)").tag(model.selectedUID)
                }
            } label: {
                Label { Text("Giriş aygıtı") } icon: { SettingIcon(systemName: "mic.fill", color: JuniorTheme.blue) }
            }
            LabeledContent("Şu an", value: model.currentInput)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        if model.running { model.stop() } else { model.runTest() }
                    } label: {
                        Label { Text(model.running ? "Durdur (\(model.remaining))" : "TEST") } icon: {
                            SettingIcon(systemName: "waveform", color: JuniorTheme.green)
                        }
                    }
                    Spacer()
                }
                LevelBar(level: model.level, active: model.running)
                    .frame(height: 10)
                if model.running {
                    Text("Konuş: çubuk sesine göre dolmalı.").font(.footnote).foregroundStyle(.secondary)
                }
                if let verdict = model.verdict {
                    Text(verdict.message(input: model.currentInput))
                        .font(.footnote)
                        .foregroundStyle(verdict.isOK ? JuniorTheme.green : JuniorTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.errorText {
                    Text(error).font(.footnote).foregroundStyle(JuniorTheme.red)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Giriş aygıtı")
        } footer: {
            Text("Otomatik: gözlük ya da kulaklık bağlıysa mikrofon ondan alınır (\"Gözlük mikrofonu\" açıkken). "
                 + "TEST 5 saniye mikrofon seviyesini gösterir; \"Hey Junior\", sürekli dinleme ve gün boyu "
                 + "kayıt bu sırada durmaz.")
        }
        .onAppear { model.refresh() }
        .onDisappear { model.stop() }
    }
}

/// Mikrofon seviyesi çubuğu (0…1).
private struct LevelBar: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(JuniorTheme.surfaceStrong)
                Capsule()
                    .fill(LinearGradient(colors: [JuniorTheme.green, JuniorTheme.cyan],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(active ? level : 0))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .accessibilityLabel("Mikrofon seviyesi")
        .accessibilityValue("\(Int(level * 100))")
    }
}
