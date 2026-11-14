import AppKit
import HarborCore
import UniformTypeIdentifiers

/// 右键「打开方式」：列出能打开所选项目的应用，默认应用排第一，最后是「其他…」
extension BrowserViewController {
    /// 能打开全部所选项目的应用（多选时取交集）。所选项目的默认应用都相同时把它排第一，
    /// 其余按名称排序；同一个应用装了多份（同一个 bundle id）只列一次
    static func applications(toOpen urls: [URL]) -> (apps: [URL], defaultApp: URL?) {
        // 同扩展名、同为文件 / 文件夹的只查一次：一次选上千个文件时不用逐个问 LaunchServices
        var representatives: [String: URL] = [:]
        for url in urls {
            let key = url.pathExtension.lowercased() + (url.hasDirectoryPath ? "/" : "")
            if representatives[key] == nil { representatives[key] = url }
        }
        let samples = Array(representatives.values)
        guard let first = samples.first else { return ([], nil) }
        let workspace = NSWorkspace.shared
        var candidates = workspace.urlsForApplications(toOpen: first)
        for url in samples.dropFirst() {
            let allowed = Set(workspace.urlsForApplications(toOpen: url).map(\.standardizedFileURL))
            candidates = candidates.filter { allowed.contains($0.standardizedFileURL) }
        }
        let defaults = Set(samples.compactMap { workspace.urlForApplication(toOpen: $0)?.standardizedFileURL })
        let defaultApp = defaults.count == 1 ? defaults.first : nil

        func identity(_ app: URL) -> String { Bundle(url: app)?.bundleIdentifier ?? app.standardizedFileURL.path }
        var seen = Set<String>()
        var result: [URL] = []
        if let defaultApp, candidates.contains(where: { $0.standardizedFileURL == defaultApp }) {
            result.append(defaultApp)
            seen.insert(identity(defaultApp))
        }
        let sorted = candidates.sorted { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
        for app in sorted where seen.insert(identity(app)).inserted {
            result.append(app)
        }
        return (result, result.first == defaultApp ? defaultApp : nil)
    }

    /// 应用的显示名（本地化，去掉 .app）
    static func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    func makeOpenWithMenu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        let (apps, defaultApp) = Self.applications(toOpen: urls)
        for app in apps {
            let isDefault = app == defaultApp
            let item = NSMenuItem(title: Self.appName(app) + (isDefault ? "（默认）" : ""),
                                  action: #selector(openWithApplication(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if isDefault, apps.count > 1 { menu.addItem(.separator()) }
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "其他…", action: #selector(chooseApplicationToOpen(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        return menu
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        open(selectedURLs, withApplication: app)
    }

    @objc func chooseApplicationToOpen(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.application]
        panel.prompt = "打开"
        panel.message = "选择用来打开所选项目的应用"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            self?.open(urls, withApplication: app)
        }
    }

    private func open(_ urls: [URL], withApplication app: URL) {
        guard let first = urls.first else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                self?.presentErrors([FileOperationError(url: first, message: message)], title: "用「\(Self.appName(app))」打开失败")
            }
        }
    }
}
