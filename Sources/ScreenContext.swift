import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// 屏幕上下文：读取当前窗口的可见文字，从中提取术语作为识别热词。
/// 对应 Typeless ContextHelper 的 collectVisibleTexts（深度上限、最大长度、超时）。
/// 例如聊天窗口里反复出现 "Python"、"Ollama"，说"派森""欧拉玛"时识别模型就会倾向这些词。
struct ScreenContext {
    var visibleText = ""
    var terms: [String] = []
    var source = "none"   // "ax" / "ocr" / "none"，写进日志便于排查

    static let maxChars = 10_000
    static let maxDepth = 60
    static let timeBudget: TimeInterval = 0.4
    static let maxTerms = 40

    /// 读到的文字少于这个长度时，说明 AX 拿不到内容（虚拟机、远程桌面、游戏、图片、部分自绘 App），改用 OCR
    static let ocrThreshold = 300

    /// 先用辅助功能读文字；读不到时截取当前窗口做 OCR（需要“屏幕录制”权限）
    static func capture(pid: pid_t) async -> ScreenContext {
        var ctx = captureAX(pid: pid)
        if ctx.visibleText.count < ocrThreshold, #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() {
            let text = await ocrFrontWindow(pid: pid)
            if text.count > ctx.visibleText.count {
                ctx.visibleText = String(text.suffix(maxChars))
                ctx.source = "ocr"
            }
        }
        ctx.terms = extractTerms(ctx.visibleText)
        return ctx
    }

    private static func captureAX(pid: pid_t) -> ScreenContext {
        guard AXIsProcessTrusted() else { return ScreenContext() }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window: AXUIElement = attr(app, kAXFocusedWindowAttribute) else { return ScreenContext() }

        let deadline = Date().addingTimeInterval(timeBudget)
        var pieces: [String] = []
        var total = 0
        var seen = Set<String>()
        // 广度优先：先拿到窗口上层（标题、主要内容），时间不够时深处的细节可以舍弃
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, total < maxChars, Date() < deadline {
            let (element, depth) = queue[index]
            index += 1
            let role: String = attr(element, kAXRoleAttribute) ?? ""
            for name in textAttributes(for: role) {
                if let s: String = attr(element, name) {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count >= 2, t.count < 4000, seen.insert(t).inserted {
                        pieces.append(t)
                        total += t.count
                    }
                }
            }
            if depth < maxDepth, let children: [AXUIElement] = attr(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.prefix(300).map { ($0, depth + 1) })
            }
        }
        var ctx = ScreenContext()
        ctx.visibleText = String(pieces.joined(separator: "\n").prefix(maxChars))
        ctx.source = ctx.visibleText.isEmpty ? "none" : "ax"
        return ctx
    }

    /// 截取该 App 最大的可见窗口，用 Vision 识别中英文。截图按 1x 分辨率，M 系列芯片上约 0.2~0.5 秒，和录音并行。
    @available(macOS 14.0, *)
    private static func ocrFrontWindow(pid: pid_t) async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.isOnScreen && $0.frame.width > 200 && $0.frame.height > 150
            }
            guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                return ""
            }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 1.5)
            config.height = Int(window.frame.height * 1.5)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            // 按从上到下的顺序拼接；Vision 坐标原点在左下角
            let lines = (request.results ?? [])
                .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                .compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        } catch {
            Log.info("screen OCR failed: \(error.localizedDescription)")
            return ""
        }
    }

    private static func textAttributes(for role: String) -> [String] {
        switch role {
        case "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell", "AXLink":
            return [kAXValueAttribute, kAXTitleAttribute]
        case "AXWindow", "AXButton", "AXTab", "AXMenuItem":
            return [kAXTitleAttribute]
        default:
            return []
        }
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "you", "your", "are", "was", "were", "is", "to", "of", "in",
        "on", "at", "by", "or", "an", "be", "it", "as", "if", "not", "can", "will", "from", "have", "has", "had",
        "but", "all", "any", "one", "my", "we", "our", "they", "their", "what", "when", "how", "use", "used",
        "true", "false", "nil", "null", "let", "var", "func", "return", "self", "import", "def", "else", "then",
        "http", "https", "www", "com", "png", "jpg", "html", "ok", "no", "yes", "id", "md",
    ]

    /// 提取英文/字母数字术语，按出现次数排序，保留最常见的大小写写法
    static func extractTerms(_ text: String, limit: Int = maxTerms) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9]*(?:[.+#_-][A-Za-z0-9]+)*\+*"#) else { return [] }
        var counts: [String: Int] = [:]
        var spelling: [String: [String: Int]] = [:]
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range)
            let key = word.lowercased()
            guard word.count >= 2, word.count <= 30, !stopwords.contains(key), !looksLikeID(word) else { continue }
            counts[key, default: 0] += 1
            spelling[key, default: [:]][word, default: 0] += 1
        }
        // 专有名词（有大写或数字）权重更高：Python、Qwen3、MLX 比普通英文单词更值得做热词
        func score(_ key: String) -> Double {
            let best = spelling[key]?.max { $0.value < $1.value }?.key ?? key
            let special = best != best.lowercased() || best.contains(where: \.isNumber)
            return Double(counts[key] ?? 0) * (special ? 3 : 1)
        }
        return counts.keys.sorted { score($0) > score($1) }.prefix(limit).compactMap { key in
            spelling[key]?.max { $0.value < $1.value }?.key
        }
    }

    /// 随机 ID / 哈希 / 带下划线的用户名不适合做热词，例如 XyM1GbDbv、a3f9c2e1、user_name
    private static func looksLikeID(_ word: String) -> Bool {
        if word.contains("_") { return true }
        let digits = word.filter(\.isNumber).count
        let uppers = word.filter(\.isUppercase).count
        let transitions = zip(word, word.dropFirst()).filter { $0.isUppercase != $1.isUppercase || $0.isNumber != $1.isNumber }.count
        return word.count >= 6 && (digits >= 3 || (uppers >= 3 && transitions >= 5))
    }

    private static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
}
