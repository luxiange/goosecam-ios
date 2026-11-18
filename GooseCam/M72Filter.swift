import UIKit
import CoreGraphics
import CoreImage

/// Gloam M72 风格（v0.50 全新内核，推倒重来）。
///
/// 设计依据：对 gloam 官方样片 + 用户实拍样片（共 17 张）做定量分析后归纳出的“中画幅负片”特征：
///   1) 中调稳、反差柔：中位亮度落在 0.40~0.46，高光从 0.66 起用 2.4 次幂平滑滚落（奶油白），
///      暗部保留密度不再硬压黑；
///   2) 饱和度软膝：低饱和几乎不动，浓色按二次衰减收回来（最高约 0.55，不会数码味直冲）；
///   3) 色相微旋：黄绿/绿向青绿偏 8°，蓝向青偏 -4°，红橙略加饱和（M72 的红是暖砖红）；
///   4) 分区偏色：高光暖奶油（R+2%/B-1.4%），暗部极轻的冷中性（B+1%/R-0.6%）；
///   5) 润：高光辉光（半径约画面 0.3%）+ 中高频反差轻微收敛 + 细颗粒（亮部更弱）；
///   6) 轻暗角 + 黑边框。
///
/// RAW 侧：CIRAWFilter 关掉 Apple 的局部色调映射/锐化/降噪，在 sRGB 工作与输出空间里渲染，
/// 拿到的是“干净、线性、未被系统拉亮”的底子，再由本内核塑形。
enum M72Filter {

    private static let targetRatio = 4.0 / 5.0
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - 对外流水线

    /// 拍照：4:5 居中裁切 → M72 内核 → 黑边框
    static func processPhoto(_ image: UIImage, debugSave: Bool = false) -> UIImage? {
        guard let raster = rasterize(image, cropTo45: true, standardSize: nil) else { return nil }
        defer { raster.dispose() }
        if debugSave { dumpDebug(raster) }
        guard process(raster) else { return nil }
        return bordered(raster)
    }

    /// 导入：4:5 居中裁切 → 标准化分辨率 → M72 内核 → 黑边框
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

