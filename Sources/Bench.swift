import AppKit

/// 评测模式：Vocalocal.app --args --bench <目录>
/// 读取 <目录>/truth.tsv 和 audio/*.wav，用系统新旧两个识别 API 跑一遍，结果写到 results_apple.jsonl。
/// 放在 App 里跑是因为语音识别权限是授给 Vocalocal.app 的，命令行工具拿不到。
enum Bench {
    static let vocabulary = ["Fn", "ASR", "Typeless", "Qwen3", "DeepSeek", "JSON", "PR", "CI", "main", "try catch", "Vocalocal"]

    @MainActor
    static func run(directory: URL) async {
        let truth = (try? String(contentsOf: directory.appendingPathComponent("truth.tsv"), encoding: .utf8)) ?? ""
        let ids = truth.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }
        let outURL = directory.appendingPathComponent("results_apple.jsonl")
        var lines: [String] = []
        Log.info("bench: \(ids.count) samples in \(directory.path)")

        typealias Engine = (name: String, run: (Data, URL) async throws -> String)
        var engines: [Engine] = [
            ("apple-old/plain", { wav, _ in try await AppleSpeech.transcribe(wav: wav, language: "zh") }),
            ("apple-old/vocab", { wav, _ in try await AppleSpeech.transcribe(wav: wav, language: "zh", vocabulary: vocabulary) }),
        ]
        if #available(macOS 26.0, *) {
            engines.append(("apple-new/plain", { _, url in try await AppleSpeechAnalyzer.transcribe(fileURL: url, language: "zh") }))
            engines.append(("apple-new/vocab", { _, url in
                try await AppleSpeechAnalyzer.transcribe(fileURL: url, language: "zh", vocabulary: vocabulary)
            }))
        }

        for id in ids {
            let url = directory.appendingPathComponent("audio/\(id).wav")
            guard let wav = try? Data(contentsOf: url) else { continue }
            for engine in engines {
                let start = Date()
                var row: [String: Any] = ["engine": engine.name, "id": id]
                do {
                    row["text"] = try await engine.run(wav, url)
                } catch {
                    row["text"] = ""
                    row["error"] = error.localizedDescription
                }
                row["seconds"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
                Log.info("bench \(id) \(engine.name): \(row["text"] ?? "") \(row["error"] ?? "")")
                if let data = try? JSONSerialization.data(withJSONObject: row), let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
        Log.info("bench: done -> \(outURL.path)")
        NSApp.terminate(nil)
    }
}
