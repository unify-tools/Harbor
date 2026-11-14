import CArchive
import Darwin
import Foundation
import Synchronization

/// 压缩时可选的格式
public enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip, tarGz, tarXz, sevenZip

    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .tarGz: "tar.gz"
        case .tarXz: "tar.xz"
        case .sevenZip: "7z"
        }
    }

    public var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .tarGz: "tar.gz"
        case .tarXz: "tar.xz"
        case .sevenZip: "7z"
        }
    }
}

public enum ArchiveError: Error, Sendable, Equatable {
    case passwordRequired
    case wrongPassword
    case cancelled
    case failed(String)

    public var message: String {
        switch self {
        case .passwordRequired: "压缩包已加密，需要密码。"
        case .wrongPassword: "密码不正确。"
        case .cancelled: "已取消。"
        case .failed(let message): message
        }
    }
}

public struct ArchiveProgress: Sendable {
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    public var currentName = ""

    public init() {}

    public var fraction: Double {
        totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 1) : 0
    }
}

/// 从别的线程取消正在进行的压缩 / 解压
public final class ArchiveCancellation: Sendable {
    private let flag = Atomic<Bool>(false)
    public init() {}
    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// 用系统自带的 libarchive 压缩、解压。都是同步函数，调用方放到后台执行。
public enum Archives {
    /// 能解压的扩展名（长的在前，「a.tar.gz」先匹配 .tar.gz）
    private static let extractableSuffixes = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".tbz2", ".txz",
        ".tar", ".zip", ".7z", ".rar", ".cpio", ".gz", ".bz2", ".xz",
    ]

