import Darwin
import Foundation

/// 撤销一次文件操作要做的一步
public enum UndoStep: Sendable, Hashable {
    /// 移到废纸篓（撤销拷贝、新建文件夹）
    case trash(URL)
    /// 移回去（撤销移动、重命名、移到废纸篓）
    case move(from: URL, to: URL)
}

/// 不需要进度的简单操作，以及撤销步骤的执行
public enum FileActions {
    public static func createFolder(in directory: URL, name: String) throws(FileOperationError) -> URL {
        let url = FileNaming.uniqueURL(for: directory.appending(path: name, directoryHint: .isDirectory))
        guard mkdir(url.path(percentEncoded: false), 0o755) == 0 else {
            throw FileOperationError(url: url, code: errno)
        }
        return url
    }

    /// 改名；目标已存在时报错。只改大小写（a → A）也能用。
    public static func rename(_ url: URL, to newName: String) throws(FileOperationError) -> URL {
        if let problem = FileNaming.validationError(forNewName: newName) {
            throw FileOperationError(url: url, message: problem)
        }
        let target = url.deletingLastPathComponent().appending(path: newName)
        let src = url.path(percentEncoded: false)
        let dst = target.path(percentEncoded: false)
        let caseOnly = url.lastPathComponent.lowercased() == newName.lowercased()
        // 不区分大小写的卷上只改大小写时，目标「已存在」的就是它自己，不能用 RENAME_EXCL
        let status = caseOnly ? Darwin.rename(src, dst) : renamex_np(src, dst, UInt32(RENAME_EXCL))
        guard status == 0 else {
            let code = errno
            if code == EEXIST {
                throw FileOperationError(url: url, message: "名称「\(newName)」已被使用，请换一个名称。")
            }
            throw FileOperationError(url: url, code: code)
        }
        return target
    }

    /// 移到废纸篓。返回的撤销步骤会把它们移回原处。
    public static func trash(_ urls: [URL], fileSystem: FileSystem = .live) -> (undo: [UndoStep], errors: [FileOperationError]) {
        var undo: [UndoStep] = []
        var errors: [FileOperationError] = []
        for url in urls {
            do {
                let trashed = try fileSystem.trash(url)
                undo.append(.move(from: trashed, to: url))
            } catch {
                errors.append(FileOperationError(url: url, error: error))
            }
        }
        return (undo, errors)
    }

    /// 永久删除，不能撤销
    public static func delete(_ urls: [URL]) -> [FileOperationError] {
        urls.compactMap { url in
            do {
                try FileManager.default.removeItem(at: url)
                return nil
            } catch {
                return FileOperationError(url: url, error: error)
            }
        }
    }

    /// 执行撤销步骤，返回反向步骤（用来重做）。
    /// 移回时原位置被占了就用「名称 2」；原来的父目录没了就重新建。
    public static func perform(_ steps: [UndoStep], fileSystem: FileSystem = .live) -> (inverse: [UndoStep], errors: [FileOperationError]) {
        var inverse: [UndoStep] = []
        var errors: [FileOperationError] = []
        let context = TransferContext(onProgress: { _ in })
        for step in steps {
            switch step {
            case .trash(let url):
                guard FileSystem.exists(url) else {
                    errors.append(FileOperationError(url: url, message: "已经不存在。"))
                    continue
                }
                do {
                    let trashed = try fileSystem.trash(url)
                    inverse.insert(.move(from: trashed, to: url), at: 0)
                } catch {
                    errors.append(FileOperationError(url: url, error: error))
                }

            case .move(let from, let to):
                guard FileSystem.exists(from) else {
                    errors.append(FileOperationError(url: from, message: "已经不存在。"))
                    continue
                }
                // 同一目录下只差大小写（撤销 readme → README）：直接改名，
                // 否则在不区分大小写的卷上会把它自己当成占位的，改成「readme 2」
                if from.deletingLastPathComponent().pathKey == to.deletingLastPathComponent().pathKey,
                   from.lastPathComponent.lowercased() == to.lastPathComponent.lowercased() {
                    do throws(FileOperationError) {
                        let renamed = try rename(from, to: to.lastPathComponent)
                        inverse.insert(.move(from: renamed, to: from), at: 0)
                    } catch {
                        errors.append(error)
                    }
                    continue
                }
                let target = FileNaming.uniqueURL(for: to)
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileSystem.moveItem(from: from, to: target, context: context)
                    inverse.insert(.move(from: target, to: from), at: 0)
                } catch {
                    errors.append(FileOperationError(url: from, error: error))
                }
            }
        }
        return (inverse, errors)
    }
}
