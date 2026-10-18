import AppKit
import ApplicationServices

/// 用 Accessibility API 读取当前焦点信息，对应 Typeless 的 ContextHelper / InputHelper.getSelectedText。
struct FocusContext {
    var appName: String?
    var bundleID: String?
    var pid: pid_t?
    var selectedText: String?
    /// 光标前的文字（最多 maxContext 个字符）
    var textBeforeCursor: String?
    var isEditable = false

    static let maxContext = 800

    static func capture() -> FocusContext {
        var ctx = FocusContext()
        guard let app = NSWorkspace.shared.frontmostApplication else { return ctx }
        ctx.appName = app.localizedName
        ctx.bundleID = app.bundleIdentifier
        ctx.pid = app.processIdentifier
        guard AXIsProcessTrusted() else { return ctx }

        enableElectronAccessibility(pid: app.processIdentifier)

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)   // 有的 App 无响应时不要卡住
        guard let focused: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return ctx }

        if let role: String = attribute(focused, kAXRoleAttribute) {
            ctx.isEditable = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            ctx.isEditable = true
        }

        if let sel: String = attribute(focused, kAXSelectedTextAttribute), !sel.isEmpty {
            ctx.selectedText = sel
        }

        // 光标前上下文：AXValue + AXSelectedTextRange
        if let value: String = attribute(focused, kAXValueAttribute), !value.isEmpty {
            var cursor = value.utf16.count
            if let rangeValue: AXValue = attribute(focused, kAXSelectedTextRangeAttribute) {
                var range = CFRange()
                if AXValueGetValue(rangeValue, .cfRange, &range) { cursor = min(max(range.location, 0), value.utf16.count) }
            }
            let utf16 = Array(value.utf16)
            let start = max(0, cursor - maxContext)
            ctx.textBeforeCursor = String(utf16CodeUnits: Array(utf16[start..<cursor]), count: cursor - start)
        }
        return ctx
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    /// Electron / Chromium 默认不暴露 AX 树，读不到输入框内容。
    /// 设置 AXManualAccessibility（Electron）后就能读到，Typeless 的 setFocusedWindowEnhancedUserInterface 也是在做这件事。
    /// 不用 AXEnhancedUserInterface：它会让部分 App 的窗口动画失效。
    private static var enabledPIDs = Set<pid_t>()
    private static func enableElectronAccessibility(pid: pid_t) {
        guard !enabledPIDs.contains(pid) else { return }
        enabledPIDs.insert(pid)
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
