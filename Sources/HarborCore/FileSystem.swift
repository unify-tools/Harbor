import Darwin
import Foundation
import Synchronization

public struct FileOperationError: Error, Sendable {
    public let url: URL
    public let message: String
    public var isCancellation = false

    public init(url: URL, message: String, isCancellation: Bool = false) {
        self.url = url
        self.message = message
        self.isCancellation = isCancellation
    }

    init(url: URL, code: Int32) {
        self.init(url: url, message: String(cString: strerror(code)), isCancellation: code == ECANCELED)
    }

    init(url: URL, error: any Error) {
        if let error = error as? FileOperationError {
            self = error
        } else {
            self.init(url: url, message: error.localizedDescription)
        }
    }

    /// 给用户看的一行说明
    public var description: String { "「\(url.lastPathComponent)」：\(message)" }
}

/// 底层文件操作。可替换「移到废纸篓」的实现，单测用假的废纸篓，不污染真实的废纸篓。
public struct FileSystem: Sendable {
    /// 移到废纸篓，返回它在废纸篓里的新位置
    public var trash: @Sendable (URL) throws -> URL
    /// 单测用来强制走逐个文件拷贝的路径
    public var allowsClone = true

    public init(trash: @escaping @Sendable (URL) throws -> URL, allowsClone: Bool = true) {
        self.trash = trash
        self.allowsClone = allowsClone
    }

    public static let live = FileSystem(trash: { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    })

    /// 不跟随符号链接（断开的链接也算存在）
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    static func device(_ url: URL) -> dev_t? {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 ? info.st_dev : nil
    }

    // MARK: - 移动

    /// 同卷直接 rename（瞬间完成）；跨卷拷贝后删除源。目标已存在时报错，不会覆盖。
    func moveItem(from source: URL, to destination: URL, context: TransferContext) throws(FileOperationError) {
        if context.isCancelled { throw FileOperationError(url: source, code: ECANCELED) }
        if renamex_np(source.path(percentEncoded: false), destination.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 {
            return
        }
        let code = errno
        guard code == EXDEV else { throw FileOperationError(url: source, code: code) }
        try copyItem(from: source, to: destination, context: context)
        do {
            try FileManager.default.removeItem(at: source)
        } catch {
            throw FileOperationError(url: source, message: "已拷贝到目标位置，但删除原项目失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 拷贝

    /// 先尝试 clonefile 整体克隆（同一 APFS 卷上瞬间完成，文件夹也是）；
    /// 不行再逐个文件 copyfile，带字节进度和取消。失败或取消时清理掉拷了一半的目标。
    func copyItem(from source: URL, to destination: URL, context: TransferContext) throws(FileOperationError) {
        let src = source.path(percentEncoded: false)
        let dst = destination.path(percentEncoded: false)
        if context.isCancelled { throw FileOperationError(url: source, code: ECANCELED) }
        if allowsClone {
            if clonefile(src, dst, UInt32(CLONE_NOFOLLOW)) == 0 { return }
            if errno == EEXIST { throw FileOperationError(url: source, code: EEXIST) }
        }
        do {
            try copyTree(source, to: destination, context: context)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func copyTree(_ source: URL, to destination: URL, context: TransferContext) throws(FileOperationError) {
        if context.isCancelled { throw FileOperationError(url: source, code: ECANCELED) }
        let src = source.path(percentEncoded: false)
        let dst = destination.path(percentEncoded: false)
        var info = stat()
        guard lstat(src, &info) == 0 else { throw FileOperationError(url: source, code: errno) }

        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            // 先给自己写权限，子项拷完后再用 COPYFILE_METADATA 还原权限、时间和扩展属性
            guard mkdir(dst, 0o700) == 0 else { throw FileOperationError(url: source, code: errno) }
            let children: [FileItem]
            do { children = try DirectoryReader.read(source) } catch { throw FileOperationError(url: source, code: error.code) }
            for child in children {
                try copyTree(source.appending(path: child.name), to: destination.appending(path: child.name), context: context)
            }
            _ = copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_METADATA))

        case S_IFLNK:
            guard copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL)) == 0 else {
                throw FileOperationError(url: source, code: errno)
            }

        default:
            try copyFile(src, dst, source: source, context: context)
            context.fileFinished(bytes: Int64(info.st_size))
        }
    }

    private func copyFile(_ src: String, _ dst: String, source: URL, context: TransferContext) throws(FileOperationError) {
        guard let state = copyfile_state_alloc() else { throw FileOperationError(url: source, code: ENOMEM) }
        defer { copyfile_state_free(state) }

        // 回调里汇报当前文件已拷字节，取消时返回 QUIT，copyfile 会以 ECANCELED 失败
        let callback: copyfile_callback_t = { what, stage, state, _, _, info in
            guard let info else { return COPYFILE_CONTINUE }
            let context = Unmanaged<TransferContext>.fromOpaque(info).takeUnretainedValue()
            if context.isCancelled { return COPYFILE_QUIT }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
                var copied: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                    context.currentFileProgress(bytes: Int64(copied))
                }
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(src, dst, state, flags) == 0 else {
            throw FileOperationError(url: source, code: context.isCancelled ? ECANCELED : errno)
        }
    }
}

/// 递归统计大小，用来算进度
enum TreeSize {
    static func measure(_ url: URL) -> (bytes: Int64, files: Int) {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return (0, 0) }
        guard info.st_mode & S_IFMT == S_IFDIR else { return (Int64(info.st_size), 1) }
        var total: (bytes: Int64, files: Int) = (0, 0)
        for child in (try? DirectoryReader.read(url)) ?? [] {
            if child.kind == .directory {
                let sub = measure(url.appending(path: child.name))
                total.bytes += sub.bytes
                total.files += sub.files
            } else {
                total.bytes += child.size ?? 0
                total.files += 1
            }
        }
        return total
    }
}
