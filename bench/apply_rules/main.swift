// 把 App 里的 TextCleanup 规则套到已有结果上，生成“小内存方案”一列（和 App 用的是同一份代码）。
// 用法（在 bench/ 下）: swiftc -o /tmp/apply_rules ../Sources/TextCleanup.swift apply_rules/main.swift && /tmp/apply_rules real
import Foundation

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "real"
let input = URL(fileURLWithPath: dir).appendingPathComponent("results_local.jsonl")
let output = URL(fileURLWithPath: dir).appendingPathComponent("results_rules.jsonl")
let source = "qwen3-asr+词汇表"

var lines: [String] = []
for line in (try String(contentsOf: input, encoding: .utf8)).split(separator: "\n") {
    guard let data = line.data(using: .utf8),
          var row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          row["engine"] as? String == source, let text = row["text"] as? String else { continue }
    row["engine"] = "小内存方案"
    row["text"] = TextCleanup.apply(text)
    let out = try JSONSerialization.data(withJSONObject: row)
    lines.append(String(decoding: out, as: UTF8.self))
}
try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
print("\(lines.count) 条 → \(output.path)")
