import UIKit
import CoreGraphics
import CoreImage

/// Gloam M72 风格处理（0.41 版：按 gloam 样片重新标定的胶片曲线）。
///
/// 与 0.40 的区别：0.40 是在安卓 JPG 上调出来的“自适应微调”打法，
/// 在 iPhone 上因为 Apple 已经把 JPEG 拉亮/锐化/降噪，再叠那套只会更灰更亮。
/// 0.41 改成以 gloam 样片为基准标定出来的**固定胶片曲线**：
///   1) 曝光基准 ×1.05；
///   2) 高光肩部（>0.56 用二次衰减压回去，gloam 的 p90 只有 160，而我们原来 197）；
///   3) 黑位脚部（暗部再压 0.03，gloam 的 p10 是 13，我们原来 21）；
///   4) 分色段乘性偏色：暗部偏暖褐（B×0.80）、高光偏奶油（B×0.94）；
///   5) 冷相收敛、颗粒、暗角、黑边。
/// 全部在自建位图上直接算，不依赖 UIGraphicsImageRenderer 的 cgContext.data。
enum M72Filter {

    private static let targetRatio = 4.0 / 5.0
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - 对外流水线

    /// 拍照：4:5 居中裁切 → M72 调色 → 黑边框
    /// debugSave=true 时把“调色前”的底图存到 Documents/goosecam/debug/pre.jpg，供离线标定用
    static func processPhoto(_ image: UIImage, debugSave: Bool = false) -> UIImage? {
        guard let raster = rasterize(image, cropTo45: true, standardSize: nil) else { return nil }
        defer { raster.dispose() }
        if debugSave { dumpDebug(raster) }
        guard grade(raster) else { return nil }
        softSharpen(raster, soft: 0.06, sharpen: 0.18)
        bloom(raster, threshold: 0.72, strength: 0.08)
        vignette(raster)
        return bordered(raster)
    }

    /// 把调色前的底图与统计写盘（只用于标定，正式版可关）
    private static func dumpDebug(_ r: Raster) {
        guard let img = r.makeImage(), let data = img.jpegData(compressionQuality: 0.9) else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("goosecam/debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pre.jpg")
        try? data.write(to: url)
        Diag.mark("debug.pre saved \(r.width)x\(r.height) -> \(url.lastPathComponent)")
    }

    /// 导入：4:5 居中裁切（横图 5:4）→ 标准化分辨率 → M72 调色 → 黑边框
    static func processImport(_ image: UIImage) -> UIImage? {
        guard let cropped = rasterize(image, cropTo45: true, standardSize: nil) else { return nil }
        defer { cropped.dispose() }

        let landscape = cropped.width > cropped.height
        let targetW = landscape ? 3840 : 3072
        let targetH = landscape ? 3072 : 3840

        var work = cropped
        var scaled: Raster?
        if cropped.width != targetW || cropped.height != targetH {
            if let s = resized(cropped, toWidth: targetW, height: targetH) { scaled = s; work = s }
        }
        defer { scaled?.dispose() }

        guard grade(work) else { return nil }
        softSharpen(work, soft: 0.06, sharpen: 0.18)
        bloom(work, threshold: 0.72, strength: 0.08)
        vignette(work)
        return bordered(work)
    }

    // MARK: - 位图容器

    /// RGBA8（非预乘 alpha 混淆版：alpha 恒为 255）位图，行序自上而下。
    final class Raster {
        let width: Int
        let height: Int
        let px: UnsafeMutablePointer<UInt8>

        private init(width: Int, height: Int, px: UnsafeMutablePointer<UInt8>) {
            self.width = width
            self.height = height
            self.px = px
        }

        static func make(width: Int, height: Int) -> Raster? {
            guard width > 1, height > 1, width * height < 40_000_000 else { return nil }
            let count = width * height * 4
            let raw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
                .bindMemory(to: UInt8.self, capacity: count)
            raw.initialize(repeating: 255, count: count)
            return Raster(width: width, height: height, px: raw)
        }

