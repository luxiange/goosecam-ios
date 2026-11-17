import Foundation
import UIKit
import Photos
import ImageIO

struct PhotoItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let date: Date
}

/// 照片落盘与相册读取。iOS 没有 Pictures/goosecam 这种公共目录，
/// 这里用 App 沙盒 Documents/goosecam（与安卓同名），同时往系统相册写一份。
final class PhotoStore {
    static let shared = PhotoStore()

    let folder: URL
    private let stampFormatter: DateFormatter

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("goosecam", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd_HHmmss"
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
    }

    func list() -> [PhotoItem] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let items: [PhotoItem] = urls.compactMap { url in
            guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
            let date = (try? url.resourceValues(forKeys: keys).contentModificationDate) ?? Date.distantPast
            return PhotoItem(id: url.path, url: url, date: date)
        }
        return items.sorted { $0.date > $1.date }
    }

    @discardableResult
    func save(_ image: UIImage, prefix: String = "M72") -> URL? {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        let name = "\(prefix)_\(stampFormatter.string(from: Date())).jpg"
        var url = folder.appendingPathComponent(name)
        var index = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(prefix)_\(stampFormatter.string(from: Date()))_\(index).jpg")
            index += 1
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        saveToSystemPhotos(data)
        return url
    }

    func delete(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func latestImage(maxPixel: Int) -> UIImage? {
        guard let first = list().first else { return nil }
        return thumbnail(for: first.url, maxPixel: maxPixel)
    }

    /// 抽样解码缩略图，避免整张 4000px 原图进内存。
    func thumbnail(for url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func saveToSystemPhotos(_ data: Data) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let write: (PHAuthorizationStatus) -> Void = { st in
            guard st == .authorized || st == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: nil)
        }
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                write(newStatus)
            }
        } else {
            write(status)
        }
    }
}

/// 缩略图缓存，网格滚动时不重复解码。
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for url: URL, maxPixel: Int) -> UIImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = PhotoStore.shared.thumbnail(for: url, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
