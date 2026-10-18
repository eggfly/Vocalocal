import Foundation

/// 纠错：把录音、识别初稿、屏幕上下文交给本地 Qwen3-Omni（server/correct_server.py），
/// 它只返回 {from, to} 修改列表，这里逐条校验后套用。
/// 评测结论：整句重写会"回答问题"或改写过度；只允许改词以后，这两种问题都不会出现，
/// 同时又能利用模型的听力把 "派送/欧拉玛" 改回 "Python/Ollama"。
enum Corrector {
    struct Fix: Codable { let from: String; let to: String }

    static let fillers: Set<String> = ["呃", "嗯", "啊", "额", "呃呃", "嗯嗯", "啊啊", "um", "uh"]

    static func correct(wav: Data, draft: String, context: String, hotwords: [String], config: Config) async throws -> [Fix] {
        guard let url = URL(string: config.correctorURL.trimmingSlash + "/correct") else {
            throw APIError(message: "纠错服务地址无效")
        }
        let boundary = "vocalocal-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("draft", draft)
        if !context.isEmpty { field("context", context) }
        if !hotwords.isEmpty { field("hotwords", hotwords.joined(separator: ",")) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await HTTP.session(for: url).upload(for: req, from: body)
        try checkHTTP(resp, data)
        struct R: Decodable { let fixes: [Fix] }
        return try JSONDecoder().decode(R.self, from: data).fixes
    }

    /// 逐条校验后套用。返回结果文字和被拒绝的修改（写进历史，方便以后调整规则）
    static func apply(_ fixes: [Fix], to draft: String) -> (text: String, applied: [Fix], rejected: [Fix]) {
        var text = draft
        var applied: [Fix] = []
        var rejected: [Fix] = []
        var changedChars = 0
        for fix in fixes {
            let from = fix.from, to = fix.to.trimmingCharacters(in: .whitespaces)
            let ok: Bool = {
                guard !from.isEmpty, text.contains(from), from != to else { return false }
                guard from.lowercased() != to.lowercased() else { return false }          // 只改大小写：没必要
                if to.isEmpty {                                                          // 删除：只允许语气词
                    return fillers.contains(from.trimmingCharacters(in: .punctuationCharacters).lowercased())
                }
                guard from.count <= 12 else { return false }                             // 只改词，不改整句
                guard to.count <= max(from.count * 3, from.count + 10) else { return false }
                return true
            }()
            // 总改动不超过初稿的 40%，防止模型借多条小修改变相重写
            if ok, changedChars + max(from.count, to.count) <= max(8, draft.count * 4 / 10) {
                text = text.replacingOccurrences(of: from, with: to, options: [], range: text.range(of: from))
                changedChars += max(from.count, to.count)
                applied.append(fix)
            } else {
                rejected.append(fix)
            }
        }
        return (tidy(text), applied, rejected)
    }

    /// 删除语气词后可能留下 "，，" 或句首逗号
    private static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"([，,])\s*[，,]"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[，,\s]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}
