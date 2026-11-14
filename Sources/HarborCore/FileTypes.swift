import Foundation
import Synchronization
import UniformTypeIdentifiers

/// 按扩展名查 UTType 的结果都缓存起来，列表里成千上万个同类文件只查一次
public enum FileTypes {
    private static let packageCache = Mutex<[String: Bool]>([:])
    private static let descriptionCache = Mutex<[String: String]>([:])

    public static func isPackageExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty else { return false }
        let key = ext.lowercased()
        if let hit = packageCache.withLock({ $0[key] }) { return hit }
        let result = UTType(filenameExtension: key, conformingTo: .directory)?.conforms(to: .package) ?? false
        packageCache.withLock { $0[key] = result }
        return result
    }

    /// 「种类」列显示的文字，跟随 App 的本地化（Info.plist 里设为简体中文）
    public static func kindDescription(for item: FileItem) -> String {
        switch item.kind {
        case .directory where !item.isPackage:
            return cached("folder") { UTType.folder.localizedDescription ?? "Folder" }
        case .symlink:
            return cached("symlink") { UTType.symbolicLink.localizedDescription ?? "Alias" }
        case .other:
            return cached("other") { UTType.item.localizedDescription ?? "Item" }
        case .directory, .file:
            let ext = item.pathExtension.lowercased()
            let base: UTType = item.kind == .directory ? .directory : .data
            return cached("\(item.kind == .directory ? "p" : "f"):\(ext)") {
                if ext.isEmpty { return UTType.data.localizedDescription ?? "Document" }
                let type = UTType(filenameExtension: ext, conformingTo: base)
                return type?.localizedDescription ?? "\(ext.uppercased()) 文件"
            }
        }
    }

    private static func cached(_ key: String, _ make: () -> String) -> String {
        if let hit = descriptionCache.withLock({ $0[key] }) { return hit }
        let value = make()
        descriptionCache.withLock { $0[key] = value }
        return value
    }
}
