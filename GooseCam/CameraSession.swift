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

    /// 机身支持的 Bayer RAW 像素格式（iPhone 13 上就是 12MP DNG）
    private var rawFormat: OSType?
    /// 同一帧的 JPEG 备份：RAW 解码失败时退回去用它
    private var jpegFallback: [Int64: Data] = [:]
    /// 正在冲印 RAW 的帧
    private var pendingRaw: Set<Int64> = []
    /// 已经出过片的帧（防止 RAW 和 JPEG 双写）
    private var doneIDs: Set<Int64> = []
    private let fallbackLock = NSLock()

    @Published var lenses: [LensInfo] = []
    @Published var currentLensID: String = ""
    @Published var torchOn = false
    @Published var processing = false
    @Published var permissionDenied = false
    @Published var lastError: String?
    /// 当前是否走 RAW 管线（UI 上打 RAW 徽标）
    @Published var usingRaw = false

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

        // Bayer RAW：和 gloam 一样，拿传感器原始数据再自己调色，
        // 而不是吃 Apple 已经拉亮/锐化/降噪过的 JPEG。
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        rawFormat = rawTypes.first
        Diag.mark("raw.formats \(rawTypes.map { "\($0)" }.joined(separator: ","))")

        configured = true
        let list = found.map { LensInfo(id: $0.device.uniqueID, focal: $0.focal, zoomLabel: $0.zoomLabel) }
        let current = wideEntry.device.uniqueID
        let hasRaw = rawFormat != nil
        DispatchQueue.main.async {
            self.lenses = list
            self.currentLensID = current
            self.usingRaw = hasRaw
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

            let settings: AVCapturePhotoSettings
            if let raw = self.rawFormat {
                // RAW + JPEG 双输出：主用 RAW 冲印，JPEG 只做兜底
                // 注意：RAW settings 不要动 photoQualityPrioritization，Apple 对 RAW 这一档有额外约束
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: raw,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                )
                Diag.mark("capture.begin raw=\(raw)")
            } else {
                settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .quality
                Diag.mark("capture.begin jpeg")
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let photoID = photo.resolvedSettings.uniqueID
        let isRaw = photo.isRawPhoto
        Diag.mark("capture.delegate raw=\(isRaw) id=\(photoID) error=\(error?.localizedDescription ?? "nil")")

        if let error {
            Diag.mark("capture.ERROR \(error.localizedDescription)")
            // RAW 失败但 JPEG 备份还在时，仍有机会出片
            if !isRaw, let fallback = takeFallback(photoID) {
                finishCapture(failed: false, photoID: photoID)
                process(jpegData: fallback, photoID: photoID)
                return
            }
            finishCapture(failed: true, photoID: photoID)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            Diag.mark("capture.decode FAILED raw=\(isRaw)")
            finishCapture(failed: true, photoID: photoID)
            return
        }

        if isRaw {
            finishCapture(failed: false, photoID: photoID)
            process(rawData: data, photoID: photoID)
        } else {
            if rawFormat != nil {
                // RAW 还没回来，先把 JPEG 备胎存起来；快门立即释放，允许连拍
                finishCapture(failed: false, photoID: photoID)
                storeFallback(data, photoID: photoID)
            } else {
                finishCapture(failed: false, photoID: photoID)
                process(jpegData: data, photoID: photoID)
            }
        }
    }

    // MARK: - 冲印

    private func process(rawData: Data, photoID: Int64) {
        markPending(photoID)
        DispatchQueue.main.async { self.processing = true }
        processQueue.async { [weak self] in
            guard let self else { return }
            var saved = false
            autoreleasepool {
                Diag.mark("grade.raw begin")
                let started = Date()
                if let image = M72Filter.developRaw(rawData), let out = M72Filter.processPhoto(image) {
                    Diag.mark(String(format: "grade.raw end %.2fs", Date().timeIntervalSince(started)))
                    saved = PhotoStore.shared.save(out, prefix: "M72") != nil
                    Diag.mark("save(raw) \(saved ? "ok" : "fail")")
                } else {
                    Diag.mark("grade.raw FAILED")
                }
            }

            // RAW 没成功就退回同帧 JPEG
            if !saved, let fallback = self.takeFallback(photoID) {
                Diag.mark("grade.raw fallback to jpeg")
                autoreleasepool {
                    if let image = UIImage(data: fallback), let out = M72Filter.processPhoto(image) {
                        saved = PhotoStore.shared.save(out, prefix: "M72") != nil
                    }
                }
            }
            self.dropFallback(photoID)
            self.markDone(photoID)

            DispatchQueue.main.async {
                self.processing = false
                if saved {
                    self.onSaved?()
                } else {
                    self.lastError = "照片冲印失败"
                }
            }
        }
    }

    private func process(jpegData: Data, photoID: Int64) {
        markPending(photoID)
        DispatchQueue.main.async { self.processing = true }
        processQueue.async { [weak self] in
            guard let self else { return }
            var saved = false
            autoreleasepool {
                Diag.mark("grade.jpeg begin")
                let started = Date()
                if let image = UIImage(data: jpegData), let out = M72Filter.processPhoto(image) {
                    Diag.mark(String(format: "grade.jpeg end %.2fs", Date().timeIntervalSince(started)))
                    saved = PhotoStore.shared.save(out, prefix: "M72") != nil
                } else {
                    Diag.mark("grade.jpeg FAILED")
                }
            }
            self.markDone(photoID)
            DispatchQueue.main.async {
                self.processing = false
                if saved {
                    self.onSaved?()
                } else {
                    self.lastError = "照片冲印失败"
                }
            }
        }
    }

    // MARK: - JPEG 备胎

    private func storeFallback(_ data: Data, photoID: Int64) {
        fallbackLock.lock()
        jpegFallback[photoID] = data
        if jpegFallback.count > 6, let oldest = jpegFallback.keys.min() {
            jpegFallback.removeValue(forKey: oldest)
        }
        fallbackLock.unlock()

        // RAW 万一没回来（机型不支持 / 出错），2.5 秒后用这帧 JPEG 出片，保证不空拍
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.fallbackLock.lock()
            let pending = self.pendingRaw.contains(photoID)
            let done = self.doneIDs.contains(photoID)
            let data = pending || done ? nil : self.jpegFallback[photoID]
            self.fallbackLock.unlock()
            guard let data else { return }
            Diag.mark("jpeg fallback fired id=\(photoID)")
            self.finishCapture(failed: false, photoID: photoID)
            self.process(jpegData: data, photoID: photoID)
        }
    }

    private func takeFallback(_ photoID: Int64) -> Data? {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        return jpegFallback[photoID]
    }

    private func dropFallback(_ photoID: Int64) {
        fallbackLock.lock()
        jpegFallback.removeValue(forKey: photoID)
        fallbackLock.unlock()
    }

    private func markPending(_ photoID: Int64) {
        fallbackLock.lock()
        pendingRaw.insert(photoID)
        fallbackLock.unlock()
    }

    private func markDone(_ photoID: Int64) {
        fallbackLock.lock()
        pendingRaw.remove(photoID)
        doneIDs.insert(photoID)
        if doneIDs.count > 32, let oldest = doneIDs.min() {
            doneIDs.remove(oldest)
        }
        fallbackLock.unlock()
    }

    private func finishCapture(failed: Bool, photoID: Int64) {
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
