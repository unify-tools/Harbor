import Foundation

/// 地址栏输入：解析路径、Tab 补全
public enum PathInput {
    /// 支持 ~、绝对路径、相对当前目录的路径、file:// URL，以及 .. 和 .
    public static func resolve(_ text: String, relativeTo base: URL) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            return URL(string: trimmed)?.standardizedFileURL
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(filePath: expanded)
            : base.appending(path: expanded)
        return url.standardizedFileURL
    }

    /// Tab 补全目录名。唯一匹配时补全并加 /；多个匹配时补到公共前缀；补不了返回 nil。
    /// 用户输入的部分（比如 ~）原样保留。
    public static func complete(_ text: String, relativeTo base: URL, showHidden: Bool) -> String? {
        let slash = text.lastIndex(of: "/")
        let dirPart = slash.map { String(text[...$0]) } ?? ""
        let prefix = slash.map { String(text[text.index(after: $0)...]) } ?? text

        let directory: URL
        if dirPart.isEmpty {
            directory = base
        } else {
            guard let resolved = resolve(dirPart, relativeTo: base) else { return nil }
            directory = resolved
        }
        guard let entries = try? DirectoryReader.read(directory) else { return nil }

        let wantsHidden = showHidden || prefix.hasPrefix(".")
        let matches = entries
            .filter { entry in
                guard entry.isFolder || (entry.kind == .symlink && isDirectory(entry.url(in: directory))) else { return false }
                guard wantsHidden || !entry.isHidden else { return false }
                return entry.name.lowercased().hasPrefix(prefix.lowercased())
            }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard let first = matches.first else { return nil }
        if matches.count == 1 { return dirPart + first + "/" }

        let common = matches.dropFirst().reduce(first) { commonPrefix($0, $1) }
        return common.count > prefix.count ? dirPart + common : nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }

    /// 不区分大小写的公共前缀，大小写取自第一个参数
    private static func commonPrefix(_ a: String, _ b: String) -> String {
        var result = ""
        for (ca, cb) in zip(a, b) {
            guard ca.lowercased() == cb.lowercased() else { break }
            result.append(ca)
        }
        return result
    }
}
