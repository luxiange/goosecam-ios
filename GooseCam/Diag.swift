import Foundation

/// 轻量诊断日志：写入沙盒 Documents/goosecam/diag.log。
/// 真机上若再出现闪退，可在「文件」App → 我的 iPhone → 鹅相机 里读到崩溃前最后一步。
enum Diag {
    private static let queue = DispatchQueue(label: "goosecam.diag")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static var fileURL: URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("goosecam", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("diag.log")
    }

    static func mark(_ text: String) {
        queue.async {
            guard let url = fileURL else { return }
            let line = "[\(formatter.string(from: Date()))] \(text)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
            // 只保留最近约 100KB
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 200_000,
               let content = try? Data(contentsOf: url) {
                try? content.suffix(100_000).write(to: url)
            }
        }
    }

    static func installExceptionLogger() {
        NSSetUncaughtExceptionHandler { exception in
            let symbols = exception.callStackSymbols.prefix(12).joined(separator: " | ")
            mark("UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "-") \(symbols)")
        }
    }
}
