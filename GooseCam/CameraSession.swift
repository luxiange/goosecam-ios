import AVFoundation
import UIKit

/// 后置摄像头会话：三档变焦、点按对焦、常亮补光、拍照后处理。
final class CameraSession: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "goosecam.camera")
    private var device: AVCaptureDevice?
    private var configured = false

    @Published var torchOn = false
    @Published var busy = false
    @Published var isRunning = false
    @Published var permissionDenied = false

    /// 一张照片处理并落盘后的回调（用于刷新左下角缩略图）
    var onSaved: (() -> Void)?

    func prepare() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.start()
                } else {
                    DispatchQueue.main.async { self.permissionDenied = true }
                }
            }
        default:
            DispatchQueue.main.async { self.permissionDenied = true }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        guard let input = try? AVCaptureDeviceInput(device: dev) else { return }
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else { return }
        session.addOutput(photoOutput)

        device = dev
        configured = true
    }

    // MARK: - 变焦

    func setZoom(_ factor: CGFloat) {
        queue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                let upper = min(dev.maxAvailableVideoZoomFactor, 10.0)
                dev.videoZoomFactor = max(1.0, min(factor, upper))
                dev.unlockForConfiguration()
            } catch {
                // 该倍率不被支持时保持原状
            }
        }
    }

    // MARK: - 补光

    func toggleTorch() {
        queue.async { [weak self] in
            guard let self, let dev = self.device, dev.hasTorch else { return }
            do {
                try dev.lockForConfiguration()
                dev.torchMode = dev.torchMode == .on ? .off : .on
                dev.unlockForConfiguration()
                let on = dev.torchMode == .on
                DispatchQueue.main.async { self.torchOn = on }
            } catch {
                // 过热保护等情况下忽略
            }
        }
    }

    // MARK: - 点按对焦

    /// point 为设备坐标（0…1，左上原点）。
    func focus(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported && dev.isFocusModeSupported(.autoFocus) {
                    dev.focusPointOfInterest = point
                    dev.focusMode = .autoFocus
                }
                if dev.isExposurePointOfInterestSupported && dev.isExposureModeSupported(.autoExpose) {
                    dev.exposurePointOfInterest = point
                    dev.exposureMode = .autoExpose
                }
                dev.unlockForConfiguration()
            } catch {
                // 忽略
            }
        }
    }

    // MARK: - 拍照

    func capture() {
        guard !busy else { return }
        busy = true
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg] as [String: Any])
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.busy = false }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = UIImage(data: data)
            let processed = raw.flatMap { M72Filter.processPhoto($0) }
            if let processed {
                PhotoStore.shared.save(processed, prefix: "M72")
            }
            DispatchQueue.main.async {
                self?.busy = false
                self?.onSaved?()
            }
        }
    }
}
