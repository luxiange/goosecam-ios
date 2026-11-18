import UIKit
import CoreGraphics

/// Gloam M72 风格处理（与安卓 0.40 的 M72Filter.kt 逐条对齐）：
/// 暖柔奶金高光、轻微冷灰蓝阴影、低饱和、柔和对比、胶片颗粒、柔焦+轻锐化、
/// 高光辉光与自然暗角；输出 4:5 画面并叠加四周纯黑细边框（上下略宽）。
///
/// 与旧实现的区别：全部在自建的 CGContext 位图上直接操作字节，不再依赖
/// UIGraphicsImageRenderer 的 cgContext.data（该指针在真机上可能为空或格式不符，
/// 是旧版拍照后闪退的直接原因之一）。
enum M72Filter {

    private static let targetRatio = 4.0 / 5.0
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - 对外流水线

    /// 拍照：4:5 居中裁切 → M72 调色 → 黑边框
    static func processPhoto(_ image: UIImage) -> UIImage? {
        guard let raster = rasterize(image, cropTo45: true, standardSize: nil) else { return nil }
        defer { raster.dispose() }
        guard grade(raster) else { return nil }
        softSharpen(raster, soft: 0.06, sharpen: 0.18)
        bloom(raster, threshold: 0.72, strength: 0.10)
        vignette(raster)
        return bordered(raster)
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
        bloom(work, threshold: 0.72, strength: 0.10)
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

    private static func cgImage(of image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        // 少数来源（CIImage 支撑）没有 cgImage，先渲染一遍
        let size = CGSize(width: max(1, image.size.width * image.scale),
                          height: max(1, image.size.height * image.scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
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

    // MARK: - 调色（0.40 算法）

    /// 两遍式：先统计场景亮度/反差/饱和/色温，再按场景权重逐像素处理。
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
        var hiCount = 0
        var loCount = 0
        var hist = [Int](repeating: 0, count: 256)

        var i = 0
        while i < n {
            let o = i * 4
            let rf = Double(px[o]) / 255.0
            let gf = Double(px[o + 1]) / 255.0
            let bf = Double(px[o + 2]) / 255.0
            let lum = 0.299 * rf + 0.587 * gf + 0.114 * bf
            lumSum += lum
            if lum > 0.75 { hiCount += 1 }
            if lum < 0.25 { loCount += 1 }
            let mx = max(rf, max(gf, bf))
            let mn = min(rf, min(gf, bf))
            satSum += mx > 1e-6 ? (mx - mn) / mx : 0
            rbSum += rf - bf
            let bin = Int((lum * 255.0).rounded())
            hist[min(255, max(0, bin))] += 1
            i += 1
        }

        let total = Double(n)
        let meanLum = lumSum / total
        let meanSat = satSum / total
        let meanRb = rbSum / total
        let hiRatio = Double(hiCount) / total
        _ = loCount

        // 灰度直方图 P10 / P90
        var acc = 0
        var p10 = 0.0
        for k in 0..<256 {
            acc += hist[k]
            if Double(acc) >= total * 0.10 { p10 = Double(k) / 255.0; break }
        }
        acc = 0
        var p90 = 1.0
        for k in 0..<256 {
            acc += hist[k]
            if Double(acc) >= total * 0.90 { p90 = Double(k) / 255.0; break }
        }

        // —— 场景权重 ——
        let night = 1.0 - smooth((meanLum - 0.22) / 0.18)
        let warm = smooth(meanRb / 0.06)
        let backlit = smooth((hiRatio - 0.18) / 0.15)

        // —— 自适应系数 ——
        let expo = clamp(-0.002 - 0.018 * smooth(meanLum) + night * 0.022, -0.024, 0.020)
        let liftBase = clamp(0.026 + 0.038 * smooth(meanLum) - night * 0.002, 0.018, 0.064)
        let spread = clamp(p90 - p10, 0, 1)
        let contrast = clamp(0.95 + 0.05 * spread - night * 0.020, 0.90, 1.04)
        let sat = clamp(0.95 - 0.28 * meanSat + warm * 0.008 + night * 0.020, 0.92, 1.03)
        let hiStrength = clamp(0.9 + 0.2 * smooth(meanLum) + backlit * 0.10 - night * 0.10, 0.85, 1.15)
        let warmShift = 0.008 - clamp(meanRb, -0.05, 0.05) * 0.1
        let blueDrop = 0.010 - night * 0.004
        let sceneGrain = 0.008 + 0.006 * (1.0 - smooth(meanLum)) + night * 0.004
        let warmBoost = 0.6 + 0.4 * warm

        // —— 第二遍：逐像素 ——
        var rng: UInt64 = 72
        i = 0
        while i < n {
            let o = i * 4
            var rf = Double(px[o]) / 255.0
            var gf = Double(px[o + 1]) / 255.0
            var bf = Double(px[o + 2]) / 255.0

            // 自适应饱和（全局基准）
            let gray = 0.299 * rf + 0.587 * gf + 0.114 * bf
            rf = gray + (rf - gray) * sat
            gf = gray + (gf - gray) * sat
            bf = gray + (bf - gray) * sat

            // 冷相（绿/蓝）收敛
            if gf > rf && gf > bf { gf -= (gf - max(rf, bf)) * 0.20 }
            if bf > rf && bf > gf { bf -= (bf - max(rf, gf)) * 0.20 }

            // 暖相轻微补回饱和
            if rf > gf && rf > bf {
                let wg = 0.299 * rf + 0.587 * gf + 0.114 * bf
                let warmSat = 1.0 + 0.018 * warm
                rf = wg + (rf - wg) * warmSat
                gf = wg + (gf - wg) * warmSat
            }

            var lum = 0.299 * rf + 0.587 * gf + 0.114 * bf

            // 三段亮度权重
            let shadow = 1.0 - smooth(lum / 0.32)
            let mid = smooth(lum / 0.55) * (1.0 - smooth((lum - 0.45) / 0.35))
            let hi = smooth((lum - 0.55) / 0.45)

            // 自适应对比
            rf = 0.5 + (rf - 0.5) * contrast
            gf = 0.5 + (gf - 0.5) * contrast
            bf = 0.5 + (bf - 0.5) * contrast
            lum = 0.299 * rf + 0.587 * gf + 0.114 * bf
            let lumC = lum

            // 曝光偏移
            rf += expo; gf += expo; bf += expo

            // 阴影抬起
            let shadowLift = shadow * liftBase
            rf += shadowLift; gf += shadowLift; bf += shadowLift

            // 中间调柔暖
            rf += mid * 0.008
            gf += mid * 0.004
            rf += mid * backlit * 0.006

            // 高光非线性压缩
            let over = smooth((lum - 0.72) / 0.28)
            let roll = over * over
            let rollAmt = 1.0 + backlit * 0.35 - night * 0.15
            rf -= roll * 0.035 * rollAmt
            gf -= roll * 0.026 * rollAmt
            bf -= roll * 0.014 * rollAmt

            // 分通道色偏：高光暖金、阴影冷灰青
            rf += hi * 0.034 * hiStrength
            gf += hi * 0.014
            bf -= hi * 0.022
            bf += shadow * 0.028
            gf += shadow * 0.006
            rf -= shadow * 0.006

            // 暖白平衡
            rf += warmShift
            gf += warmShift * 0.4
            bf -= blueDrop

            // 高光叠暖柔白
            rf += hi * 0.010 * hiStrength
            gf += hi * 0.006
            bf -= hi * 0.008

            // 肤色 / 橙黄食物掩膜
            let skinMask = (rf >= gf - 0.02) && rf > bf && (rf - bf) > 0.06 && lumC >= 0.25 && lumC <= 0.78
            let orangeMask = rf > bf && gf > bf && rf > gf * 0.95 && lumC >= 0.30 && lumC <= 0.70
            if skinMask || orangeMask {
                rf += 0.018 * warmBoost
                gf += 0.011 * warmBoost
                bf += 0.005 * warmBoost
            }

            // 胶片颗粒
            let lumGrain = sceneGrain * (0.55 + 0.70 * shadow)
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

            // 白位压缩
            let whiteK = smooth((lumC - 0.86) / 0.14) * (1.0 - night * 0.4)
            if whiteK > 0 {
                rf -= whiteK * max(rf - 0.96, 0) * 0.50
                gf -= whiteK * max(gf - 0.96, 0) * 0.50
                bf -= whiteK * max(bf - 0.96, 0) * 0.60
            }

            // 黑位轻压
            let blackK = shadow * 0.02
            rf *= 1.0 - blackK
            gf *= 1.0 - blackK
            bf *= 1.0 - blackK

            px[o] = UInt8(clamp(rf, 0, 1) * 255.0 + 0.5)
            px[o + 1] = UInt8(clamp(gf, 0, 1) * 255.0 + 0.5)
            px[o + 2] = UInt8(clamp(bf, 0, 1) * 255.0 + 0.5)
            px[o + 3] = 255
            i += 1
        }
        return true
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
                let k = clamp(1.0 - d * d * 0.12 - corner * 0.06, 0.85, 1.0)
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
}
