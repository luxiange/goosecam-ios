import AVFoundation
import UIKit
import CoreGraphics

/// 一个后置物理镜头（真实读取机身，不做数码变焦档位）。
struct LensInfo: Identifiable, Hashable {
    let id: String        // AVCaptureDevice.uniqueID
    let focal: Int        // 35mm 等效焦距
    let zoomLabel: String // "0.5x" / "1x" / "3x"
}

/// 后置多摄会话：真实枚举物理镜头（超广角 / 广角 / 长焦）、切换镜头、
/// 点按对焦、常亮补光、拍照后后台冲印。
final class CameraSession: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "goosecam.camera.session")
    private let processQueue = DispatchQueue(label: "goosecam.camera.process", qos: .userInitiated)
    private var devices: [String: AVCaptureDevice] = [:]
    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var configured = false
    private var capturing = false

    @Published var lenses: [LensInfo] = []
    @Published var currentLensID: String = ""
    @Published var torchOn = false
    @Published var processing = false
    @Published var permissionDenied = false
    @Published var lastError: String?

    /// 一张照片处理并落盘后的回调（用于刷新左下角缩略图）
    var onSaved: (() -> Void)?

    // MARK: - 启动 / 停止

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
            Diag.mark("session.start")
            if !self.configured { self.configure() }
            if self.configured, !self.session.isRunning { self.session.startRunning() }
            Diag.mark("session.start done running=\(self.session.isRunning)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - 配置 + 真实镜头枚举

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        let found = Self.discoverLenses()
        Diag.mark("lens.discover \(found.map { "\($0.device.localizedName)/\($0.focal)mm" }.joined(separator: ", "))")
        guard !found.isEmpty else {
            Diag.mark("lens.discover EMPTY")
            DispatchQueue.main.async { self.lastError = "未找到可用后置摄像头" }
            return
        }

        for entry in found { devices[entry.device.uniqueID] = entry.device }

        // 默认用 1x（广角），没有广角就用最接近 1x 的
        let wideEntry = found.first { $0.isWide } ?? found[0]
        guard let input = try? AVCaptureDeviceInput(device: wideEntry.device),
              session.canAddInput(input) else {
            Diag.mark("lens.input FAILED")
            return
        }
        session.addInput(input)
        currentInput = input
        currentDevice = wideEntry.device

        guard session.canAddOutput(photoOutput) else {
            Diag.mark("photoOutput FAILED")
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality

        configured = true
        let list = found.map { LensInfo(id: $0.device.uniqueID, focal: $0.focal, zoomLabel: $0.zoomLabel) }
        let current = wideEntry.device.uniqueID
        DispatchQueue.main.async {
            self.lenses = list
            self.currentLensID = current
        }
        applyInitialFocus(wideEntry.device)
    }

    private struct LensEntry {
        let device: AVCaptureDevice
        let focal: Int
        let zoomLabel: String
        let isWide: Bool
    }

    /// 用 DiscoverySession 枚举机身真实后置镜头，并按 35mm 等效焦距标定。
    private static func discoverLenses() -> [LensEntry] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(iOS 13.0, *) {
            types.append(.builtInUltraWideCamera)
            types.append(.builtInTelephotoCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        var list = discovery.devices

        // 兜底：DiscoverySession 偶尔拿不到多摄，退回默认广角
        if list.isEmpty {
            if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                list = [wide]
            }
        }

        let mapped: [(device: AVCaptureDevice, focal: Int)] = list.compactMap { dev in
            guard let mm = equivalentFocal(dev) else { return nil }
            return (dev, mm)
        }
        guard !mapped.isEmpty else { return [] }

        // 广角基准：优先 builtInWideAngleCamera，其次最接近 26mm 的一枚
        let wideMM: Int
        if let w = list.first(where: { $0.deviceType == .builtInWideAngleCamera }),
           let mm = equivalentFocal(w) {
            wideMM = mm
        } else {
            wideMM = mapped.map { $0.focal }.min(by: { abs($0 - 26) < abs($1 - 26) }) ?? 26
        }

        return mapped
            .sorted { $0.focal < $1.focal }
            .map { entry in
                let ratio = Double(entry.focal) / Double(wideMM)
                let label = ratio >= 0.99 && ratio <= 1.01 ? "1x" : String(format: "%.1fx", ratio)
                return LensEntry(device: entry.device,
                                 focal: entry.focal,
                                 zoomLabel: label,
                                 isWide: abs(entry.focal - wideMM) <= 1)
            }
    }

    /// 用镜头视场角换算 35mm 等效焦距，并吸附到常见焦段（26 / 13 / 77 …）。
    private static func equivalentFocal(_ dev: AVCaptureDevice) -> Int? {
        let fov = Double(dev.activeFormat.videoFieldOfView)
        guard fov > 5, fov < 175 else { return nil }
        let raw = 36.0 / (2.0 * tan(fov * Double.pi / 360.0))
        let standard = [13, 26, 35, 48, 77, 120]
        let nearest = standard.min { abs(Double($0) - raw) < abs(Double($1) - raw) } ?? 26
        // 偏离标准焦段过多时（外接镜头等）直接取整，避免乱吸附
        if abs(Double(nearest) - raw) > 8 {
            return Int(raw.rounded())
        }
        return nearest
    }

    private func applyInitialFocus(_ dev: AVCaptureDevice) {
        do {
            try dev.lockForConfiguration()
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        } catch {
            Diag.mark("focus.init fail \(error.localizedDescription)")
        }
    }

    // MARK: - 切换镜头（真实物理切换，不是数码变焦）

    func selectLens(_ id: String) {
        guard id != currentLensID else { return }
        queue.async { [weak self] in
            guard let self, let dev = self.devices[id] else { return }
            Diag.mark("lens.switch \(id)")
            self.session.beginConfiguration()
            if let old = self.currentInput {
                self.session.removeInput(old)
                self.currentInput = nil
            }
            if let input = try? AVCaptureDeviceInput(device: dev), self.session.canAddInput(input) {
                self.session.addInput(input)
                self.currentInput = input
                self.currentDevice = dev
                self.applyInitialFocus(dev)
                self.applyTorch(dev, on: self.torchOn)
            } else {
                Diag.mark("lens.switch input FAILED")
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.currentLensID = id }
        }
    }

    // MARK: - 补光

    func toggleTorch() {
        queue.async { [weak self] in
            guard let self, let dev = self.currentDevice else { return }
            let want = !self.torchOn
            self.applyTorch(dev, on: want)
            let actual = dev.torchMode == .on
            DispatchQueue.main.async { self.torchOn = actual }
        }
    }

    private func applyTorch(_ dev: AVCaptureDevice, on: Bool) {
        guard dev.hasTorch, dev.isTorchModeSupported(.on) else { return }
        do {
            try dev.lockForConfiguration()
            dev.torchMode = on ? .on : .off
            dev.unlockForConfiguration()
        } catch {
            Diag.mark("torch fail \(error.localizedDescription)")
        }
    }

    // MARK: - 点按对焦

    /// point 为设备坐标（0…1，左上原点）。
    func focus(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let dev = self.currentDevice else { return }
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
                Diag.mark("focus.tap fail \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 拍照

    func capture() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.capturing else { return }
            guard self.configured, self.session.isRunning else {
                Diag.mark("capture SKIP session not running configured=\(self.configured)")
                DispatchQueue.main.async { self.lastError = "相机会话未就绪" }
                return
            }
            self.capturing = true
            Diag.mark("capture.begin")
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        Diag.mark("capture.delegate error=\(error?.localizedDescription ?? "nil")")

        if let error {
            Diag.mark("capture.ERROR \(error.localizedDescription)")
            finishCapture(failed: true)
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            Diag.mark("capture.decode FAILED")
            finishCapture(failed: true)
            return
        }
        Diag.mark("capture.decode ok \(Int(image.size.width))x\(Int(image.size.height))")
        // 拍完即释放快门，允许连续拍摄；冲印在串行队列里排队
        finishCapture(failed: false)

        DispatchQueue.main.async { self.processing = true }

        processQueue.async { [weak self] in
            var saved = false
            autoreleasepool {
                Diag.mark("grade.begin")
                let started = Date()
                if let out = M72Filter.processPhoto(image) {
                    Diag.mark(String(format: "grade.end %.2fs", Date().timeIntervalSince(started)))
                    saved = PhotoStore.shared.save(out, prefix: "M72") != nil
                    Diag.mark("save \(saved ? "ok" : "fail")")
                } else {
                    Diag.mark("grade FAILED")
                }
            }
            DispatchQueue.main.async {
                self?.processing = false
                if saved {
                    self?.onSaved?()
                } else {
                    self?.lastError = "照片冲印失败"
                }
            }
        }
    }

    private func finishCapture(failed: Bool) {
        queue.async { [weak self] in
            self?.capturing = false
        }
        if failed {
            DispatchQueue.main.async { [weak self] in
                self?.processing = false
                self?.lastError = "照片冲印失败"
            }
        }
    }
}