        guard process(work) else { return nil }
        return bordered(work)
    }

    /// 完整塑形链路（顺序有讲究：先定调，再上色，再润，最后颗粒/暗角）
    @discardableResult
    private static func process(_ r: Raster) -> Bool {
        let s = measure(r)
        guard tone(r, s) else { return false }
        color(r, s)
        halo(r)
        micro(r)
        grain(r, s)
        vignette(r)
        return true
    }

    private static func dumpDebug(_ r: Raster) {
        guard let img = r.makeImage(), let data = img.jpegData(compressionQuality: 0.9) else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("goosecam/debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pre.jpg")
        try? data.write(to: url)
        Diag.mark("debug.pre saved \(r.width)x\(r.height)")
    }

    // MARK: - 位图容器

    /// RGBA8 位图（alpha 恒 255），行序自上而下。
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

    /// 取“摆正”的 CGImage：UIImage 带 EXIF 方向（竖拍通常 .right）时，cgImage 是横向原始像素，
    /// 先按方向重绘成 .up，后续裁剪与调色都在正立像素上做。
    private static func cgImage(of image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
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

    /// Bayer RAW（DNG）解码。
    /// 关键点：CIRAWFilter 里把 Apple 的自动局部色调映射、锐化、降噪全部关掉，
    /// 并在 sRGB 的工作/输出色彩空间里渲染——否则 createCGImage 会按扩展线性空间输出，
    /// 画面就会整体“发白、发灰、泛亮”，这就是 0.41 泛白的根因之一。
    static func developRaw(_ data: Data) -> UIImage? {
        var ci: CIImage?
        if let filter = CIRAWFilter(imageData: data) {
            filter.isLensCorrectionEnabled = true
            filter.isGamutMappingEnabled = true
            filter.isHighlightRecoveryEnabled = true
            if filter.isLocalToneMapSupported { filter.isLocalToneMapEnabled = false }
            if filter.isNoiseReductionSupported { filter.isNoiseReductionEnabled = false }
            if filter.isSharpnessSupported { filter.isSharpnessEnabled = false }
            filter.isDraftModeEnabled = false
            ci = filter.outputImage
            Diag.mark("raw.cirawfilter ok")
        }
        if ci == nil {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("goose_\(UUID().uuidString).dng")
            if (try? data.write(to: tmp)) != nil {
                ci = CIImage(contentsOf: tmp, options: [.applyOrientationProperty: true])
                try? FileManager.default.removeItem(at: tmp)
            }
            Diag.mark("raw.decode fallback ciimage")
        }
        guard let image = ci else {
            Diag.mark("raw.decode FAILED")
            return nil
        }

        let extent = image.extent
        guard extent.width > 16, extent.height > 16 else {
            Diag.mark("raw.extent FAILED \(extent)")
            return nil
        }

        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                                y: -extent.origin.y))
        let ctx = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
        guard let cg = ctx.createCGImage(normalized, from: CGRect(origin: .zero, size: extent.size)) else {
            Diag.mark("raw.render FAILED")
            return nil
        }
        Diag.mark("raw.render ok \(Int(extent.width))x\(Int(extent.height))")
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

    // MARK: - 统计

    struct Stats {
        var p1: Double
        var p2: Double
        var p5: Double
        var p10: Double
        var p50: Double
        var p90: Double
        var p95: Double
        var p99: Double
        var meanLum: Double
        var satMean: Double
        var rbMean: Double
    }

    private static func measure(_ r: Raster) -> Stats {
        let w = r.width
        let h = r.height
        let px = r.px
        let n = w * h
        var hist = [Int](repeating: 0, count: 256)
        var lumSum = 0.0
        var satSum = 0.0
        var rbSum = 0.0

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
        return Stats(
            p1: percentile(hist, 0.01, total),
            p2: percentile(hist, 0.02, total),
            p5: percentile(hist, 0.05, total),
            p10: percentile(hist, 0.10, total),
            p50: percentile(hist, 0.50, total),
            p90: percentile(hist, 0.90, total),
            p95: percentile(hist, 0.95, total),
            p99: percentile(hist, 0.99, total),
            meanLum: lumSum / total,
            satMean: satSum / total,
            rbMean: rbSum / total
        )
    }

    // MARK: - 1) 定调（曝光锚定 + 胶片曲线）

    /// 中位亮度锚到 0.44，黑位锚到 0.022，再走一条“中调柔、高光奶油”的曲线。
    /// 用中位数而不是均值/固定系数，是为了让不同光线、不同机型底子都能落在同一条曲线上。
    @discardableResult
    private static func tone(_ r: Raster, _ s: Stats) -> Bool {
        let px = r.px
        let n = r.width * r.height

        let gain = clamp(0.44 / max(s.p50, 0.06), 0.45, 2.20)
        let blackAfterGain = s.p2 * gain
        let lift = clamp(0.022 - blackAfterGain, -0.030, 0.050)
        // 高光起点随底子略微移动，保证爆掉的高光也能被收住
        let shoulderT = clamp(0.66 - max(0.0, (s.p95 - 0.86)) * 0.35, 0.50, 0.72)

        var i = 0
        while i < n {
            let o = i * 4
            var rf = Double(px[o]) / 255.0 * gain + lift
            var gf = Double(px[o + 1]) / 255.0 * gain + lift
            var bf = Double(px[o + 2]) / 255.0 * gain + lift

            rf = film(rf, shoulderT)
            gf = film(gf, shoulderT)
            bf = film(bf, shoulderT)

            px[o] = UInt8(clamp(rf, 0, 1) * 255.0 + 0.5)
            px[o + 1] = UInt8(clamp(gf, 0, 1) * 255.0 + 0.5)
            px[o + 2] = UInt8(clamp(bf, 0, 1) * 255.0 + 0.5)
            px[o + 3] = 255
            i += 1
        }
        Diag.mark(String(format: "tone gain=%.2f lift=%.3f shoulder=%.2f median=%.3f p95=%.3f",
                         gain, lift, shoulderT, s.p50, s.p95))
        return true
    }

    /// 单通道胶片曲线：
    ///  - 中调轻微加对比（围绕 0.46，向两端收敛，所以不会把暗部和高光压硬）
    ///  - 高光从 shoulderT 起用 2.4 次幂平滑滚落，最亮仍可到 1.0（保留高光点）
    ///  - 极暗处留一点密度（film base），不发死
    @inline(__always)
    private static func film(_ x: Double, _ shoulderT: Double) -> Double {
        var v = clamp(x, 0, 1)
        // 中调柔对比
        let pivot = 0.46
        let d = v - pivot
        v = pivot + d * (1.0 + 0.10 * (1.0 - min(1.0, abs(d) / 0.58)))
        // 高光肩部
        if v > shoulderT {
            let u = min(1.0, (v - shoulderT) / (1.0 - shoulderT))
            v = shoulderT + (1.0 - shoulderT) * (1.0 - pow(1.0 - u, 2.4))
        }
        return clamp(v, 0, 1)
    }

    // MARK: - 2) 上色（饱和度软膝 + 色相微旋 + 分区偏色）

    private static func color(_ r: Raster, _ s: Stats) {
        let px = r.px
        let n = r.width * r.height

        // 场景自适应只做很小的修正：整体越暗，饱和度补偿越轻（夜景不要把噪色炒出来）
        let satScale = clamp(0.92 + (0.44 - s.satMean) * 0.45, 0.86, 1.10)
        let warm = clamp(s.rbMean / 0.06, 0, 1)

        var i = 0
        while i < n {
            let o = i * 4
            let rf = Double(px[o]) / 255.0
            let gf = Double(px[o + 1]) / 255.0
            let bf = Double(px[o + 2]) / 255.0

            let Y = 0.299 * rf + 0.587 * gf + 0.114 * bf
            let mx = max(rf, max(gf, bf))
            let mn = min(rf, min(gf, bf))
            let S = mx > 1e-6 ? (mx - mn) / mx : 0

            // —— 饱和度软膝：0.26 以下不动，以上按二次衰减收回
            let knee = 0.26
            var targetS = S
            if S > knee {
                let t = (S - knee) / max(1e-6, 1.0 - knee)
                targetS = S - 0.55 * t * t * (1.0 - knee)
            }
            targetS *= satScale

            // —— 色相判断（HSV 色相），按色带做增益与旋转
            var hDeg = 0.0
            var hasHue = false
            let d = mx - mn
            if d > 1e-5 {
                hasHue = true
                if mx == rf {
                    hDeg = 60.0 * (((gf - bf) / d).truncatingRemainder(dividingBy: 6.0))
                    if hDeg < 0 { hDeg += 360.0 }
                } else if mx == gf {
                    hDeg = 60.0 * ((bf - rf) / d) + 120.0
                } else {
                    hDeg = 60.0 * ((rf - gf) / d) + 240.0
                }
            }

            var hueSat = 1.0
            var hueRot = 0.0
            if hasHue {
                switch hDeg {
                case 30..<75:      // 黄
                    hueSat = 0.95; hueRot = 3.0
                case 75..<165:     // 绿 → 青绿
                    hueSat = 0.88; hueRot = 8.0
                case 165..<250:    // 青蓝
                    hueSat = 0.94; hueRot = -4.0
                case 250..<300:    // 紫
                    hueSat = 0.92; hueRot = 2.0
                default:           // 红/橙/品红：略提，M72 的红是暖砖红
                    hueSat = 1.02 + warm * 0.02; hueRot = -2.0
                }
            }

            // 应用饱和度：围绕亮度 Y 缩放色度
            let m = S > 1e-6 ? (targetS / S) * hueSat : 1.0
            var cr = Y + (rf - Y) * m
            var cg2 = Y + (gf - Y) * m
            var cb = Y + (bf - Y) * m

            // 色相微旋（在 Cb/Cr 平面旋转，等价于绕灰轴的色相旋转）
            if hasHue && abs(hueRot) > 0.01 {
                let Cb = (cb - Y) * 0.564
                let Cr = (cr - Y) * 0.713
                let rad = hueRot * Double.pi / 180.0
                let co = cos(rad), si = sin(rad)
                let Cb2 = Cb * co - Cr * si
                let Cr2 = Cr * co + Cb * si
                cr = Y + Cr2 / 0.713
                cb = Y + Cb2 / 0.564
            }

            // —— 分区偏色
            let hi = smooth((Y - 0.60) / 0.40)
            let sh = 1.0 - smooth(Y / 0.30)
            cr *= 1.0 + 0.020 * hi - 0.006 * sh
            cg2 *= 1.0 + 0.008 * hi + 0.002 * sh
            cb *= 1.0 - 0.014 * hi + 0.010 * sh

            px[o] = UInt8(clamp(cr, 0, 1) * 255.0 + 0.5)
            px[o + 1] = UInt8(clamp(cg2, 0, 1) * 255.0 + 0.5)
            px[o + 2] = UInt8(clamp(cb, 0, 1) * 255.0 + 0.5)
            px[o + 3] = 255
            i += 1
        }
    }

    // MARK: - 3) 润：高光辉光 / 中高频收敛

    private static func halo(_ r: Raster) {
        let w = r.width
        let h = r.height
        guard let mask = Raster.make(width: w, height: h),
              let blur = Raster.make(width: w, height: h) else { return }
        defer { mask.dispose(); blur.dispose() }

        let src = r.px
        let mp = mask.px
        let bp = blur.px
        let threshold = 0.70
        let denom = max(1e-6, 1.0 - threshold)

        var i = 0
        let n = w * h
        while i < n {
            let o = i * 4
            let rf = Double(src[o]) / 255.0
            let gf = Double(src[o + 1]) / 255.0
            let bf = Double(src[o + 2]) / 255.0
            let lum = 0.299 * rf + 0.587 * gf + 0.114 * bf
            let m = clamp(smooth((lum - threshold) / denom), 0, 1)
            mp[o] = UInt8(rf * m * 255.0 + 0.5)
            mp[o + 1] = UInt8(gf * m * 255.0 + 0.5)
            mp[o + 2] = UInt8(bf * m * 255.0 + 0.5)
            mp[o + 3] = 255
            i += 1
        }

        // 半径跟着画面尺寸走：约短边 0.30%，3 次盒式模糊近似高斯；结果始终落在 mask 上
        let radius = max(2, Int((Double(min(w, h)) * 0.0030).rounded()))
        boxBlur(mp, bp, w, h, radius)
        boxBlur(mp, bp, w, h, radius)
        boxBlur(mp, bp, w, h, radius)

        let strength = 0.13
        i = 0
        while i < n {
            let o = i * 4
            let cr = Double(src[o]) / 255.0
            let cg = Double(src[o + 1]) / 255.0
            let cb = Double(src[o + 2]) / 255.0
            // 高光辉光偏暖（胶片 halation 的红晕），蓝通道最少
            let hr = Double(mp[o]) / 255.0
            let hg = Double(mp[o + 1]) / 255.0
            let hb = Double(mp[o + 2]) / 255.0
            src[o] = UInt8(clamp(cr + hr * strength * 1.15, 0, 1) * 255.0 + 0.5)
            src[o + 1] = UInt8(clamp(cg + hg * strength * 1.00, 0, 1) * 255.0 + 0.5)
            src[o + 2] = UInt8(clamp(cb + hb * strength * 0.80, 0, 1) * 255.0 + 0.5)
            src[o + 3] = 255
            i += 1
        }
    }

    /// 中高频轻微收敛（“润”的关键）：把 1px 附近的细节能量收回一点，但不整体糊。
    private static func micro(_ r: Raster) {
        let w = r.width
        let h = r.height
        guard let tmp = Raster.make(width: w, height: h) else { return }
        defer { tmp.dispose() }
        blur5(r.px, tmp.px, w, h)

        let src = r.px
        let tp = tmp.px
        let soft = 0.16
        var i = 0
        let n = w * h
        while i < n {
            let o = i * 4
            for c in 0..<3 {
                let a = Double(src[o + c]) / 255.0
                let b = Double(tp[o + c]) / 255.0
                var v = a * (1.0 - soft) + b * soft
                // 之后补一点点边缘清晰度，避免糊成一片
                v += 0.07 * (v - b)
                src[o + c] = UInt8(clamp(v, 0, 1) * 255.0 + 0.5)
            }
            src[o + 3] = 255
            i += 1
        }
    }

    // MARK: - 4) 颗粒与暗角

    private static func grain(_ r: Raster, _ s: Stats) {
        let px = r.px
        let n = r.width * r.height
        // 亮部颗粒更弱（负片在高光更细腻），暗部稍强
        let amp = 0.020 * (1.0 - 0.55 * smooth((s.p50 - 0.30) / 0.45))
        var rng: UInt64 = 72

        var i = 0
        while i < n {
            let o = i * 4
            let rf = Double(px[o]) / 255.0
            let gf = Double(px[o + 1]) / 255.0
            let bf = Double(px[o + 2]) / 255.0
            let lum = 0.299 * rf + 0.587 * gf + 0.114 * bf
            let local = amp * (1.0 - 0.45 * smooth((lum - 0.55) / 0.45))
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n1 = Double(Int(rng >> 33) % 100000) / 100000.0 - 0.5
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n2 = Double(Int(rng >> 33) % 100000) / 100000.0 - 0.5
            px[o] = UInt8(clamp(rf + n1 * local, 0, 1) * 255.0 + 0.5)
            px[o + 1] = UInt8(clamp(gf + n1 * local * 0.97 + n2 * local * 0.12, 0, 1) * 255.0 + 0.5)
            px[o + 2] = UInt8(clamp(bf + n1 * local * 0.94 + n2 * local * 0.20, 0, 1) * 255.0 + 0.5)
            px[o + 3] = 255
            i += 1
        }
    }

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
                let k = clamp(1.0 - d * d * 0.10 - corner * 0.05, 0.86, 1.0)
                let o = (row + x) * 4
                px[o] = UInt8(Double(px[o]) * k + 0.5)
                px[o + 1] = UInt8(Double(px[o + 1]) * k + 0.5)
                px[o + 2] = UInt8(Double(px[o + 2]) * k + 0.5)
            }
        }
    }

    // MARK: - 模糊

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

    /// 可分离盒式模糊（O(N)），用于大半径辉光。
    private static func boxBlur(_ src: UnsafeMutablePointer<UInt8>,
                                _ dst: UnsafeMutablePointer<UInt8>,
                                _ w: Int, _ h: Int, _ radius: Int) {
        let r = max(1, radius)
        let win = 2 * r + 1
        // 横向
        for y in 0..<h {
            let row = y * w
            var sumR = 0, sumG = 0, sumB = 0
            for k in -r...r {
                let x = min(w - 1, max(0, k))
                let o = (row + x) * 4
                sumR += Int(src[o]); sumG += Int(src[o + 1]); sumB += Int(src[o + 2])
            }
            for x in 0..<w {
                let o = (row + x) * 4
                dst[o] = UInt8(sumR / win)
                dst[o + 1] = UInt8(sumG / win)
                dst[o + 2] = UInt8(sumB / win)
                dst[o + 3] = 255
                let xOut = min(w - 1, max(0, x - r))
                let xIn = min(w - 1, max(0, x + r + 1))
                let oo = (row + xOut) * 4
                let oi = (row + xIn) * 4
                sumR += Int(src[oi]) - Int(src[oo])
                sumG += Int(src[oi + 1]) - Int(src[oo + 1])
                sumB += Int(src[oi + 2]) - Int(src[oo + 2])
            }
        }
        // 纵向（读 dst，写 src 的临时？这里直接读 dst 写 dst 会污染，改用逐列缓冲）
        var col = [Int](repeating: 0, count: 3)
        let rows = h
        for x in 0..<w {
            var sumR = 0, sumG = 0, sumB = 0
            for k in -r...r {
                let y = min(h - 1, max(0, k))
                let o = (y * w + x) * 4
                sumR += Int(dst[o]); sumG += Int(dst[o + 1]); sumB += Int(dst[o + 2])
            }
            for y in 0..<rows {
                let o = (y * w + x) * 4
                col[0] = sumR / win; col[1] = sumG / win; col[2] = sumB / win
                src[o] = UInt8(col[0]); src[o + 1] = UInt8(col[1]); src[o + 2] = UInt8(col[2]); src[o + 3] = 255
                let yOut = min(h - 1, max(0, y - r))
                let yIn = min(h - 1, max(0, y + r + 1))
                let oo = (yOut * w + x) * 4
                let oi = (yIn * w + x) * 4
                sumR += Int(dst[oi]) - Int(dst[oo])
                sumG += Int(dst[oi + 1]) - Int(dst[oo + 1])
                sumB += Int(dst[oi + 2]) - Int(dst[oo + 2])
            }
        }
    }

    // MARK: - 黑边框

    private static func bordered(_ r: Raster) -> UIImage? {
        let W = r.width
        let H = r.height
        guard W > 16, H > 16, let src = r.makeImage() else { return nil }

        let side = Int((Double(min(W, H)) * 0.011).rounded())
        let topBottom = Int((Double(min(W, H)) * 0.009).rounded())
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
