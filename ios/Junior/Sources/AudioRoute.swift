import Foundation
import AVFoundation

/// Sesin hangi cihazdan girip çıktığını izler.
///
/// Gözlük hazırlığının doğrulanabilir kısmı budur: Ray-Ban Meta bağlandığında
/// mikrofonun gerçekten oraya gittiğini görmeden "gözlükten konuşuyor" denemez.
/// Meta DAT gerektirmez; Bluetooth HFP yönlendirmesi iOS tarafında olur.
@MainActor
final class AudioRoute: ObservableObject {
    struct Description: Equatable {
        let inputName: String
        let outputName: String
        let isBluetoothInput: Bool
        let isBuiltInInput: Bool

        /// Kullanıcıya gösterilecek kısa etiket.
        var label: String {
            isBuiltInInput ? "iPhone mikrofonu" : inputName
        }
    }

    @Published private(set) var current: Description?
    /// Dinleme sırasında yol değişirse doldurulur; kayıt güvenilir olmayabilir.
    @Published var routeChangedWhileListening = false

    private var observer: NSObjectProtocol?
    private var listening = false

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in self?.handle(reason: reason) }
        }
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func beginListening() {
        listening = true
        routeChangedWhileListening = false
        refresh()
    }

    func endListening() {
        listening = false
    }

    func refresh() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let input = route.inputs.first
        let output = route.outputs.first
        let bluetoothInputs: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE]
        current = Description(
            inputName: input?.portName ?? "bilinmiyor",
            outputName: output?.portName ?? "bilinmiyor",
            isBluetoothInput: input.map { bluetoothInputs.contains($0.portType) } ?? false,
            isBuiltInInput: input?.portType == .builtInMic
        )
    }

    private func handle(reason: AVAudioSession.RouteChangeReason?) {
        refresh()
        // Cihaz çıkarıldıysa veya kategori değiştiyse süren kayıt bölünmüş olabilir.
        if listening, reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            routeChangedWhileListening = true
        }
    }
}
