import Foundation

/// 目录里的一个条目。只保存列表展示和排序要用的字段，读出来之后不再变。
public struct FileItem: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case file, directory, symlink, other
    }

    public let name: String
    public let kind: Kind
    /// .app、.bundle 这类在 Finder 里当作单个文件显示的目录
    public let isPackage: Bool
    /// 以 . 开头，或者带 UF_HIDDEN 标志
    public let isHidden: Bool
    /// 数据大小（字节）；目录为 nil
    public let size: Int64?
    public let modified: Date
    public let created: Date

    public init(name: String, kind: Kind, isPackage: Bool, isHidden: Bool, size: Int64?, modified: Date, created: Date) {
        self.name = name
        self.kind = kind
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.created = created
    }

    /// 双击时进入而不是打开
    public var isFolder: Bool { kind == .directory && !isPackage }

    public var pathExtension: String { (name as NSString).pathExtension }

    public func url(in directory: URL) -> URL {
        directory.appending(path: name, directoryHint: kind == .directory ? .isDirectory : .notDirectory)
    }
}

extension URL {
    /// 用于比较两个文件 URL 是否指向同一路径：标准化，去掉末尾斜杠
    public var pathKey: String {
        let path = standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
