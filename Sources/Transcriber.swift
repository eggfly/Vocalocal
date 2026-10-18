import AVFoundation
import Foundation
import Speech

enum Transcriber {
    /// context：识别时的上下文（App 名、输入框前文），只有本地 Qwen3-ASR 会用到
    /// hotwords：词汇表 + 屏幕术语，只有本地 Qwen3-ASR 会用到
    static func transcribe(wav: Data, config: Config, context: String = "", hotwords: [String]? = nil) async throws -> String {
        switch config.asrProvider {
        case "apple":
            return try await AppleSpeech.transcribe(wav: wav, language: config.asrLanguage, vocabulary: config.vocabularyList)
        case "apple-new":
            return try await appleNew(wav: wav, config: config)
        case "local":
            do {
                return try await OpenAICompatibleASR.transcribe(wav: wav, config: config, local: true, context: context,
                                                                hotwords: hotwords ?? config.vocabularyList)
            } catch {
                // 本地服务没起来时自动兜底，保证随时能用
                Log.info("local ASR failed (\(error.localizedDescription)), falling back to Apple")
                return try await appleNew(wav: wav, config: config)
            }
        default:
            return try await OpenAICompatibleASR.transcribe(wav: wav, config: config)
        }
    }

    private static func appleNew(wav: Data, config: Config) async throws -> String {
        if #available(macOS 26.0, *) {
            return try await AppleSpeechAnalyzer.transcribe(wav: wav, language: config.asrLanguage, vocabulary: config.vocabularyList)
        }
        return try await AppleSpeech.transcribe(wav: wav, language: config.asrLanguage, vocabulary: config.vocabularyList)
    }
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum HTTP {
    /// 访问本机服务时不走系统代理（Clash 等代理软件有时会把 127.0.0.1 也转发出去）
    static let direct: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg)
    }()

    static func session(for url: URL) -> URLSession {
        let host = url.host ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "::1" ? direct : .shared
    }
}

/// OpenAI 兼容的 /audio/transcriptions 接口。
/// 可用：本地 Qwen3-ASR 服务（server/asr_server.py）、OpenAI（whisper-1 / gpt-4o-transcribe）、
/// Groq（whisper-large-v3），以及其它兼容服务。
enum OpenAICompatibleASR {
    static func transcribe(wav: Data, config: Config, local: Bool = false, context: String = "",
                           hotwords: [String] = []) async throws -> String {
        let baseURL = local ? config.localASRURL : config.asrBaseURL
        guard let url = URL(string: baseURL.trimmingSlash + "/audio/transcriptions") else {
            throw APIError(message: "ASR 地址无效")
        }
        if !local, config.asrAPIKey.isEmpty, HTTP.session(for: url) !== HTTP.direct {
            throw APIError(message: "未设置 ASR API Key")
        }
        let boundary = "vocalocal-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", local ? "qwen3-asr" : config.asrModel)
        field("response_format", "json")
        field("temperature", "0")
        if !config.asrLanguage.isEmpty {
            // Whisper 只接受 ISO-639-1，比如 "zh-CN" 要传 "zh"
            field("language", String(config.asrLanguage.prefix(2)))
        }
        if local {
            // Qwen3-ASR 在识别阶段就使用词汇表和上下文（评测里字错率 3.7% → 1.0%）
            field("hotwords", hotwords.joined(separator: ","))
            if !context.isEmpty { field("context", context) }
        } else {
            // prompt 会影响 Whisper 的用词和标点风格：给简体中文示例能减少繁体输出，词汇表能提高专有名词准确率
            var prompt = "以下是普通话的句子，使用简体中文和标点符号。"
            if !config.vocabularyList.isEmpty { prompt += "词汇：" + config.vocabularyList.joined(separator: "、") + "。" }
            field("prompt", prompt)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url, timeoutInterval: local ? 20 : 60)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !local, !config.asrAPIKey.isEmpty { req.setValue("Bearer \(config.asrAPIKey)", forHTTPHeaderField: "Authorization") }

        let (data, resp) = try await HTTP.session(for: url).upload(for: req, from: body)
        try checkHTTP(resp, data)
        struct R: Decodable { let text: String }
        return try JSONDecoder().decode(R.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func checkHTTP(_ resp: URLResponse, _ data: Data) throws {
    guard let http = resp as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
        let text = String(data: data, encoding: .utf8) ?? ""
        throw APIError(message: "HTTP \(http.statusCode): \(text.prefix(300))")
    }
}

/// macOS 自带的语音识别（免费、无需 Key；中文准确率不如 Whisper 大模型，没有 LLM 时也能用）
enum AppleSpeech {
    static func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    static func localeID(_ language: String) -> String {
        switch language {
        case "", "zh": return "zh-CN"
        case "en": return "en-US"
        default: return language
        }
    }

    static func transcribe(wav: Data, language: String, vocabulary: [String] = []) async throws -> String {
        let localeID = localeID(language)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            throw APIError(message: "系统语音识别不可用（\(localeID)）")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vocalocal-\(UUID().uuidString).wav")
        try wav.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let request = SFSpeechURLRecognitionRequest(url: tmp)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    cont.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

/// macOS 26 起的新一代端侧识别（SpeechAnalyzer + SpeechTranscriber），备忘录 / 语音备忘录的转写用的就是它。
/// 模型由系统按语言下载和管理（AssetInventory），不占 App 体积。
@available(macOS 26.0, *)
enum AppleSpeechAnalyzer {
    static func transcribe(wav: Data, language: String, vocabulary: [String] = []) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vocalocal-\(UUID().uuidString).wav")
        try wav.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try await transcribe(fileURL: tmp, language: language, vocabulary: vocabulary)
    }

    static func transcribe(fileURL: URL, language: String, vocabulary: [String] = []) async throws -> String {
        let wanted = Locale(identifier: AppleSpeech.localeID(language))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw APIError(message: "SpeechTranscriber 不支持 \(wanted.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // 首次使用该语言时由系统下载模型
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let collector = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let file = try AVAudioFile(forReading: fileURL)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
