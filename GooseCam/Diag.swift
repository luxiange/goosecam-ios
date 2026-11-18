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

    static var logURL: URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("goosecam", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("diag.log")
    }

    /// 同步写一行（异常处理器里也安全）
    static func writeLine(_ text: String) {
        guard let url = logURL else { return }
        let line = "[\(formatter.string(from: Date()))] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 200_000,
           let content = try? Data(contentsOf: url) {
            try? content.suffix(100_000).write(to: url)
        }
    }

    static func mark(_ text: String) {
        queue.async { writeLine(text) }
    }

    static func installExceptionLogger() {
        NSSetUncaughtExceptionHandler(goosecamUncaughtHandler)
    }
}

/// 必须是全局函数：闭包捕获上下文时无法转成 C 函数指针
private func goosecamUncaughtHandler(_ exception: NSException) {
    let symbols = exception.callStackSymbols.prefix(12).joined(separator: " | ")
    Diag.writeLine("UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "-") \(symbols)")
}