        func context() -> CGContext? {
            CGContext(
                data: px,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }

        func makeImage() -> UIImage? {
            guard let ctx = context(), let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }

        private var freed = false
        func dispose() {
            guard !freed else { return }
            freed = true
            px.deallocate()
        }
        deinit { dispose() }
    }

    // MARK: - 栅格化

    /// 取“摆正”的 CGImage：UIImage 带着 EXIF 方向（竖拍通常是 .right / 6）时，
    /// cgImage 本身是横的原始像素，直接拿它算会把竖拍照片做成横图。
    /// 这里先在解码阶段按方向重绘成 .up，后续所有裁剪、调色都在正立的像素上做。
    private static func cgImage(of image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }

        // image.size 已经是考虑方向后的显示尺寸，按它重绘即可完成旋转
        let size = CGSize(width: max(1, image.size.width * image.scale),
                          height: max(1, image.size.height * image.scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        format.prefersExtendedRange = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    /// Bayer RAW（DNG）解码：Core Image 走 RAW 管线做去马赛克与线性化，
    /// 得到的是未经 JPEG 那种“重度拉亮+锐化+降噪”的原始信息，再交给我们的胶片曲线。
    static func developRaw(_ data: Data) -> UIImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goose_\(UUID().uuidString).dng")
        do {
            try data.write(to: tmp)
        } catch {
            Diag.mark("raw.write FAILED \(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard let ci = CIImage(contentsOf: tmp, options: options) else {
            Diag.mark("raw.decode FAILED")
            return nil
        }
        let extent = ci.extent
        guard extent.width > 16, extent.height > 16 else {
            Diag.mark("raw.extent FAILED \(extent)")
            return nil
        }
        Diag.mark("raw.decode ok \(Int(extent.width))x\(Int(extent.height))")

        let normalized = ci.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                             y: -extent.origin.y))
        let ctx = CIContext(options: [.cacheIntermediates: false])
        guard let cg = ctx.createCGImage(normalized, from: CGRect(origin: .zero, size: extent.size)) else {
            Diag.mark("raw.render FAILED")
            return nil
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// 居中裁切 4:5（横图 5:4）后写入自建位图。
    static func rasterize(_ image: UIImage, cropTo45: Bool, standardSize: CGSize?) -> Raster? {
        guard let cg = cgImage(of: image) else { return nil }
        let cgW = CGFloat(cg.width)
        let cgH = CGFloat(cg.height)
        guard cgW > 8, cgH > 8 else { return nil }

        var crop = CGRect(x: 0, y: 0, width: cgW, height: cgH)
        if cropTo45 {
            let landscape = cgW > cgH
            let target: CGFloat = landscape ? (1.0 / targetRatio) : targetRatio
            let ratio = cgW / cgH
            var w = cgW
            var h = cgH
            if ratio > target {
                w = (cgH * target).rounded()
            } else {
                h = (cgW / target).rounded()
            }
            w = min(max(w, 1), cgW)
            h = min(max(h, 1), cgH)
            crop = CGRect(x: ((cgW - w) / 2).rounded(), y: ((cgH - h) / 2).rounded(), width: w, height: h)
        }

        let outW: Int
        let outH: Int
        if let standard = standardSize {
            outW = Int(standard.width.rounded())
            outH = Int(standard.height.rounded())
        } else {
            outW = Int(crop.width.rounded())
            outH = Int(crop.height.rounded())
        }
        guard let raster = Raster.make(width: outW, height: outH), let ctx = raster.context() else { return nil }

        ctx.interpolationQuality = .high
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))

        // 目标缩放比与输出偏移（CGContext 用户空间原点在左下，需换算竖向偏移）
        let sx = CGFloat(outW) / crop.width
        let sy = CGFloat(outH) / crop.height
        let yUp = cgH - crop.maxY
        ctx.draw(cg, in: CGRect(x: -crop.minX * sx, y: -yUp * sy,
                                width: cgW * sx, height: cgH * sy))
        return raster
    }

