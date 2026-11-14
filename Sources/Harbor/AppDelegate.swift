import AppKit
import HarborCore
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, SPUUpdaterDelegate {
    /// 自动更新（Sparkle，更新源和公钥在 Info.plist）。
    /// 调试脚本运行时、不是从 .app 启动时（swift run）不启用，免得更新弹窗打断脚本
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        if Bundle.main.bundleURL.pathExtension == "app", ProcessInfo.processInfo.environment["HARBOR_SCRIPT"] == nil {
            updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
            if Self.debugFeedURL != nil, let updater = updaterController?.updater {
                // 调试：后台检查、自动下载，下载完立即安装并重启（见 willInstallUpdateOnQuit）
                updater.automaticallyDownloadsUpdates = true
                updater.checkForUpdatesInBackground()
            }
        }
        // 窗口由 MainWindowController.all 持有
        MainWindowController(url: startURL()).showWindow(nil)
        NSApp.activate()
        SmokeScript.runIfRequested()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updaterController?.updater.canCheckForUpdates ?? false
        }
        return true
    }

    /// 调试用：HARBOR_FEED_URL 指向本地的 appcast，验证更新流程时不用发真的 Release
    nonisolated static var debugFeedURL: String? { ProcessInfo.processInfo.environment["HARBOR_FEED_URL"] }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.debugFeedURL
    }

    /// 平时自动下载的更新等退出时再装；调试时立即安装，好验证整个流程
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard Self.debugFeedURL != nil else { return false }
        immediateInstallHandler()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecentPlaces.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 命令行参数里的目录优先（方便调试），其次上次打开的位置，最后是主目录
    private func startURL() -> URL {
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            let url = URL(filePath: (argument as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            if Self.isDirectory(url) { return url.standardizedFileURL }
        }
        if let last = Preferences.lastDirectory, Self.isDirectory(last) {
            return last
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }
}

/// 需要跨启动保留的界面设置
@MainActor
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var showHidden: Bool {
        get { defaults.bool(forKey: "showHidden") }
        set { defaults.set(newValue, forKey: "showHidden") }
    }

    static var sortOrder: FileSortOrder {
        get {
            let key = defaults.string(forKey: "sortKey").flatMap(FileSortOrder.Key.init(rawValue:)) ?? .name
            let ascending = defaults.object(forKey: "sortAscending") as? Bool ?? true
            return FileSortOrder(key: key, ascending: ascending)
        }
        set {
            defaults.set(newValue.key.rawValue, forKey: "sortKey")
            defaults.set(newValue.ascending, forKey: "sortAscending")
        }
    }

    /// 新窗口、新标签页是否用双栏
    static var dualPane: Bool {
        get { defaults.bool(forKey: "dualPane") }
        set { defaults.set(newValue, forKey: "dualPane") }
    }

    /// 终端面板的高度，收起时记下，下次打开沿用
    static var terminalHeight: CGFloat {
        get { defaults.object(forKey: "terminalHeight") as? CGFloat ?? 240 }
        set { defaults.set(Double(newValue), forKey: "terminalHeight") }
    }

    static var lastDirectory: URL? {
        get { defaults.string(forKey: "lastDirectory").map { URL(filePath: $0, directoryHint: .isDirectory) } }
        set { defaults.set(newValue?.path(percentEncoded: false), forKey: "lastDirectory") }
    }
}
