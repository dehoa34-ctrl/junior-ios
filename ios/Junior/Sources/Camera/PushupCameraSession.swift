import AVFoundation
import SwiftUI
import UIKit
import Vision

/// Ön kameradan şınav sayar. Görüntü cihazda işlenir (VNDetectHumanBodyPoseRequest); hiçbir kare
/// ağa gitmez ve saklanmaz. Sayma kararı PushupCounter'da (saf mantık); burası yalnız kamera,
/// Vision ve ekrana durum yayınıdır. @Published alanlar yalnız ana kuyrukta yazılır.
final class PushupCameraSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Status: Equatable {
        case idle, starting, running
        case denied
        case unavailable(String)
    }

    @Published private(set) var count = 0
    @Published private(set) var status: Status = .idle
    @Published private(set) var hint = PushupCounter().hint
    /// Son karede kol bulundu mu (ekranda "seni göremiyorum" uyarısı için).
    @Published private(set) var tracking = false
    @Published var speakCounts = false

    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "xyz.jrbilge.junior.pushup.video")
    private let request = VNDetectHumanBodyPoseRequest()
    private let speaker = AVSpeechSynthesizer()
    // Aşağıdakilere yalnız videoQueue'dan dokunulur.
    private var counter = PushupCounter()
    private var configured = false
    private var lastTracking = false
    private var lastHint = ""
    private var speak = false

    @MainActor
    func start() async {
        guard status == .idle || status == .denied || isUnavailable else { return }
        status = .starting
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            status = .denied
            return
        }
        guard configureIfNeeded() else {
            if !isUnavailable { status = .unavailable("Kamera açılamadı.") }
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        let session = self.session
        videoQueue.async { [weak self] in
            self?.counter.reset()
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { self?.status = .running }
        }
    }

    @MainActor
    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        speaker.stopSpeaking(at: .immediate)
        let session = self.session
        videoQueue.async { if session.isRunning { session.stopRunning() } }
        if status == .running || status == .starting { status = .idle }
    }

    @MainActor
    func resetCount() {
        count = 0
        hint = PushupCounter().hint
        videoQueue.async { [weak self] in self?.counter.reset() }
    }

    @MainActor
    func setSpeaking(_ on: Bool) {
        speakCounts = on
        videoQueue.async { [weak self] in self?.speak = on }
    }

    private var isUnavailable: Bool {
        if case .unavailable = status { return true }
        return false
    }

    @MainActor
    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            status = .unavailable("Bu cihazda ön kamera bulunamadı.")
            return false
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            status = .unavailable("Kamera açılamadı; başka bir uygulama kullanıyor olabilir.")
            return false
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            status = .unavailable("Kamera görüntüsü okunamadı.")
            return false
        }
        session.addOutput(output)
        // Kareler dik gelsin: Vision açıları ve en-boy oranı portre görüntüde hesaplanır.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        configured = true
        return true
    }

    // MARK: - Kare işleme (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        var angle: Double?
        do {
            try handler.perform([request])
            if let observation = request.results?.first {
                let aspect = Double(CVPixelBufferGetWidth(buffer)) / Double(max(1, CVPixelBufferGetHeight(buffer)))
                angle = Self.elbowAngle(of: observation, aspect: aspect)
            }
        } catch {
            angle = nil
        }
        let counted = counter.feed(angle)
        let tracked = angle != nil
        let hintNow = counter.hint
        let total = counter.count
        if counted && speak { DispatchQueue.main.async { [weak self] in self?.say(total) } }
        let hintChanged = hintNow != lastHint
        if counted || hintChanged || tracked != lastTracking {
            lastHint = hintNow
            lastTracking = tracked
            DispatchQueue.main.async { [weak self] in
                self?.count = total
                self?.hint = hintNow
                self?.tracking = tracked
            }
        }
    }

    private static func elbowAngle(of observation: VNHumanBodyPoseObservation, aspect: Double) -> Double? {
        func joint(_ name: VNHumanBodyPoseObservation.JointName) -> JointSample? {
            guard let point = try? observation.recognizedPoint(name) else { return nil }
            // Normalleştirilmiş koordinatlar kare değil; x'i en-boy oranıyla ölçekleyip açıyı bozmayız.
            return JointSample(point: CGPoint(x: point.location.x * aspect, y: point.location.y),
                               confidence: Double(point.confidence))
        }
        func arm(_ shoulder: VNHumanBodyPoseObservation.JointName, _ elbow: VNHumanBodyPoseObservation.JointName,
                 _ wrist: VNHumanBodyPoseObservation.JointName) -> Double? {
            guard let s = joint(shoulder), let e = joint(elbow), let w = joint(wrist) else { return nil }
            return PushupGeometry.elbowAngle(shoulder: s, elbow: e, wrist: w)
        }
        return PushupGeometry.combined(arm(.leftShoulder, .leftElbow, .leftWrist),
                                       arm(.rightShoulder, .rightElbow, .rightWrist))
    }

    private func say(_ number: Int) {
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: String(number))
        utterance.voice = AVSpeechSynthesisVoice(language: "tr-TR")
        speaker.speak(utterance)
    }
}

/// AVCaptureSession önizlemesi.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
