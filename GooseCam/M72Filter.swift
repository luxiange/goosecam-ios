import UIKit

/// Gloam M72 风格处理（与安卓 M72Filter.kt 逐条对齐）：
/// 暖柔奶金高光、轻微冷灰蓝阴影、低饱和、柔和对比、轻微胶片颗粒与自然暗角；
/// 输出 4:5 画面并叠加四周纯黑细边框（上下略宽）。
enum M72Filter {

    private static let targetRatio: CGFloat = 4.0 / 5.0

    // MARK: - 对外流水线

    /// 拍照：4:5 居中裁切 → M72 调色 → 黑边框
    static func processPhoto(_ image: UIImage) -> UIImage? {
        let up = normalized(image)
        let cropped = cropTo4x5(up)
        let graded = applyM72(cropped)
        return addBlackBorder(graded)
    }

    /// 导入：4:5 居中裁切（横图 5:4）→ 标准化分辨率 → M72 调色 → 黑边框
    static func processImport(_ image: UIImage) -> UIImage? {
        let up = normalized(image)
        let cropped = cropTo4x5(up)
        let standard = standardize(cropped)
        let graded = applyM72(standard)
        return addBlackBorder(graded)
    }

    // MARK: - 几何

    /// 统一成 .up + scale 1 的位图，抹平 EXIF 方向差异。
    static func normalized(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        if image.imageOrientation == .up && image.scale == 1 {
            return image
        }
        let size = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 居中裁切：竖图 4:5，横图 5:4（横拍出横版）。
    static func cropTo4x5(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w0 = CGFloat(cg.width)
        let h0 = CGFloat(cg.height)
        guard w0 > 1, h0 > 1 else { return image }

        let landscape = w0 > h0
        let target: CGFloat = landscape ? (1.0 / targetRatio) : targetRatio
        let ratio = w0 / h0

        var w = w0
        var h = h0
        if ratio > target {
            w = (h0 * target).rounded()
        } else {
            h = (w0 / target).rounded()
        }
        w = min(w, w0)
        h = min(h, h0)

        let x = ((w0 - w) / 2).rounded()
        let y = ((h0 - h) / 2).rounded()
        guard let cut = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return image }
        return UIImage(cgImage: cut, scale: 1, orientation: .up)
    }

    /// 导入图标准化：竖图/方形 3072×3840，横图 3840×3072。
    static func standardize(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let landscape = cg.width > cg.height
        let target = landscape ? CGSize(width: 3840, height: 3072) : CGSize(width: 3072, height: 3840)
        if cg.width == Int(target.width) && cg.height == Int(target.height) {
            return image
        }
        return resize(image, to: target)
    }

    static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 调色

    /// 逐像素 M72 调色（两遍式：先统计场景，再按场景自适应调整，末段叠暗角）。
    static func applyM72(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = cg.width
        let h = cg.height
        guard w > 1, h > 1 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)

