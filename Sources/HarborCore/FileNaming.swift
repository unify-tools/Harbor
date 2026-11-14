import Darwin
import Foundation

public enum FileNaming {
    /// 目标已被占用时生成「名称 2.扩展名」「名称 3.扩展名」…；已经带编号的接着往后编。
    public static func uniqueURL(for url: URL, isTaken: (URL) -> Bool = FileSystem.exists) -> URL {
        guard isTaken(url) else { return url }
        let directory = url.deletingLastPathComponent()
        let (base, ext) = split(url.lastPathComponent)
        var stem = base
        var number = 2
        if let match = base.wholeMatch(of: /(.+) (\d+)/), let existing = Int(match.2) {
            stem = String(match.1)
            number = existing + 1
        }
        while true {
            let candidate = directory.appending(path: "\(stem) \(number)\(ext)")
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// 新名称不合法时返回原因
    public static func validationError(forNewName name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "名称不能为空。" }
        if name.contains("/") { return "名称不能包含「/」。" }
        if name == "." || name == ".." { return "不能使用「\(name)」作为名称。" }
        if name.utf8.count > 255 { return "名称太长。" }
        return nil
    }

    /// 「a.txt」→（a, .txt）；「.zshrc」「Makefile」没有扩展名
    static func split(_ name: String) -> (String, String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        guard !ext.isEmpty, !base.isEmpty else { return (name, "") }
        return (base, "." + ext)
    }
}