    public static func isExtractable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return extractableSuffixes.contains { name.hasSuffix($0) && name.count > $0.count }
    }

    /// 去掉压缩包的扩展名：「照片.tar.gz」→「照片」，「notes.txt.gz」→「notes.txt」
    public static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for suffix in extractableSuffixes where lower.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return (name as NSString).deletingPathExtension
    }

    // MARK: - 解压

    public struct ExtractResult: Sendable {
        /// 解出来的东西：单个顶层项目就是它本身，否则是以压缩包命名的文件夹
        public var output: URL
        /// 跳过的条目（不安全的路径、写入失败）
        public var skipped: [String]
    }

    /// 解压到 directory。先解到 directory 里的隐藏暂存目录，完成后再挪到位，取消或出错时整个删掉。
    /// 和「归档实用工具」一样：只有一个顶层项目就直接放出来，多个就放进以压缩包命名的文件夹。
    /// 拒绝绝对路径、带「..」的路径、穿过符号链接写入；压缩包带隔离属性时解出来的东西也带上。
    public static func extract(_ archive: URL, into directory: URL, password: String? = nil,
                               cancellation: ArchiveCancellation = ArchiveCancellation(),
                               progress: @Sendable (ArchiveProgress) -> Void = { _ in }) throws(ArchiveError) -> ExtractResult {
        let fm = FileManager.default
        // 暂存目录的路径不能含符号链接（/tmp → /private/tmp），否则 SECURE_SYMLINKS 会拒绝所有写入。
        // 不能用 resolvingSymlinksInPath：它会把 /private/var 反过来改成 /var
        guard let resolved = realpath(directory.path(percentEncoded: false), nil) else {
            throw .failed("无法访问「\(directory.lastPathComponent)」：\(String(cString: strerror(errno)))")
        }
        let realDirectory = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
        free(resolved)
        let staging = realDirectory.appending(path: ".harbor-extract-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard mkdir(staging.path(percentEncoded: false), 0o755) == 0 else {
            throw .failed("无法在「\(directory.lastPathComponent)」里创建文件：\(String(cString: strerror(errno)))")
        }
        var succeeded = false
        // 压缩包里可能有只读目录，普通删除删不掉
        defer { if !succeeded { forceRemove(staging) } }

        guard let reader = archive_read_new() else { throw .failed("libarchive 初始化失败") }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        // 不用 format_all：它带进的 mtree 会把只有一个单词的文本（比如解开后的 notes.txt.gz）当成文件清单
        archive_read_support_format_tar(reader)
        archive_read_support_format_zip(reader)
        archive_read_support_format_7zip(reader)
        archive_read_support_format_rar(reader)
        archive_read_support_format_rar5(reader)
        archive_read_support_format_cpio(reader)
        archive_read_support_format_iso9660(reader)
        archive_read_support_format_xar(reader)
        // 单个文件的 .gz / .bz2 / .xz
        archive_read_support_format_raw(reader)
        if let password { archive_read_add_passphrase(reader, password) }
        guard archive_read_open_filename(reader, archive.path(percentEncoded: false), 64 * 1024) == ARCHIVE_OK else {
            throw .failed("无法打开「\(archive.lastPathComponent)」：\(errorString(reader))")
        }

        guard let writer = archive_write_disk_new() else { throw .failed("libarchive 初始化失败") }
        defer { archive_write_free(writer) }
        archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_XATTR
            | ARCHIVE_EXTRACT_NO_OVERWRITE | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT)
        archive_write_disk_set_standard_lookup(writer)

        var state = ArchiveProgress()
        state.totalBytes = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let throttle = Throttle()
        var skipped: [String] = []
        let stagingPath = staging.path(percentEncoded: false)

        while true {
            if cancellation.isCancelled { throw .cancelled }
            var entryPointer: OpaquePointer?
            let status = archive_read_next_header(reader, &entryPointer)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN { throw readError(reader, password: password) }
            guard let entry = entryPointer else { break }

            var name = entryName(entry)
            if archive_format(reader) == ARCHIVE_FORMAT_RAW {
                // raw 只用来解单个文件的 .gz / .bz2 / .xz。没有经过任何解压过滤器（只有 none 一层）
                // 说明根本不是压缩包，不能当成「解出一个原样副本」
                guard archive_filter_count(reader) > 1 else {
                    throw .failed("「\(archive.lastPathComponent)」不是可识别的压缩包，或者已经损坏。")
                }
                name = baseName(of: archive)
            }
            // macOS 打包时附带的资源分支，解出来没用
            if name == "__MACOSX" || name.hasPrefix("__MACOSX/") {
                archive_read_data_skip(reader)
                continue
            }
            guard let relative = safeRelativePath(name) else {
                skipped.append(name)
                archive_read_data_skip(reader)
                continue
            }
            let encrypted = archive_entry_is_encrypted(entry) != 0
            if encrypted {
                // libarchive 能认出 7z、RAR 加了密，但只会解 zip 的加密
                guard archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_ZIP else {
                    let format = archive_format_name(reader).map { String(cString: $0) } ?? "这种"
                    throw .failed("暂不支持解压加密的 \(format) 压缩包。")
                }
                if password == nil { throw .passwordRequired }
            }

            archive_entry_update_pathname_utf8(entry, stagingPath + "/" + relative)
            if let hardlink = archive_entry_hardlink(entry) {
                guard let target = safeRelativePath(String(cString: hardlink)) else {
                    skipped.append(name)
                    archive_read_data_skip(reader)
                    continue
                }
                // 只链到本次已经解出来的普通文件。目标是符号链接、或者路径中间经过符号链接时，
                // 带数据的硬链接条目会顺着链接写到暂存目录外面。暂存路径本身不含符号链接，
                // 所以 realpath 不变就说明一路都是真实目录
                let targetPath = (stagingPath.hasSuffix("/") ? String(stagingPath.dropLast()) : stagingPath) + "/" + target
                var info = stat()
                guard lstat(targetPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      realPath(targetPath) == targetPath else {
                    skipped.append(name)
                    archive_read_data_skip(reader)
                    continue
                }
                archive_entry_copy_hardlink(entry, targetPath)
            }
            state.currentName = relative

            if archive_write_header(writer, entry) < ARCHIVE_WARN {
                skipped.append("\(relative)（\(errorString(writer, hiding: stagingPath))）")
                archive_read_data_skip(reader)
                continue
            }
            while true {
                if cancellation.isCancelled { throw .cancelled }
                var buffer: UnsafeRawPointer?
                var size = 0
                var offset: Int64 = 0
                let read = archive_read_data_block(reader, &buffer, &size, &offset)
                if read == ARCHIVE_EOF { break }
                if read < ARCHIVE_WARN {
                    // ZipCrypto 的密码校验只有 1 字节，约 1/256 的错密码能通过校验，到解码时才出错（CRC、解压失败）
                    throw encrypted && password != nil ? .wrongPassword : readError(reader, password: password)
                }
                if size > 0, let buffer {
                    let written = archive_write_data_block(writer, buffer, size, offset)
                    if written == ARCHIVE_WARN {
                        // NO_OVERWRITE 下同名条目（重复条目、只差大小写的 README / readme）写不进去：跳过这一项
                        skipped.append("\(relative)（已有同名项目）")
                        archive_read_data_skip(reader)
                        break
                    }
                    if written < 0 { throw .failed("写入「\(relative)」失败：\(errorString(writer, hiding: stagingPath))") }
                }
                state.completedBytes = archive_filter_bytes(reader, -1)
                if throttle.ready() { progress(state) }
            }
            if archive_write_finish_entry(writer) < ARCHIVE_WARN {
                throw .failed("写入「\(relative)」失败：\(errorString(writer, hiding: stagingPath))")
            }
        }
        // 目录的修改时间、权限在这里才写回去；磁盘写满这类延迟的错误也在这里报
        if archive_write_close(writer) < ARCHIVE_WARN {
            throw .failed("写入失败：\(errorString(writer, hiding: stagingPath))")
        }
        state.completedBytes = state.totalBytes
        progress(state)

        let top = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        guard !top.isEmpty else {
            throw skipped.isEmpty ? .failed("「\(archive.lastPathComponent)」是空的。") : .failed("没有可以安全解压的内容。")
        }
        // 隔离属性在挪到位之前设好；设不上（哪怕一项）就算失败，免得留下绕过 Gatekeeper 的文件
        if let quarantine = quarantineValue(of: archive) {
            try applyQuarantine(quarantine, to: stagingPath)
        }
        let output: URL
        if top.count == 1 {
            output = try place(top[0].path(percentEncoded: false), preferred: realDirectory.appending(path: top[0].lastPathComponent))
            rmdir(stagingPath)
        } else {
            output = try place(stagingPath, preferred: realDirectory.appending(path: baseName(of: archive), directoryHint: .isDirectory))
        }
        succeeded = true
        // 调用方按它看到的路径（可能含符号链接）比较，换回原目录下的同名路径
        return ExtractResult(output: directory.appending(path: output.lastPathComponent), skipped: skipped)
    }

    /// realpath(3)：解析所有符号链接；不存在时返回 nil
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 压缩包里的路径转成相对路径；绝对路径、含「..」的拒绝（返回 nil）
    static func safeRelativePath(_ name: String) -> String? {
        guard !name.hasPrefix("/") else { return nil }
        let components = name.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    private static func entryName(_ entry: OpaquePointer) -> String {
        if let utf8 = archive_entry_pathname_utf8(entry) { return String(cString: utf8) }
        if let raw = archive_entry_pathname(entry) { return String(cString: raw) }
        return ""
    }

    private static func readError(_ reader: OpaquePointer, password: String?) -> ArchiveError {
        let message = errorString(reader)
        if message.localizedCaseInsensitiveContains("passphrase") || message.localizedCaseInsensitiveContains("password") {
            return password == nil ? .passwordRequired : .wrongPassword
        }
        return .failed("读取压缩包失败：\(message)")
    }

    private static func errorString(_ archive: OpaquePointer, hiding prefix: String? = nil) -> String {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? "未知错误"
        // 错误信息里的暂存目录绝对路径对用户没意义
        guard let prefix else { return message }
        return message.replacingOccurrences(of: prefix + "/", with: "")
    }

    /// 把 path 挪到 preferred（重名加编号）。用 RENAME_EXCL：两个操作同时选中同一个名字时不会互相覆盖。
    /// 只读目录换父目录需要对它自己有写权限，临时加上，挪完恢复
    private static func place(_ path: String, preferred: URL) throws(ArchiveError) -> URL {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw .failed("无法放置解压结果：\(String(cString: strerror(errno)))") }
        let mode = info.st_mode & 0o7777
        let needsWrite = info.st_mode & S_IFMT == S_IFDIR && mode & S_IWUSR == 0
        if needsWrite { chmod(path, mode | S_IWUSR) }
        while true {
            let candidate = FileNaming.uniqueURL(for: preferred)
            if renamex_np(path, candidate.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 {
                if needsWrite { chmod(candidate.path(percentEncoded: false), mode) }
                return candidate
            }
            let code = errno
            guard code == EEXIST else {
                if needsWrite { chmod(path, mode) }
                throw .failed("无法放置解压结果：\(String(cString: strerror(code)))")
            }
        }
    }

    private static let quarantineName = "com.apple.quarantine"

    private static func quarantineValue(of archive: URL) -> [UInt8]? {
        let path = archive.path(percentEncoded: false)
        let length = getxattr(path, quarantineName, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var value = [UInt8](repeating: 0, count: length)
        guard getxattr(path, quarantineName, &value, length, 0, 0) == length else { return nil }
        return value
    }

    /// 和「归档实用工具」一样：压缩包是从网上下的（带 com.apple.quarantine），解出来的东西也都带上，Gatekeeper 照常检查。
    /// 只读的文件、目录（0444、0555 的 .app）临时加上权限再设，设完恢复；符号链接本身不执行，跳过
    static func applyQuarantine(_ value: [UInt8], to path: String) throws(ArchiveError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw .failed("无法设置隔离属性：\(String(cString: strerror(errno)))") }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { return }
        let mode = info.st_mode & 0o7777
        let needed: mode_t = type == S_IFDIR ? S_IRUSR | S_IWUSR | S_IXUSR : S_IWUSR
        let changed = mode & needed != needed
        if changed { chmod(path, mode | needed) }
        defer { if changed { chmod(path, mode) } }
        if type == S_IFDIR {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for child in children {
                try applyQuarantine(value, to: path + "/" + child)
            }
        }
        guard setxattr(path, quarantineName, value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw .failed("无法给「\((path as NSString).lastPathComponent)」设置隔离属性：\(String(cString: strerror(errno)))")
        }
    }

    /// 删除暂存目录。里面可能有只读目录（0555），先递归加上权限
    static func forceRemove(_ url: URL) {
        func unlock(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
            chmod(path, (info.st_mode & 0o7777) | S_IRWXU)
            for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                unlock(path + "/" + child)
            }
        }
        unlock(url.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 压缩

    /// 把 sources（同一目录下的项目）压缩到 directory。单个项目叫「名称.zip」，多个叫「归档.zip」，重名时加编号。
    /// 先写到隐藏的临时文件，完成后再改名；不收 .DS_Store；符号链接按链接本身保存。
    public static func create(_ sources: [URL], format: ArchiveFormat, in directory: URL,
                              cancellation: ArchiveCancellation = ArchiveCancellation(),
                              progress: @Sendable (ArchiveProgress) -> Void = { _ in }) throws(ArchiveError) -> URL {
        guard !sources.isEmpty else { throw .failed("没有要压缩的项目。") }
        let stem = sources.count == 1 ? sources[0].lastPathComponent : "归档"
        let temp = directory.appending(path: ".harbor-compress-\(UUID().uuidString).\(format.fileExtension)")
        var succeeded = false
        defer { if !succeeded { unlink(temp.path(percentEncoded: false)) } }

        // 先列出全部条目，算出总大小
        var items: [(path: String, relative: String, info: stat)] = []
        var state = ArchiveProgress()
        for source in sources {
            try collect(source.path(percentEncoded: false), relative: source.lastPathComponent, into: &items)
        }
        state.totalBytes = items.reduce(0) { ($1.info.st_mode & S_IFMT) == S_IFREG ? $0 + Int64($1.info.st_size) : $0 }

        guard let writer = archive_write_new() else { throw .failed("libarchive 初始化失败") }
        defer { archive_write_free(writer) }
        switch format {
        case .zip:
            archive_write_set_format_zip(writer)
            // 文件名按 UTF-8 存，并设上 UTF-8 标志，Windows 上中文名不乱码
            archive_write_set_options(writer, "zip:hdrcharset=UTF-8")
        case .tarGz:
            archive_write_set_format_pax_restricted(writer)
            archive_write_add_filter_gzip(writer)
        case .tarXz:
            archive_write_set_format_pax_restricted(writer)
            archive_write_add_filter_xz(writer)
        case .sevenZip:
            archive_write_set_format_7zip(writer)
        }
        guard archive_write_open_filename(writer, temp.path(percentEncoded: false)) == ARCHIVE_OK else {
            throw .failed("无法创建压缩文件：\(errorString(writer))")
        }

        guard let entry = archive_entry_new() else { throw .failed("libarchive 初始化失败") }
        defer { archive_entry_free(entry) }
        let throttle = Throttle()
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        for item in items {
            if cancellation.isCancelled { throw .cancelled }
            archive_entry_clear(entry)
            var info = item.info
            archive_entry_copy_stat(entry, &info)
            archive_entry_update_pathname_utf8(entry, item.relative)
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = readlink(item.path, &target, Int(PATH_MAX))
                guard length >= 0 else { throw .failed("读取链接「\(item.relative)」失败：\(String(cString: strerror(errno)))") }
                target[length] = 0
                archive_entry_copy_symlink(entry, target)
                archive_entry_set_size(entry, 0)
            } else if type != S_IFREG {
                archive_entry_set_size(entry, 0)
            }
            state.currentName = item.relative
            guard writeHeader(entry, to: writer) else {
                throw .failed("写入「\(item.relative)」失败：\(errorString(writer))")
            }
            if type == S_IFREG {
                let fd = open(item.path, O_RDONLY)
                guard fd >= 0 else { throw .failed("无法读取「\(item.relative)」：\(String(cString: strerror(errno)))") }
                defer { close(fd) }
                // 条目头里写的是列目录时的大小：最多读这么多（文件变大只收前面这部分），变小了就报错，不让 tar 拿零补齐
                var remaining = Int64(info.st_size)
                while remaining > 0 {
                    if cancellation.isCancelled { throw .cancelled }
                    let count = read(fd, buffer, Int(min(Int64(bufferSize), remaining)))
                    if count == 0 { throw .failed("「\(item.relative)」在压缩过程中变小了，请重试。") }
                    guard count > 0 else { throw .failed("读取「\(item.relative)」失败：\(String(cString: strerror(errno)))") }
                    remaining -= Int64(count)
                    guard archive_write_data(writer, buffer, count) == count else {
                        throw .failed("写入「\(item.relative)」失败：\(errorString(writer))")
                    }
                    state.completedBytes += Int64(count)
                    if throttle.ready() { progress(state) }
                }
            }
        }
        // zip 的中央目录、7z 的头都在关闭时才写
        guard archive_write_close(writer) == ARCHIVE_OK else {
            throw .failed("写入压缩文件失败：\(errorString(writer))")
        }
        // 结束时再挑名字，并且不覆盖：压缩期间别处放进来的同名文件、同时进行的另一次压缩都不会被盖掉
        var output: URL
        while true {
            output = uniqueURL(directory: directory, stem: stem, extension: format.fileExtension)
            if renamex_np(temp.path(percentEncoded: false), output.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 { break }
            let code = errno
            guard code == EEXIST else {
                throw .failed("无法保存「\(output.lastPathComponent)」：\(String(cString: strerror(code)))")
            }
        }
        succeeded = true
        progress(state)
        return output
    }

    private static func writeHeader(_ entry: OpaquePointer, to writer: OpaquePointer) -> Bool {
        archive_write_header(writer, entry) >= ARCHIVE_WARN
    }

    /// 递归列出条目（不跟随符号链接），目录在其内容之前
    private static func collect(_ path: String, relative: String,
                                into items: inout [(path: String, relative: String, info: stat)]) throws(ArchiveError) {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw .failed("无法读取「\(relative)」：\(String(cString: strerror(errno)))")
        }
        items.append((path, relative, info))
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        let children: [String]
        do {
            children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        } catch {
            throw .failed("无法读取「\(relative)」：\(error.localizedDescription)")
        }
        for child in children where child != ".DS_Store" {
            // socket、设备、FIFO 没法有意义地放进压缩包（zip 也存不了），跳过
            var childInfo = stat()
            if lstat(path + "/" + child, &childInfo) == 0 {
                let type = childInfo.st_mode & S_IFMT
                if type != S_IFREG, type != S_IFDIR, type != S_IFLNK { continue }
            }
            try collect(path + "/" + child, relative: relative + "/" + child, into: &items)
        }
    }

    /// 「名称.tar.gz」重名时生成「名称 2.tar.gz」（FileNaming 只认最后一段扩展名，会变成「名称.tar 2.gz」）
    static func uniqueURL(directory: URL, stem: String, extension ext: String) -> URL {
        var candidate = directory.appending(path: "\(stem).\(ext)")
        var number = 2
        while FileSystem.exists(candidate) {
            candidate = directory.appending(path: "\(stem) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

/// 进度最多每 50ms 汇报一次
private final class Throttle {
    private var last = ContinuousClock.now - .seconds(1)
    func ready() -> Bool {
        let now = ContinuousClock.now
        guard now - last >= .milliseconds(50) else { return false }
        last = now
        return true
    }
}