    /// 重采样到指定尺寸（导入图标准化用）。
    private static func resized(_ r: Raster, toWidth: Int, height: Int) -> Raster? {
        guard let src = r.makeImage(), let dst = Raster.make(width: toWidth, height: height), let ctx = dst.context() else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(src.cgImage!, in: CGRect(x: 0, y: 0, width: toWidth, height: height))
        return dst
    }

    // MARK: - 调色（0.41 标定曲线）

    /// 两遍式：先统计场景亮度/饱和/色偏，再按固定胶片曲线逐像素处理。
    @discardableResult
    static func grade(_ r: Raster) -> Bool {
        let w = r.width
        let h = r.height
        let px = r.px
        let n = w * h
        guard n > 16 else { return false }

        // —— 第一遍：统计 ——
        var lumSum: Double = 0
        var satSum: Double = 0
        var rbSum: Double = 0
        var hist = [Int](repeating: 0, count: 256)

        var i = 0
        while i < n {
            let o = i * 4
            let rf = Double(px[o]) / 255.0
            let gf = Double(px[o + 1]) / 255.0
            let bf = Double(px[o + 2]) / 255.0
            let lum = 0.299 * rf + 0.587 * gf + 0.114 * bf
            lumSum += lum
            let mx = max(rf, max(gf, bf))
            let mn = min(rf, min(gf, bf))
            satSum += mx > 1e-6 ? (mx - mn) / mx : 0
            rbSum += rf - bf
            hist[min(255, max(0, Int((lum * 255.0).rounded())))] += 1
            i += 1
        }

        let total = Double(n)
        let meanLum = lumSum / total
        let meanSat = satSum / total
        let meanRb = rbSum / total

        let p10 = percentile(hist, 0.10, total)
        let p50 = percentile(hist, 0.50, total)
        let p90 = percentile(hist, 0.90, total)

        // —— 基准归一化 ——
        // 关键：RAW 渲染出来的底子和系统 JPEG 不在同一个亮度区间（同一场景中位亮度能差 0.07），
        // 所以先用中位亮度把画面锚到标定域（0.43），再做固定曲线，否则中调会整片顶进高光肩部。
        let anchor = 0.43
        let normGain = clamp(anchor / max(p50, 0.05), 0.55, 1.75)
        Diag.mark(String(format: "grade.in median=%.3f p10=%.3f p90=%.3f sat=%.3f rb=%.3f gain=%.2f",
                         p50, p10, p90, meanSat, meanRb, normGain))

        // —— 场景权重（只做温和的自适应，主旋律是固定曲线）——
        let night = 1.0 - smooth((meanLum - 0.20) / 0.16)
        let bright = smooth((meanLum - 0.50) / 0.28)

        // 曝光：归一化 × 基准 1.05；夜景再亮一点；大白场景略收
        var expo = normGain * (1.05 + night * 0.07 - bright * 0.05)
        let toe = max(0.0, 0.030 - night * 0.012 + bright * 0.004)
        // 饱和度按实测偏差补：目标 0.265 左右
        var sat = 1.06 + (0.265 - meanSat) * 1.20 - bright * 0.03
        sat = clamp(sat, 0.96, 1.34)
        let grain = 0.009 + 0.004 * (1.0 - smooth(meanLum))
        // 暖相（画面偏红偏黄）时轻微补一点饱和度
        let warmBias = clamp(meanRb / 0.05, 0, 1)

        // 固定曲线参数（按 gloam 样片标定）
        let shoulderT = 0.56
        let shMulR = 1.02 + warmBias * 0.01
        let shMulG = 0.98
        let shMulB = 0.94
        let hiMulR = 1.02
        let hiMulG = 1.00
        let hiMulB = 0.96
        let coldConverge = 0.10

        // —— 第二遍：逐像素 ——
        var rng: UInt64 = 72
        i = 0
        while i < n {
            let o = i * 4
            var rf = Double(px[o]) / 255.0
            var gf = Double(px[o + 1]) / 255.0
            var bf = Double(px[o + 2]) / 255.0

            // 饱和度归一
            let gray = 0.299 * rf + 0.587 * gf + 0.114 * bf
            rf = gray + (rf - gray) * sat
            gf = gray + (gf - gray) * sat
            bf = gray + (bf - gray) * sat

            // 冷相（绿/蓝主导）收敛，避免蓝被子那种“跳蓝”
            if gf > rf && gf > bf { gf -= (gf - max(rf, bf)) * coldConverge }
            if bf > rf && bf > gf { bf -= (bf - max(rf, gf)) * coldConverge }

            // 曝光 + 高光肩部（逐通道，天然把高光的冷白压成奶油白）
            rf = shoulder(rf * expo, shoulderT)
            gf = shoulder(gf * expo, shoulderT)
            bf = shoulder(bf * expo, shoulderT)

            var lum = 0.299 * rf + 0.587 * gf + 0.114 * bf
            let sh = 1.0 - smooth(lum / 0.38)
            let hi = smooth((lum - 0.42) / 0.58)

            // 黑位脚部：只压暗部，不动中高光
            let toeAmt = toe * (1.0 - smooth(lum / 0.28))
            rf -= toeAmt; gf -= toeAmt; bf -= toeAmt

            // 暗部偏暖褐 / 高光偏奶油（乘性，不吃掉黑位）
            if sh > 0 {
                rf *= 1.0 + sh * (shMulR - 1.0)
                gf *= 1.0 + sh * (shMulG - 1.0)
                bf *= 1.0 + sh * (shMulB - 1.0)
            }
            if hi > 0 {
                rf *= 1.0 + hi * (hiMulR - 1.0)
                gf *= 1.0 + hi * (hiMulG - 1.0)
                bf *= 1.0 + hi * (hiMulB - 1.0)
            }

            lum = 0.299 * rf + 0.587 * gf + 0.114 * bf

            // 胶片颗粒（暗部更明显）
            let lumGrain = grain * (0.55 + 0.70 * sh)
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n1 = Double(Int(rng >> 33) % 100000) / 100000.0 - 0.5
            rf += n1 * lumGrain
            gf += n1 * lumGrain * 0.96
            bf += n1 * lumGrain * 0.92
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n2 = Double(Int(rng >> 33) % 100000) / 100000.0 - 0.5
            rf += n2 * lumGrain * 0.25
            gf += n2 * lumGrain * 0.25
            bf += n2 * lumGrain * 0.25

            _ = lum
            px[o] = UInt8(clamp(rf, 0, 1) * 255.0 + 0.5)
            px[o + 1] = UInt8(clamp(gf, 0, 1) * 255.0 + 0.5)
            px[o + 2] = UInt8(clamp(bf, 0, 1) * 255.0 + 0.5)
            px[o + 3] = 255
            i += 1
        }
        return true
    }

