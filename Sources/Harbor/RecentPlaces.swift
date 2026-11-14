import Foundation
import HarborCore

/// 访问过的目录（快速跳转的数据），所有窗口共用。
/// 存在 ~/Library/Application Support/Harbor/visits.json，改动后 2 秒内合并写盘。
/// 跑调试脚本（HARBOR_SCRIPT）时只放内存，不碰真实数据。
@MainActor
final class RecentPlaces {
    static let shared = RecentPlaces()

    private(set) var store = VisitStore()
    private let fileURL: URL?
    private var saveTask: Task<Void, Never>?

    private init() {
        if ProcessInfo.processInfo.environment["HARBOR_SCRIPT"] != nil {
            fileURL = nil
            return
        }
        let support = URL.applicationSupportDirectory.appending(path: "Harbor", directoryHint: .isDirectory)
        fileURL = support.appending(path: "visits.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(VisitStore.self, from: data) {
            store = decoded
        }
    }

    func record(_ url: URL) {
        store.record(url)
        scheduleSave()
    }

    /// 跳转时发现目录已经不存在了
    func forget(_ path: String) {
        store.remove(path)
        scheduleSave()
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(store).write(to: fileURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[harbor] 保存访问记录失败：\(error)\n".utf8))
        }
    }

    private func scheduleSave() {
        guard fileURL != nil, saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }
}
