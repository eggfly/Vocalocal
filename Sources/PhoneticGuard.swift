import Foundation

/// 发音相近校验：纠错模型给出的“把 A 改成 B”，只有读音接近时才接受。
///
/// 在 112 段真实录音上的观察：正确的修改几乎都发音相近（派送→Python、考→拷、李依晨→李一辰），
/// 错误的修改大多发音不同（改低→改高、SSD→机械硬盘、思维→Vocalocal、push→推送）。
/// 做法：去掉两边相同的前后缀，只比较真正改动的部分；转成拼音字母串（英文保持原样、数字读成拼音）后算相似度。
/// 与 bench/phonetic_guard.py 的逻辑一致。
enum PhoneticGuard {
    static let fillers: Set<String> = ["呃", "嗯", "啊", "额", "呃呃", "嗯嗯", "啊啊", "um", "uh"]

    /// 改成词汇表/屏幕术语时门槛放低（中文音译的英文词本来就不太像）
    static let vocabThreshold = 0.25
    static let threshold = 0.6

    static func accept(from: String, to rawTo: String, hotwords: [String]) -> (ok: Bool, similarity: Double) {
        let to = rawTo.trimmingCharacters(in: .whitespaces)
        if to.isEmpty { return (isFiller(from), 1) }
        let (a, b) = core(from, to)
        let sa = sound(a), sb = sound(b)
        if sa.isEmpty, sb.isEmpty { return (true, 1) }                  // 只改了空格 / 标点 / 大小写
        let vocab = hotwords.map { $0.lowercased() }.filter { $0.count >= 2 }
        let gainsTerm = vocab.contains { to.lowercased().contains($0) && !from.lowercased().contains($0) }
        if sa.isEmpty { return (gainsTerm, 0) }                         // 纯插入：只允许补上词汇表里的词
        if sb.isEmpty { return (isFiller(a), 0) }                       // 纯删除：只允许删语气词
        let sim = similarity(sa, sb)
        return (sim >= (gainsTerm ? vocabThreshold : threshold), sim)
    }

    static func isFiller(_ s: String) -> Bool {
        fillers.contains(s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)).lowercased())
    }

    /// 去掉两边相同的前后缀："改低一下那个" / "改高一下那个" → ("低", "高")
    static func core(_ a: String, _ b: String) -> (String, String) {
        let x = Array(a), y = Array(b)
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        var j = 0
        while j < min(x.count, y.count) - i, x[x.count - 1 - j] == y[y.count - 1 - j] { j += 1 }
        return (String(x[i..<(x.count - j)]), String(y[i..<(y.count - j)]))
    }

    private static let digitSounds: [Character: String] = [
        "0": "ling", "1": "yi", "2": "er", "3": "san", "4": "si", "5": "wu", "6": "liu", "7": "qi", "8": "ba", "9": "jiu",
    ]

    /// 读音字母串：汉字转无声调拼音，数字转拼音，只保留 a-z
    static func sound(_ s: String) -> String {
        let spelled = s.map { digitSounds[$0] ?? String($0) }.joined()
        let m = NSMutableString(string: spelled)
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        return (m as String).lowercased().filter { $0 >= "a" && $0 <= "z" }
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
