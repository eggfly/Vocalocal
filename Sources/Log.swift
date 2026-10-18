import Foundation

/// 写到 ~/Library/Logs/Vocalocal.log，方便远程排查（tail -f 即可）
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Vocalocal.log")
    private static let queue = DispatchQueue(label: "vocalocal.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        NSLog("Vocalocal: \(message)")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
