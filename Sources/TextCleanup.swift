import Foundation

/// 不用模型的轻量整理：去语气词、修常见的格式问题。纠错模型关闭时这是唯一的后处理，开启时也会再过一遍。
/// 规则都保守：拿不准的情况保持原样（例如句末语气的“啊”、“额度”里的“额”）。
enum TextCleanup {
    static func apply(_ text: String) -> String {
        var t = removeFillers(text)
        t = joinSpacedLetters(t)
        t = numeralsBeforeUnits(t)
        t = tidyPunctuation(t)
        // 整句都是语气词（比如只说了一声“嗯”）时，不要把它删成空
        return t.isEmpty ? text : t
    }

    // MARK: - 语气词

    static func removeFillers(_ s: String) -> String {
        var t = s
        // “呃”几乎从不是实义字，出现就删（连同紧跟的逗号）
        t = t.replacingOccurrences(of: #"呃+[，,、]?\s*"#, with: "", options: .regularExpression)
        // “嗯”：作为独立的停顿词时删，例如“，嗯，效果”“能确定嗯这九个”
        t = t.replacingOccurrences(of: #"(?<![嗯])嗯+(?![嗯])[，,、]?\s*"#, with: "", options: .regularExpression)
        // “啊”：只删句首/逗号后的独立“啊，”；句末语气（“很牛啊！”“测试一下啊。”）保留
        t = t.replacingOccurrences(of: #"(^|[，,。！？!?、\s])啊+[，,、]\s*"#, with: "$1", options: .regularExpression)
        // “额”：只删独立的“额，”，避免误伤“额度”“额外”
        t = t.replacingOccurrences(of: #"(^|[，,。！？!?、\s])额+[，,、]\s*"#, with: "$1", options: .regularExpression)
        return t
    }

    // MARK: - 格式

    /// "B P C" → "BPC"、"A S R" → "ASR"、"五G B" → "五GB"：识别模型常把逐个念的字母分开写
    static func joinSpacedLetters(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(?<![A-Za-z])[A-Z](?: [A-Z])+(?![A-Za-z])"#) else { return s }
        var t = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: t) else { continue }
            t.replaceSubrange(r, with: t[r].replacingOccurrences(of: " ", with: ""))
        }
        return t
    }

    /// "五GB" → "5GB"、"十七 GB" → "17GB"：中文数字后面跟存储/频率单位时改成阿拉伯数字
    static func numeralsBeforeUnits(_ s: String) -> String {
        let pattern = #"([零一二两三四五六七八九十百]+)\s*(GB|MB|TB|KB|Gb|Mb|G|M|K|Hz|MHz|GHz)(?![A-Za-z])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var t = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: t), let numR = Range(m.range(at: 1), in: t),
                  let unitR = Range(m.range(at: 2), in: t), let n = chineseNumber(String(t[numR])) else { continue }
            t.replaceSubrange(whole, with: "\(n)\(t[unitR])")
        }
        return t
    }

    /// 0~999 的中文数字："十七" → 17，"一百二十八" → 128，"三二" → 32（逐位念）
    static func chineseNumber(_ s: String) -> Int? {
        let digit: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if !s.contains("十"), !s.contains("百") {           // 逐位念：三二 → 32
            var v = 0
            for c in s { guard let d = digit[c] else { return nil }; v = v * 10 + d }
            return v
        }
        var total = 0, current = 0
        for c in s {
            if let d = digit[c] { current = d }
            else if c == "十" { total += (current == 0 ? 1 : current) * 10; current = 0 }
            else if c == "百" { total += current * 100; current = 0 }
            else { return nil }
        }
        return total + current
    }

    /// 删除语气词后可能留下 "，，"、句首逗号、"，。"
    static func tidyPunctuation(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"([，,、])\s*[，,、]+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[，,、]\s*([。！？!?])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[，,、。\s]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}
