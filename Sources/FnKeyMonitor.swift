import Cocoa

/// 用 CGEventTap 全局监听 Fn（🌐）键。
///
/// Fn 不产生 keyDown/keyUp，只产生 flagsChanged 事件：keycode 63（kVK_Function），
/// 按下时 flags 带 .maskSecondaryFn，松开时不带。注意方向键、F1-F12 等按键的事件也会带
/// .maskSecondaryFn，所以必须按 keycode 过滤，不能只看 flag。
///
/// 系统在回调太慢或用户输入安全输入框时会停用 tap（tapDisabledByTimeout / ByUserInput），
/// 必须重新启用，否则过一会儿就"Fn 没反应了"。Typeless 的 KeyboardHelper 也专门处理了这个情况。
final class FnKeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    /// Fn 按住时又按了别的键（例如 fn+↑、fn+F1），说明用户不是想说话
    var onChordWhileFn: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnDown = false

    private static let fnKeycodes: Set<Int64> = [63, 179]   // 63 = kVK_Function；部分键盘的 🌐 键上报为 179
    private static let escKeycode: Int64 = 53

    func start() -> Bool {
        if isRunning { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        // listenOnly：只监听不拦截，不会吞掉用户的按键
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
        fnDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.info("event tap disabled (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if Self.fnKeycodes.contains(keycode) {
                let down = event.flags.contains(.maskSecondaryFn)
                guard down != fnDown else { return }
                fnDown = down
                if down { onFnDown?() } else { onFnUp?() }
            } else if fnDown {
                // Fn 按住期间又按了 ⌘/⌥/⇧/⌃
                onChordWhileFn?()
            }

        case .keyDown:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == Self.escKeycode { onEscape?() }
            if fnDown { onChordWhileFn?() }

        default:
            break
        }
    }
}