    /// 高光肩部：t 以下保持线性，t 以上按二次衰减压回，得到胶片式的高光滚落。
    @inline(__always)
    private static func shoulder(_ v: Double, _ t: Double) -> Double {
        if v <= t { return max(0.0, v) }
        let d = v - t
        let y = v - (d * d / (1.0 - t))
        return max(0.0, y)
    }

    // MARK: - 柔焦 + 轻锐化

    private static func softSharpen(_ r: Raster, soft: Double, sharpen: Double) {
        let w = r.width
        let h = r.height
        guard let blur = Raster.make(width: w, height: h) else { return }
        defer { blur.dispose() }
        let src = r.px
        let dst = blur.px

        for y in 0..<h {
            let yUp = max(0, y - 1)
            let yDown = min(h - 1, y + 1)
            for x in 0..<w {
                let xL = max(0, x - 1)
                let xR = min(w - 1, x + 1)
                let o = (y * w + x) * 4
                let oU = (yUp * w + x) * 4
                let oD = (yDown * w + x) * 4
                let oL = (y * w + xL) * 4
                let oR = (y * w + xR) * 4
                dst[o] = UInt8((Int(src[o]) + Int(src[oU]) + Int(src[oD]) + Int(src[oL]) + Int(src[oR])) / 5)
                dst[o + 1] = UInt8((Int(src[o + 1]) + Int(src[oU + 1]) + Int(src[oD + 1]) + Int(src[oL + 1]) + Int(src[oR + 1])) / 5)
                dst[o + 2] = UInt8((Int(src[o + 2]) + Int(src[oU + 2]) + Int(src[oD + 2]) + Int(src[oL + 2]) + Int(src[oR + 2])) / 5)
                dst[o + 3] = 255
            }
        }

        for i in 0..<(w * h) {
            let o = i * 4
            for c in 0..<3 {
                let cr = Double(src[o + c]) / 255.0
                let br = Double(dst[o + c]) / 255.0
                var v = cr * (1 - soft) + br * soft
                v += sharpen * (v - br)
                src[o + c] = UInt8(clamp(v, 0, 1) * 255.0 + 0.5)
            }
            src[o + 3] = 255
        }
    }

