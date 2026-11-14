import Foundation
import Testing
@testable import HarborCore

@Suite struct NavigationHistoryTests {
    @Test func backAndForward() {
        var history = NavigationHistory()
        let a = URL(filePath: "/a"), b = URL(filePath: "/b"), c = URL(filePath: "/c")
        history.visit(a); history.visit(b); history.visit(c)
        #expect(history.goBack()?.path == "/b")
        #expect(history.goBack()?.path == "/a")
        #expect(history.goBack() == nil)
        #expect(history.goForward()?.path == "/b")
        // 后退后访问新位置会清掉前进历史
        history.visit(URL(filePath: "/d"))
        #expect(!history.canGoForward)
        #expect(history.goBack()?.path == "/b")
    }

    @Test func revisitingCurrentIsIgnored() {
        var history = NavigationHistory()
        history.visit(URL(filePath: "/a"))
        history.visit(URL(filePath: "/a/"))
        #expect(!history.canGoBack)
    }
}

@Suite struct PathInputTests {
    let base = URL(filePath: "/Users/someone/work", directoryHint: .isDirectory)

    @Test func resolveVariants() {
        let home = FileManager.default.homeDirectoryForCurrentUser.pathKey
        #expect(PathInput.resolve("~", relativeTo: base)?.pathKey == home)
        #expect(PathInput.resolve("~/Downloads", relativeTo: base)?.pathKey == home + "/Downloads")
        #expect(PathInput.resolve("/tmp/../etc", relativeTo: base)?.pathKey == "/etc")
        #expect(PathInput.resolve("src", relativeTo: base)?.pathKey == "/Users/someone/work/src")
        #expect(PathInput.resolve("..", relativeTo: base)?.pathKey == "/Users/someone")
        #expect(PathInput.resolve("file:///var/log", relativeTo: base)?.pathKey == "/var/log")
        #expect(PathInput.resolve("  ", relativeTo: base) == nil)
    }

    @Test func completion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for name in ["Documents", "Downloads", "Desktop", ".config", "Music"] {
            try fm.createDirectory(at: dir.appending(path: name), withIntermediateDirectories: false)
        }
        try Data().write(to: dir.appending(path: "Dotfile.txt"))

        // 唯一匹配：补全并加 /，不区分大小写
        #expect(PathInput.complete("mu", relativeTo: dir, showHidden: false) == "Music/")
        // 多个匹配：补到公共前缀
        #expect(PathInput.complete("Do", relativeTo: dir, showHidden: false) == nil)
        #expect(PathInput.complete("Doc", relativeTo: dir, showHidden: false) == "Documents/")
        #expect(PathInput.complete("D", relativeTo: dir, showHidden: false) == nil)
        // 文件不参与补全；隐藏目录只在输入 . 开头或显示隐藏文件时参与
        #expect(PathInput.complete("Dot", relativeTo: dir, showHidden: false) == nil)
        #expect(PathInput.complete(".c", relativeTo: dir, showHidden: false) == ".config/")
        // 带目录部分时保留用户输入
        let absolute = dir.path(percentEncoded: false)
        #expect(PathInput.complete(absolute + "/Mus", relativeTo: base, showHidden: false) == absolute + "/Music/")
    }
}

@Suite struct DirectoryWatcherTests {
    @Test func relevanceFilter() {
        #expect(DirectoryWatcher.isRelevant("/a/b", to: "/a/b"))
        #expect(DirectoryWatcher.isRelevant("/a/b/c", to: "/a/b"))
        #expect(!DirectoryWatcher.isRelevant("/a/b/c/d", to: "/a/b"))
        #expect(DirectoryWatcher.isRelevant("/x", to: "/"))
        #expect(!DirectoryWatcher.isRelevant("/x/y", to: "/"))
        // 前缀对不上时保守处理
        #expect(DirectoryWatcher.isRelevant("/System/Volumes/Data/a/b/c", to: "/a/b"))
    }

    @Test func notifiesOnNewFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let watcher = try #require(DirectoryWatcher(url: dir) { continuation.yield() })
        defer { watcher.stop() }
        // 等监听真正生效
        try await Task.sleep(for: .milliseconds(300))
        try Data().write(to: dir.appending(path: "new.txt"))

        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            continuation.finish()
            return first
        }
        #expect(received)
    }
}