        return renderer.image { ctx in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let raw = ctx.cgContext.data else { return }
            let px = raw.assumingMemoryBound(to: UInt8.self)
            let count = w * h

            // —— 第一遍：统计亮度、饱和、色温、反差 ——
            var lumSum: Float = 0
            var satSum: Float = 0
            var rbSum: Float = 0
            var hist = [Int](repeating: 0, count: 256)

            var i = 0
            while i < count {
                let o = i * 4
                let r = Float(px[o]) / 255.0
                let g = Float(px[o + 1]) / 255.0
                let b = Float(px[o + 2]) / 255.0
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                lumSum += lum
                let mx = max(r, max(g, b))
                let mn = min(r, min(g, b))
                satSum += mx > 1e-6 ? (mx - mn) / mx : 0
                rbSum += r - b
                let bin = Int((lum * 255.0).rounded())
                hist[min(255, max(0, bin))] += 1
                i += 1
            }

            let total = Float(count)
            let meanLum = lumSum / total
            let meanSat = satSum / total
            let meanRb = rbSum / total

            // 灰度直方图取 P10 / P90 衡量反差
            var acc = 0
            var p10: Float = 0
            for k in 0..<256 {
                acc += hist[k]
                if Float(acc) >= total * 0.10 {
                    p10 = Float(k) / 255.0
                    break
                }
            }
            acc = 0
            var p90: Float = 1
            for k in 0..<256 {
                acc += hist[k]
                if Float(acc) >= total * 0.90 {
                    p90 = Float(k) / 255.0
                    break
                }
            }

            // —— 场景自适应系数 ——
            let expo = clamp(-0.012 - 0.022 * smooth(meanLum), -0.038, 0.006)
            let liftBase = 0.018 + 0.026 * smooth(meanLum)
            let spread = clamp(p90 - p10, 0, 1)
            let contrast = clamp(0.95 + 0.05 * spread, 0.92, 1.04)
            let sat = clamp(1.02 - 0.30 * meanSat, 0.92, 1.06)
            let hiStrength = clamp(0.9 + 0.2 * smooth(meanLum), 0.85, 1.1)
            let warmShift = 0.013 - clamp(meanRb, -0.05, 0.05) * 0.1

            // 暗角参数
            let cx = Float(w) / 2.0
            let cy = Float(h) / 2.0
            let maxDist = (cx * cx + cy * cy).squareRoot()

            var rng: UInt32 = 72
            i = 0
            while i < count {
                let o = i * 4
                var r = Float(px[o]) / 255.0
                var g = Float(px[o + 1]) / 255.0
                var b = Float(px[o + 2]) / 255.0

                // 自适应饱和
                let gray = 0.299 * r + 0.587 * g + 0.114 * b
                r = gray + (r - gray) * sat
                g = gray + (g - gray) * sat
                b = gray + (b - gray) * sat

                // 蓝、绿相轻微收敛，避免天空绿植过艳
                if g > r && g > b {
                    g -= (g - max(r, b)) * 0.16
                }
                if b > r && b > g {
                    b -= (b - max(r, g)) * 0.16
                }

                var lum = 0.299 * r + 0.587 * g + 0.114 * b

                // 自适应对比
                r = 0.5 + (r - 0.5) * contrast
                g = 0.5 + (g - 0.5) * contrast
                b = 0.5 + (b - 0.5) * contrast
                lum = 0.299 * r + 0.587 * g + 0.114 * b

                // 自适应整体曝光偏移
                r += expo
                g += expo
                b += expo

                // 自适应暗部抬起
                let shadowLift = (1.0 - smooth(lum / 0.35)) * liftBase
                r += shadowLift
                g += shadowLift
                b += shadowLift

                // 暖白平衡
                r += warmShift
                g += warmShift * 0.4
                b -= 0.014

                // 暖部加暖金，阴影一点冷灰蓝
                let warm = smooth(lum)
                let cool = 1.0 - smooth(1.0 - lum)
                r += warm * 0.042
                g += warm * 0.016
                b -= warm * 0.024
                b += cool * 0.030
                g += cool * 0.006

                // 肤色/肉/木等暖中间调轻提亮暖金
                if r > g && g > b && lum > 0.28 && lum < 0.75 {
                    r += 0.016
                    g += 0.010
                    b += 0.004
                }

                // 高光：先压回过亮，再叠暖柔白
                let hi = smooth((lum - 0.60) / 0.40)
                let over = smooth((lum - 0.78) / 0.22)
                r -= over * 0.030
                g -= over * 0.022
                b -= over * 0.012
                r += hi * 0.018 * hiStrength
                g += hi * 0.010 * hiStrength
                b -= hi * 0.010

                // 轻胶片颗粒，暗部略重
                let grainAmt = 0.010 + 0.010 * (1.0 - lum)
                rng = rng &* 1664525 &+ 1013904223
                let randValue = Float(rng % 100000) / 100000.0
                let grain = (randValue - 0.5) * grainAmt
                r += grain
                g += grain
                b += grain

                // 自然暗角
                let x = Float(i % w)
                let y = Float(i / w)
                let dx = x - cx
                let dy = y - cy
                let dist = (dx * dx + dy * dy).squareRoot() / maxDist
                let k = clamp(1.0 - dist * dist * 0.14, 0.86, 1.0)
                r *= k
                g *= k
                b *= k

                px[o] = UInt8(min(255, max(0, (r * 255).rounded())))
                px[o + 1] = UInt8(min(255, max(0, (g * 255).rounded())))
                px[o + 2] = UInt8(min(255, max(0, (b * 255).rounded())))
                px[o + 3] = 255
                i += 1
            }
        }
    }

    // MARK: - 边框

    /// 窄直边胶片质感黑边框：边缘深浅轻微不均、四角略深。画布保持原比例。
    static func addBlackBorder(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let W = cg.width
        let H = cg.height
        guard W > 8, H > 8 else { return image }

        let side = Int((Float(min(W, H)) * 0.013).rounded())
        let topBottom = Int((Float(min(W, H)) * 0.011).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: format)

        return renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))

            let maxW = CGFloat(W - side * 2)
            let maxH = CGFloat(H - topBottom * 2)
            let scale = min(maxW / CGFloat(cg.width), maxH / CGFloat(cg.height))
            let sw = (CGFloat(cg.width) * scale).rounded()
            let sh = (CGFloat(cg.height) * scale).rounded()
            let dx = ((CGFloat(W) - sw) / 2)
            let dy = ((CGFloat(H) - sh) / 2)
            image.draw(in: CGRect(x: dx, y: dy, width: sw, height: sh))

            guard let raw = ctx.cgContext.data else { return }
            let px = raw.assumingMemoryBound(to: UInt8.self)
            let ix0 = Int(dx)
            let iy0 = Int(dy)
            let ix1 = ix0 + Int(sw)
            let iy1 = iy0 + Int(sh)
            var rng: UInt32 = 31

            for y in 0..<H {
                for x in 0..<W {
                    if x >= ix0 && x < ix1 && y >= iy0 && y < iy1 { continue }
                    let innerDist = min(
                        min(abs(x - ix0), abs(x - (ix1 - 1))),
                        min(abs(y - iy0), abs(y - (iy1 - 1)))
                    )
                    let corner = min(min(x, y), min(W - 1 - x, H - 1 - y))
                    rng = rng &* 1103515245 &+ 12345
                    var v = Int(rng % 11)
                    if innerDist <= 2 {
                        v = 10 + Int(rng % 10)
                    }
                    if corner <= side / 2 {
                        v = 0
                    }
                    let o = (y * W + x) * 4
                    px[o] = UInt8(v)
                    px[o + 1] = UInt8(v)
                    px[o + 2] = UInt8(v)
                    px[o + 3] = 255
                }
            }
        }
    }

    // MARK: - 工具

    private static func smooth(_ x: Float) -> Float {
        let t = clamp(x, 0, 1)
        return t * t * (3 - 2 * t)
    }

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        min(max(v, lo), hi)
    }
}
