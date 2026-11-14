import CArchive
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HarborCore

@Suite struct ArchiveTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "harbor-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func dir(_ name: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func leftovers(in directory: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".harbor-") }
    }

    /// 一个有中文名、子目录、空目录、符号链接、大文件、.DS_Store 的目录
    private func makeTree(in parent: URL) throws -> URL {
        let project = parent.appending(path: "项目 A", directoryHint: .isDirectory)
        try write("你好", to: project.appending(path: "说明.txt"))
        try fm.createDirectory(at: project.appending(path: "sub"), withIntermediateDirectories: true)
        try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: project.appending(path: "sub/data.bin"))
        try fm.createDirectory(at: project.appending(path: "empty"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: project.appending(path: "link").path, withDestinationPath: "说明.txt")
        try write("junk", to: project.appending(path: ".DS_Store"))
        return project
    }

    @Test(arguments: ArchiveFormat.allCases) func roundTrip(format: ArchiveFormat) throws {
        let source = try dir("src")
        let project = try makeTree(in: source)
        let archive = try Archives.create([project], format: format, in: source)
        #expect(archive.lastPathComponent == "项目 A.\(format.fileExtension)")
        #expect(leftovers(in: source).isEmpty)

        let target = try dir("out")
        let result = try Archives.extract(archive, into: target)
        // 只有一个顶层项目：直接放出来
        #expect(result.output.lastPathComponent == "项目 A")
        #expect(result.skipped.isEmpty)
        let out = result.output
        #expect(try String(contentsOf: out.appending(path: "说明.txt"), encoding: .utf8) == "你好")
        #expect(try Data(contentsOf: out.appending(path: "sub/data.bin")) == Data(contentsOf: project.appending(path: "sub/data.bin")))
        #expect(try fm.destinationOfSymbolicLink(atPath: out.appending(path: "link").path) == "说明.txt")
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: out.appending(path: "empty").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(!fm.fileExists(atPath: out.appending(path: ".DS_Store").path))
        #expect(leftovers(in: target).isEmpty)
    }

    @Test func multipleItemsAndNaming() throws {
        let source = try dir("src")
        try write("a", to: source.appending(path: "a.txt"))
        try write("b", to: source.appending(path: "b.txt"))
        let items = [source.appending(path: "a.txt"), source.appending(path: "b.txt")]
        let first = try Archives.create(items, format: .tarGz, in: source)
        let second = try Archives.create(items, format: .tarGz, in: source)
        #expect(first.lastPathComponent == "归档.tar.gz")
        #expect(second.lastPathComponent == "归档 2.tar.gz")

        // 多个顶层项目：放进以压缩包命名的文件夹；重名时加编号
        let one = try Archives.extract(first, into: source)
        let two = try Archives.extract(first, into: source)
        #expect(one.output.lastPathComponent == "归档")
        #expect(two.output.lastPathComponent == "归档 2")
        #expect(try String(contentsOf: one.output.appending(path: "b.txt"), encoding: .utf8) == "b")
    }

    /// 用 libarchive 直接写一个带恶意路径的 tar
    private func makeTar(_ url: URL, entries: [(path: String, symlink: String?, content: String)]) throws {
        let writer = archive_write_new()!
        defer { archive_write_free(writer) }
        archive_write_set_format_pax_restricted(writer)
        #expect(archive_write_open_filename(writer, url.path) == ARCHIVE_OK)
        for item in entries {
            let entry = archive_entry_new()!
            defer { archive_entry_free(entry) }
            var info = stat()
            info.st_mode = (item.symlink == nil ? S_IFREG : S_IFLNK) | 0o644
            info.st_size = item.symlink == nil ? off_t(item.content.utf8.count) : 0
            archive_entry_copy_stat(entry, &info)
            archive_entry_copy_pathname(entry, item.path)
            if let symlink = item.symlink { archive_entry_copy_symlink(entry, symlink) }
            archive_write_header(writer, entry)
            if item.symlink == nil {
                let bytes = Array(item.content.utf8)
                _ = archive_write_data(writer, bytes, bytes.count)
            }
        }
        archive_write_close(writer)
    }

    @Test func refusesUnsafePaths() throws {
        let outside = try dir("outside")
        let target = try dir("target")
        let absolute = root.appending(path: "absolute.txt")
        let archive = root.appending(path: "evil.tar")
        try makeTar(archive, entries: [
            ("../escaped.txt", nil, "x"),
            ("ok/../../escaped2.txt", nil, "x"),
            (absolute.path, nil, "x"),
            ("ok.txt", nil, "fine"),
            // 先放一个指向外面的链接，再借它写进去
            ("link", outside.path, ""),
            ("link/inside.txt", nil, "x"),
        ])
        let result = try Archives.extract(archive, into: target)
        #expect(!fm.fileExists(atPath: root.appending(path: "escaped.txt").path))
        #expect(!fm.fileExists(atPath: root.appending(path: "escaped2.txt").path))
        #expect(!fm.fileExists(atPath: absolute.path))
        #expect(!fm.fileExists(atPath: outside.appending(path: "inside.txt").path))
        #expect(try String(contentsOf: result.output.appending(path: "ok.txt"), encoding: .utf8) == "fine")
        #expect(result.skipped.count == 4)
        #expect(leftovers(in: target).isEmpty)
    }

    private func run(_ tool: String, _ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func singleCompressedFile() throws {
        let source = try dir("src")
        try write("plain", to: source.appending(path: "notes.txt"))
        try run("/usr/bin/gzip", ["-k", "notes.txt"], in: source)
        let target = try dir("target")
        let result = try Archives.extract(source.appending(path: "notes.txt.gz"), into: target)
        #expect(result.output.lastPathComponent == "notes.txt")
        #expect(try String(contentsOf: result.output, encoding: .utf8) == "plain")
    }

    @Test func encryptedZip() throws {
        let source = try dir("src")
        try write("secret data", to: source.appending(path: "a.txt"))
        try run("/usr/bin/zip", ["-q", "-P", "pw123", "enc.zip", "a.txt"], in: source)
        let archive = source.appending(path: "enc.zip")
        let target = try dir("target")
        #expect(throws: ArchiveError.passwordRequired) { try Archives.extract(archive, into: target) }
        #expect(throws: ArchiveError.wrongPassword) { try Archives.extract(archive, into: target, password: "nope") }
        let result = try Archives.extract(archive, into: target, password: "pw123")
        #expect(try String(contentsOf: result.output, encoding: .utf8) == "secret data")
        #expect(leftovers(in: target).isEmpty)
    }

    @Test func cancellationAndCorruptInputLeaveNothing() throws {
        let source = try dir("src")
        let project = try makeTree(in: source)
        let cancelled = ArchiveCancellation()
        cancelled.cancel()
        #expect(throws: ArchiveError.cancelled) { try Archives.create([project], format: .zip, in: source, cancellation: cancelled) }
        #expect(leftovers(in: source).isEmpty)
        #expect(!fm.fileExists(atPath: source.appending(path: "项目 A.zip").path))

        let archive = try Archives.create([project], format: .zip, in: source)
        let target = try dir("target")
        #expect(throws: ArchiveError.cancelled) { try Archives.extract(archive, into: target, cancellation: cancelled) }
        #expect(leftovers(in: target).isEmpty)

        let corrupt = source.appending(path: "broken.zip")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: corrupt)
        #expect(throws: ArchiveError.self) { try Archives.extract(corrupt, into: target) }
        #expect(leftovers(in: target).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func quarantinePropagates() throws {
        let source = try dir("src")
        let project = try makeTree(in: source)
        let archive = try Archives.create([project], format: .zip, in: source)
        let value = Array("0081;00000000;Safari;".utf8)
        #expect(setxattr(archive.path, "com.apple.quarantine", value, value.count, 0, 0) == 0)
        let result = try Archives.extract(archive, into: try dir("target"))
        let file = result.output.appending(path: "sub/data.bin").path
        #expect(getxattr(file, "com.apple.quarantine", nil, 0, 0, 0) == value.count)
    }

    /// 带目录和权限的 tar
    private func makeTar(_ url: URL, items: [(path: String, mode: mode_t, content: String?)]) throws {
        let writer = archive_write_new()!
        defer { archive_write_free(writer) }
        archive_write_set_format_pax_restricted(writer)
        #expect(archive_write_open_filename(writer, url.path) == ARCHIVE_OK)
        for item in items {
            let entry = archive_entry_new()!
            defer { archive_entry_free(entry) }
            var info = stat()
            info.st_mode = (item.content == nil ? S_IFDIR : S_IFREG) | item.mode
            info.st_size = off_t(item.content?.utf8.count ?? 0)
            archive_entry_copy_stat(entry, &info)
            archive_entry_copy_pathname(entry, item.path)
            archive_write_header(writer, entry)
            if let content = item.content {
                let bytes = Array(content.utf8)
                _ = archive_write_data(writer, bytes, bytes.count)
            }
        }
        archive_write_close(writer)
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o7777
    }

    /// 只读的目录和文件（0555 的 .app、0444 的文件）：能放到位、都带上隔离属性、权限恢复原样
    @Test func readOnlyTreeGetsQuarantine() throws {
        let archive = root.appending(path: "ro.tar")
        try makeTar(archive, items: [("Evil.app", 0o555, nil), ("Evil.app/Contents", 0o555, nil),
                                     ("Evil.app/Contents/run", 0o555, "#!/bin/sh"), ("Evil.app/readme", 0o444, "hi")])
        let value = Array("0081;00000000;Safari;".utf8)
        #expect(setxattr(archive.path, "com.apple.quarantine", value, value.count, 0, 0) == 0)
        let target = try dir("target")
        let result = try Archives.extract(archive, into: target)
        let app = result.output
        #expect(app.lastPathComponent == "Evil.app")
        for path in ["", "Contents", "Contents/run", "readme"] {
            let url = path.isEmpty ? app : app.appending(path: path)
            #expect(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == value.count, "\(path) 没有隔离属性")
        }
        #expect(mode(app) == 0o555 && mode(app.appending(path: "Contents/run")) == 0o555 && mode(app.appending(path: "readme")) == 0o444)
        #expect(leftovers(in: target).isEmpty)
        Archives.forceRemove(app)
    }

    /// 只读目录后面跟着一个截断的条目：报错，并且暂存目录能删干净
    @Test func truncatedReadOnlyArchiveLeavesNothing() throws {
        let archive = root.appending(path: "trunc.tar")
        try makeTar(archive, items: [("top", 0o555, nil), ("top/big.txt", 0o644, String(repeating: "x", count: 50_000))])
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(atOffset: 20_000)
        try handle.close()
        let target = try dir("target")
        #expect(throws: ArchiveError.self) { try Archives.extract(archive, into: target) }
        #expect(leftovers(in: target).isEmpty)
    }

    /// 重复条目、只差大小写的条目（大小写不敏感的卷上同名）：跳过后面那个，其余照常解压
    @Test func duplicateEntriesAreSkipped() throws {
        let archive = root.appending(path: "dup.tar")
        try makeTar(archive, items: [("p", 0o755, nil), ("p/README", 0o644, "upper"), ("p/readme", 0o644, "lower"),
                                     ("p/a.txt", 0o644, "first"), ("p/a.txt", 0o644, "second"), ("p/ok.txt", 0o644, "ok")])
        let result = try Archives.extract(archive, into: try dir("target"))
        #expect(try String(contentsOf: result.output.appending(path: "ok.txt"), encoding: .utf8) == "ok")
        #expect(try String(contentsOf: result.output.appending(path: "a.txt"), encoding: .utf8) == "first")
        #expect(result.skipped.count == 2)
        #expect(result.skipped.allSatisfy { !$0.contains(".harbor-extract") })
    }

    /// 只有一个单词的文本压成 .gz：不能被当成 mtree 清单
    @Test func oneWordGzipKeepsContent() throws {
        let source = try dir("src")
        try write("hello\n", to: source.appending(path: "notes.txt"))
        try run("/usr/bin/gzip", ["notes.txt"], in: source)
        let result = try Archives.extract(source.appending(path: "notes.txt.gz"), into: try dir("target"))
        #expect(result.output.lastPathComponent == "notes.txt")
        #expect(try String(contentsOf: result.output, encoding: .utf8) == "hello\n")
    }

    /// 同时压缩同一个文件：各得各的名字，不互相覆盖
    @Test func concurrentCompressionDoesNotOverwrite() throws {
        let source = try dir("src")
        try Data(count: 5_000_000).write(to: source.appending(path: "big.bin"))
        let item = source.appending(path: "big.bin")
        let outputs = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            if let url = try? Archives.create([item], format: .zip, in: source) {
                outputs.withLock { $0.append(url.lastPathComponent) }
            }
        }
        let names = outputs.withLock { $0 }
        #expect(Set(names) == ["big.bin.zip", "big.bin 2.zip", "big.bin 3.zip"])
        #expect(names.allSatisfy { fm.fileExists(atPath: source.appending(path: $0).path) })
    }

    @Test func namesAndDetection() {
        #expect(Archives.baseName(of: URL(filePath: "/x/照片.tar.gz")) == "照片")
        #expect(Archives.baseName(of: URL(filePath: "/x/notes.txt.gz")) == "notes.txt")
        #expect(Archives.baseName(of: URL(filePath: "/x/a.ZIP")) == "a")
        #expect(Archives.isExtractable(URL(filePath: "/x/a.7z")))
        #expect(!Archives.isExtractable(URL(filePath: "/x/a.txt")))
        #expect(!Archives.isExtractable(URL(filePath: "/x/.zip")))
        #expect(Archives.safeRelativePath("./a//b/") == "a/b")
        #expect(Archives.safeRelativePath("a/../b") == nil)
        #expect(Archives.safeRelativePath("/etc/passwd") == nil)
    }
}