    // MARK: - 高光辉光

    private static func bloom(_ r: Raster, threshold: Double, strength: Double) {
        let w = r.width
        let h = r.height
        guard let mask = Raster.make(width: w, height: h),
              let tmp = Raster.make(width: w, height: h) else { return }
        defer { mask.dispose(); tmp.dispose() }

        let src = r.px
        let hiPtr = mask.px
        let denom = max(1e-6, 1.0 - threshold)

        for i in 0..<(w * h) {
            let o = i * 4
            let rf = Double(src[o]) / 255.0
            let gf = Double(src[o + 1]) / 255.0
            let bf = Double(src[o + 2]) / 255.0
            let lum = 0.299 * rf + 0.587 * gf + 0.114 * bf
            let m = clamp(smooth((lum - threshold) / denom), 0, 1)
            hiPtr[o] = UInt8(rf * m * 255.0 + 0.5)
            hiPtr[o + 1] = UInt8(gf * m * 255.0 + 0.5)
            hiPtr[o + 2] = UInt8(bf * m * 255.0 + 0.5)
            hiPtr[o + 3] = 255
        }

        blur5(hiPtr, tmp.px, w, h)
        blur5(tmp.px, hiPtr, w, h)

        for i in 0..<(w * h) {
            let o = i * 4
            let cr = Double(src[o]) / 255.0
            let cg = Double(src[o + 1]) / 255.0
            let cb = Double(src[o + 2]) / 255.0
            let gr = Double(hiPtr[o]) / 255.0
            let gg = Double(hiPtr[o + 1]) / 255.0
            let gb = Double(hiPtr[o + 2]) / 255.0
            src[o] = UInt8(clamp(cr + gr * strength * 1.05, 0, 1) * 255.0 + 0.5)
            src[o + 1] = UInt8(clamp(cg + gg * strength, 0, 1) * 255.0 + 0.5)
            src[o + 2] = UInt8(clamp(cb + gb * strength * 0.9, 0, 1) * 255.0 + 0.5)
            src[o + 3] = 255
        }
    }

    private static func blur5(_ src: UnsafeMutablePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int) {
        for y in 0..<h {
            let yU = max(0, y - 1)
            let yD = min(h - 1, y + 1)
            let row = y * w
            let rowU = yU * w
            let rowD = yD * w
            for x in 0..<w {
                let xL = max(0, x - 1)
                let xR = min(w - 1, x + 1)
                let o = (row + x) * 4
                let oU = (rowU + x) * 4
                let oD = (rowD + x) * 4
                let oL = (row + xL) * 4
                let oR = (row + xR) * 4
                dst[o] = UInt8((Int(src[o]) + Int(src[oU]) + Int(src[oD]) + Int(src[oL]) + Int(src[oR])) / 5)
                dst[o + 1] = UInt8((Int(src[o + 1]) + Int(src[oU + 1]) + Int(src[oD + 1]) + Int(src[oL + 1]) + Int(src[oR + 1])) / 5)
                dst[o + 2] = UInt8((Int(src[o + 2]) + Int(src[oU + 2]) + Int(src[oD + 2]) + Int(src[oL + 2]) + Int(src[oR + 2])) / 5)
                dst[o + 3] = 255
            }
        }
    }

