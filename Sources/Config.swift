import Foundation

/// 所有配置存放在 ~/.config/vocalocal/config.json（权限 0600），可以直接手动编辑。
/// 没有用 Keychain：ad-hoc 签名每次重新编译后都会触发 Keychain 授权弹窗。
struct Config: Codable, Equatable {
    // 语音识别（ASR）
    var asrProvider: String = "local"           // "local"（本地 Qwen3-ASR）/ "openai"（OpenAI 兼容）/ "apple-new" / "apple"
    var localASRURL: String = "http://127.0.0.1:8765/v1"
    var asrBaseURL: String = "https://api.groq.com/openai/v1"
    var asrAPIKey: String = ""
    var asrModel: String = "whisper-large-v3"
    var asrLanguage: String = "zh"              // 留空表示自动检测；Apple 识别使用 zh-CN / en-US 这类 locale

    // 纠错：本地 Qwen3-Omni 听录音后只改听错的词（server/correct_server.py）。
    // 默认关闭：常驻约 21 GB 内存；在真实录音上，带发音校验后能保留的有效修改不多，
    // 主要收益（专有名词、语气词、格式）已由屏幕热词和 TextCleanup 规则覆盖
    var correctorEnabled: Bool = false
    var correctorURL: String = "http://127.0.0.1:8766/v1"

    // LLM（ollama）：用于“选中文字后语音改写”
    var llmEnabled: Bool = true
    var llmPolish: Bool = false                 // 是否也用 LLM 整理每次口述的文字（会改写，默认关闭）
    var llmBaseURL: String = "http://127.0.0.1:11434/v1"   // 本地 ollama；也可以换成 DeepSeek 等云端服务
    var llmAPIKey: String = ""
    var llmModel: String = "qwen2.5:7b"

    // 行为
    var vocabulary: String = "Fn, Vocalocal, ASR, LLM, Typeless, Qwen3, DeepSeek, Ollama, Python, Swift, MLX, macOS, GitHub, Claude, API, JSON, PR, CI, main, try catch"  // 逗号或换行分隔
    var insertMode: String = "paste"            // "paste"（剪贴板 + ⌘V）或 "type"（模拟键入 Unicode）
    var restoreClipboard: Bool = true
    var editSelection: Bool = true              // 有选中文字时，把语音当作改写指令
    var noiseSuppression: Bool = true           // 系统级降噪 / 回声消除
    var useFieldContext: Bool = true            // 把输入框已有内容作为识别和润色的上下文
    var saveRecordings: Bool = true             // 每次录音保存到 Application Support/Vocalocal/recordings，用于评测

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vocalocal/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        // 先按默认值解码，这样新版本加的字段不会让旧配置文件解析失败
        let decoder = JSONDecoder()
        if let cfg = try? decoder.decode(Config.self, from: data) { return cfg }
        guard var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any]
        else { return Config() }
        dict.merge(defaults) { current, _ in current }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict) else { return Config() }
        return (try? decoder.decode(Config.self, from: merged)) ?? Config()
    }

    func save() {
        let url = Config.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var vocabularyList: [String] {
        vocabulary.split(whereSeparator: { ",，\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
