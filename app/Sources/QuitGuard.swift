import AppKit
import SwiftUI

/// İndirme sürerken pencere kapatılır ya da uygulamadan çıkılırsa kullanıcıya sorar.
@MainActor
enum QuitGuard {
    /// Kullanıcı "Yine de Çık" dediyse ikinci kez sorulmaz
    static var confirmed = false

    static var activeCount: Int { AppState.current?.jobs.filter(\.isActive).count ?? 0 }

    private static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "İndirme sürüyor"
        let n = activeCount
        alert.informativeText = "\(n == 1 ? "Bir" : "\(n)") indirme devam ediyor. Uygulamadan çıkarsanız yarıda kesilecek."
        alert.addButton(withTitle: "İndirmeye Devam Et")          // varsayılan (Enter)
        let quit = alert.addButton(withTitle: "Yine de Çık")
        quit.hasDestructiveAction = true
        quit.keyEquivalent = ""
        return alert
    }

    /// ⌘Q ve Dock'tan "Çık": uygulama genelinde sorar
    static func shouldTerminate() -> NSApplication.TerminateReply {
        guard !confirmed, activeCount > 0 else { return .terminateNow }
        if makeAlert().runModal() == .alertSecondButtonReturn {
            confirmed = true
            return .terminateNow
        }
        return .terminateCancel
    }

    /// Pencerenin kapat düğmesi: pencereye bağlı olarak sorar, kapatmayı o an engeller
    static func shouldClose(_ window: NSWindow) -> Bool {
        guard !confirmed, activeCount > 0 else { return true }
        makeAlert().beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            confirmed = true
            NSApp.terminate(nil)
        }
        return false
    }
}

/// SwiftUI pencere kapatmayı engellemeye izin vermediği için pencerenin delegesinin önüne geçer;
/// windowShouldClose dışındaki her şeyi SwiftUI'nin kendi delegesine iletir.
final class WindowCloseProxy: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?

    init(original: NSWindowDelegate?) {
        self.original = original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard MainActor.assumeIsolated({ QuitGuard.shouldClose(sender) }) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

/// Görünümün penceresini bulup kapatma korumasını bir kez kurar.
struct WindowCloseGuard: NSViewRepresentable {
    final class Coordinator { var proxy: WindowCloseProxy? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { install(on: view.window, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if context.coordinator.proxy == nil {
            DispatchQueue.main.async { install(on: view.window, context.coordinator) }
        }
    }

    private func install(on window: NSWindow?, _ coordinator: Coordinator) {
        guard let window, coordinator.proxy == nil, !(window.delegate is WindowCloseProxy) else { return }
        let proxy = WindowCloseProxy(original: window.delegate)
        coordinator.proxy = proxy        // delege zayıf tutulduğu için burada saklanır
        window.delegate = proxy
    }
}
