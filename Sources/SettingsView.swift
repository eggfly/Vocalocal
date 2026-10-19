import AppKit
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var config: Config
    var onSave: ((Config) -> Void)?

    init(config: Config) { self.config = config }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("语音识别（ASR）") {
                Picker("服务", selection: $model.config.asrProvider) {
                    Text("本地 Qwen3-ASR（推荐）").tag("local")
                    Text("macOS 新版识别").tag("apple-new")
                    Text("macOS 旧版识别").tag("apple")
                    Text("OpenAI 兼容接口").tag("openai")
                }
                if model.config.asrProvider == "local" {
                    TextField("本地服务地址", text: $model.config.localASRURL)
                }
                if model.config.asrProvider == "openai" {
                    TextField("Base URL", text: $model.config.asrBaseURL)
                    SecureField("API Key", text: $model.config.asrAPIKey)
                    TextField("模型", text: $model.config.asrModel)
                }
                TextField("语言（zh / en / 留空自动）", text: $model.config.asrLanguage)
                Toggle("降噪 / 回声消除", isOn: $model.config.noiseSuppression)
            }
            Section("纠错（本地 Qwen3-Omni，约 21 GB，默认关闭）") {
                Toggle("启用", isOn: $model.config.correctorEnabled)
                TextField("服务地址", text: $model.config.correctorURL)
            }
            Section("LLM（选中文字后语音改写）") {
                Toggle("启用", isOn: $model.config.llmEnabled)
                Toggle("也用 LLM 整理每次口述（会改写，默认关）", isOn: $model.config.llmPolish)
                TextField("Base URL", text: $model.config.llmBaseURL)
                SecureField("API Key", text: $model.config.llmAPIKey)
                TextField("模型", text: $model.config.llmModel)
                Toggle("参考输入框已有内容", isOn: $model.config.useFieldContext)
                Toggle("选中文字时语音改写", isOn: $model.config.editSelection)
            }
            Section("输入") {
                Picker("方式", selection: $model.config.insertMode) {
                    Text("粘贴（推荐）").tag("paste")
                    Text("模拟键入").tag("type")
                }
                Toggle("粘贴后恢复剪贴板", isOn: $model.config.restoreClipboard)
                Toggle("保存每次录音（用于评测）", isOn: $model.config.saveRecordings)
                VStack(alignment: .leading) {
                    Text("自定义词汇（逗号或换行分隔）")
                    TextEditor(text: $model.config.vocabulary)
                        .font(.system(size: 12))
                        .frame(height: 60)
                }
            }
            HStack {
                Text(Config.fileURL.path).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Spacer()
                Button("保存") { model.onSave?(model.config) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(config: Config, onSave: @escaping (Config) -> Void) {
        model = SettingsModel(config: config)
        model.onSave = onSave
    }

    func show(config: Config) {
        model.config = config
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Vocalocal 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
