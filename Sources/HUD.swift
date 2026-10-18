import AppKit
import SwiftUI

enum HUDPhase: Equatable {
    case hidden
    case listening(handsFree: Bool)
    case thinking
    case message(String)
}

final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 20)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(CGFloat(level))
    }
}

/// 屏幕底部居中的胶囊浮窗。nonactivatingPanel + ignoresMouseEvents：
/// 显示它绝不会抢走目标 App 的焦点，否则 ⌘V 会粘贴到我们自己的窗口里。
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ phase: HUDPhase, autoHideAfter: TimeInterval? = nil) {
        hideWork?.cancel()
        model.phase = phase
        if phase == .hidden {
            panel.orderOut(nil)
            return
        }
        position()
        panel.orderFrontRegardless()
        if let autoHideAfter {
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: work)
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .listening(let handsFree):
                Circle().fill(handsFree ? Color.orange : Color.red).frame(width: 8, height: 8)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(model.levels.indices, id: \.self) { i in
                        Capsule().fill(Color.white)
                            .frame(width: 3, height: 4 + model.levels[i] * 22)
                    }
                }
                .animation(.linear(duration: 0.05), value: model.levels)
            case .thinking:
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text("整理中…").foregroundColor(.white).font(.system(size: 13, weight: .medium))
            case .message(let text):
                Text(text).foregroundColor(.white).font(.system(size: 12)).lineLimit(1)
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 220, height: 44)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}
