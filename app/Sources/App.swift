import SwiftUI

/// Marka değerleri derleme sırasında brands/<ad>/brand.conf'tan üretilen BrandConfig'ten gelir.
enum Brand {
    static let accent = Color(hex: BrandConfig.accent)
    static let accentDark = Color(hex: BrandConfig.accentDark)
    static let danger = Color(red: 0.86, green: 0.2, blue: 0.23)
    static let gradient = LinearGradient(colors: [accent, accentDark], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let icon: NSImage? = Bundle.main.url(forResource: "header-icon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { QuitGuard.shouldTerminate() }
    }
    func applicationWillTerminate(_ notification: Notification) { Runner.terminateAll() }
}

@main
struct VideoDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    init() { Typography.register() }

    var body: some Scene {
        WindowGroup(BrandConfig.appName) {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 720, idealWidth: 780, minHeight: 680, idealHeight: 860)
                .tint(Brand.accent)
                .font(.brand(13))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    state.checkClipboard()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("İndirme Klasörünü Aç") { state.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Nasıl Kullanılır") { state.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