    // MARK: - 暗角

    private static func vignette(_ r: Raster) {
        let w = r.width
        let h = r.height
        let px = r.px
        let cx = Double(w) / 2.0
        let cy = Double(h) / 2.0
        let maxDist = 1.41421356

        for y in 0..<h {
            let ny = abs((Double(y) - cy) / cy)
            let row = y * w
            for x in 0..<w {
                let nx = abs((Double(x) - cx) / cx)
                let d = (nx * nx + ny * ny).squareRoot() / maxDist
                let corner = nx * ny
                let k = clamp(1.0 - d * d * 0.16 - corner * 0.08, 0.80, 1.0)
                let o = (row + x) * 4
                px[o] = UInt8(Double(px[o]) * k + 0.5)
                px[o + 1] = UInt8(Double(px[o + 1]) * k + 0.5)
                px[o + 2] = UInt8(Double(px[o + 2]) * k + 0.5)
            }
        }
    }

    // MARK: - 黑边框

    private static func bordered(_ r: Raster) -> UIImage? {
        let W = r.width
        let H = r.height
        guard W > 16, H > 16, let src = r.makeImage() else { return nil }

        let side = Int((Double(min(W, H)) * 0.013).rounded())
        let topBottom = Int((Double(min(W, H)) * 0.011).rounded())
        let maxW = Double(W - side * 2)
        let maxH = Double(H - topBottom * 2)
        guard maxW > 4, maxH > 4 else { return src }

        guard let out = Raster.make(width: W, height: H), let ctx = out.context() else { return src }
        defer { out.dispose() }

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))

        let scale = min(maxW / Double(W), maxH / Double(H))
        let sw = (Double(W) * scale).rounded()
        let sh = (Double(H) * scale).rounded()
        let dx = ((Double(W) - sw) / 2.0)
        let dyUp = ((Double(H) - sh) / 2.0)
        ctx.interpolationQuality = .high
        ctx.draw(src.cgImage!, in: CGRect(x: dx, y: dyUp, width: sw, height: sh))

        let ix0 = Int(dx)
        let iy0 = Int(Double(H) - dyUp - sh)
        let ix1 = ix0 + Int(sw)
        let iy1 = iy0 + Int(sh)

        let px = out.px
        var rng: UInt64 = 31
        for y in 0..<H {
            let row = y * W
            for x in 0..<W {
                if x >= ix0 && x < ix1 && y >= iy0 && y < iy1 { continue }
                let innerDist = min(
                    min(abs(x - ix0), abs(x - (ix1 - 1))),
                    min(abs(y - iy0), abs(y - (iy1 - 1)))
                )
                let corner = min(min(x, y), min(W - 1 - x, H - 1 - y))
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                var v = Int(rng >> 33) % 11
                if innerDist <= 2 { v = 10 + Int((rng >> 20) % 10) }
                if corner <= side / 2 { v = 0 }
                let o = (row + x) * 4
                px[o] = UInt8(v); px[o + 1] = UInt8(v); px[o + 2] = UInt8(v); px[o + 3] = 255
            }
        }
        return out.makeImage() ?? src
    }

    // MARK: - 工具

    @inline(__always)
    private static func smooth(_ x: Double) -> Double {
        let t = clamp(x, 0, 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v < lo ? lo : (v > hi ? hi : v)
    }

    /// 直方图分位（hist 为 256 桶亮度分布）
    private static func percentile(_ hist: [Int], _ p: Double, _ total: Double) -> Double {
        let need = total * p
        var acc = 0.0
        for k in 0..<256 {
            acc += Double(hist[k])
            if acc >= need { return Double(k) / 255.0 }
        }
        return 1.0
    }
}
