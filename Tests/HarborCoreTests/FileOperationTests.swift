import Foundation
import Synchronization
import Testing
@testable import HarborCore

/// 每个测试一个沙盒：src、dst 两个目录，外加一个假的废纸篓
struct Sandbox {
    let root: URL
    let src: URL
    let dst: URL
    let trashDir: URL
    let fileSystem: FileSystem

    init(allowsClone: Bool = true) throws {
        root = try makeTempDir()
        src = root.appending(path: "src", directoryHint: .isDirectory)
        dst = root.appending(path: "dst", directoryHint: .isDirectory)
        trashDir = root.appending(path: "Trash", directoryHint: .isDirectory)
        for dir in [src, dst, trashDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let trash = trashDir
        fileSystem = FileSystem(trash: { url in
            let target = FileNaming.uniqueURL(for: trash.appending(path: url.lastPathComponent))
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, allowsClone: allowsClone)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ relative: String, in base: URL? = nil, _ text: String = "x") throws -> URL {
        let url = (base ?? src).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func transfer(_ mode: TransferMode, _ sources: [URL], to destination: URL? = nil,
                  answer: ConflictAnswer = ConflictAnswer(.stop)) async -> TransferResult {
        await FileTransfer(mode: mode, sources: sources, destination: destination ?? dst, fileSystem: fileSystem)
            .run { _ in answer }
    }
}

@Suite struct FileNamingTests {
    @Test func uniqueNames() {
        let taken: Set<String> = ["/d/a.txt", "/d/a 2.txt", "/d/folder", "/d/b 7.txt", "/d/.zshrc"]
        let isTaken = { (url: URL) in taken.contains(url.path) }
        #expect(FileNaming.uniqueURL(for: URL(filePath: "/d/a.txt"), isTaken: isTaken).lastPathComponent == "a 3.txt")
        #expect(FileNaming.uniqueURL(for: URL(filePath: "/d/folder"), isTaken: isTaken).lastPathComponent == "folder 2")
        #expect(FileNaming.uniqueURL(for: URL(filePath: "/d/b 7.txt"), isTaken: isTaken).lastPathComponent == "b 8.txt")
        #expect(FileNaming.uniqueURL(for: URL(filePath: "/d/.zshrc"), isTaken: isTaken).lastPathComponent == ".zshrc 2")
        #expect(FileNaming.uniqueURL(for: URL(filePath: "/d/new.txt"), isTaken: isTaken).lastPathComponent == "new.txt")
    }

    @Test func validation() {
        #expect(FileNaming.validationError(forNewName: "ok.txt") == nil)
        #expect(FileNaming.validationError(forNewName: "  ") != nil)
        #expect(FileNaming.validationError(forNewName: "a/b") != nil)
        #expect(FileNaming.validationError(forNewName: "..") != nil)
    }
}

@Suite struct FileTransferTests {
    @Test(arguments: [true, false])
    func copyFilesAndFolders(allowsClone: Bool) async throws {
        let box = try Sandbox(allowsClone: allowsClone)
        defer { box.cleanUp() }
        let file = try box.write("a.txt", "hello")
        try box.write("folder/inner/deep.txt", "deep")
        let link = box.src.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")

        let result = await box.transfer(.copy, [file, box.src.appending(path: "folder"), link])
        #expect(result.errors.isEmpty)
        #expect(box.read(box.dst.appending(path: "a.txt")) == "hello")
        #expect(box.read(box.dst.appending(path: "folder/inner/deep.txt")) == "deep")
        let copiedLink = try FileManager.default.destinationOfSymbolicLink(atPath: box.dst.appending(path: "link").path)
        #expect(copiedLink == "a.txt")
        // 源还在
        #expect(box.read(file) == "hello")
        #expect(result.destinations.count == 3)
    }

    @Test func copyIntoSameFolderMakesNumberedCopy() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let file = try box.write("a.txt")
        let result = await box.transfer(.copy, [file], to: box.src)
        #expect(box.names(box.src) == ["a 2.txt", "a.txt"])
        #expect(result.destinations.map(\.lastPathComponent) == ["a 2.txt"])
    }

    @Test func moveAndUndo() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.write("a.txt", "A")
        let folder = box.src.appending(path: "folder")
        try box.write("folder/b.txt", "B")

        let result = await box.transfer(.move, [a, folder])
        #expect(result.errors.isEmpty)
        #expect(box.names(box.src).isEmpty)
        #expect(box.names(box.dst) == ["a.txt", "folder"])

        let (inverse, errors) = FileActions.perform(result.undoSteps, fileSystem: box.fileSystem)
        #expect(errors.isEmpty)
        #expect(box.names(box.src) == ["a.txt", "folder"])
        #expect(box.names(box.dst).isEmpty)

        // 重做
        _ = FileActions.perform(inverse, fileSystem: box.fileSystem)
        #expect(box.names(box.dst) == ["a.txt", "folder"])
    }

    @Test func conflictDecisions() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.write("a.txt", "new")
        try box.write("a.txt", in: box.dst, "old")

        // 跳过
        var result = await box.transfer(.copy, [a], answer: ConflictAnswer(.skip))
        #expect(box.read(box.dst.appending(path: "a.txt")) == "old")
        #expect(result.destinations.isEmpty)

        // 保留两者
        result = await box.transfer(.copy, [a], answer: ConflictAnswer(.keepBoth))
        #expect(box.names(box.dst) == ["a 2.txt", "a.txt"])
        try FileManager.default.removeItem(at: box.dst.appending(path: "a 2.txt"))

        // 停止
        result = await box.transfer(.copy, [a], answer: ConflictAnswer(.stop))
        #expect(result.wasCancelled)

        // 替换：原有的进废纸篓，撤销后恢复
        result = await box.transfer(.copy, [a], answer: ConflictAnswer(.replace))
        #expect(box.read(box.dst.appending(path: "a.txt")) == "new")
        #expect(box.names(box.trashDir) == ["a.txt"])
        _ = FileActions.perform(result.undoSteps, fileSystem: box.fileSystem)
        #expect(box.read(box.dst.appending(path: "a.txt")) == "old")
    }

    @Test func applyToAllAsksOnce() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        var sources: [URL] = []
        for name in ["a", "b", "c"] {
            sources.append(try box.write(name))
            try box.write(name, in: box.dst)
        }
        let asked = Atomic<Int>(0)
        let result = await FileTransfer(mode: .copy, sources: sources, destination: box.dst, fileSystem: box.fileSystem).run { _ in
            asked.add(1, ordering: .relaxed)
            return ConflictAnswer(.keepBoth, applyToAll: true)
        }
        #expect(asked.load(ordering: .relaxed) == 1)
        #expect(result.destinations.count == 3)
        #expect(box.names(box.dst).count == 6)
    }

    /// 移动时内核本身也会拒绝；逐个文件拷贝时没有这个检查会无限递归，所以拷贝也要测
    @Test(arguments: [TransferMode.move, .copy])
    func refusesToPutFolderIntoItself(mode: TransferMode) async throws {
        let box = try Sandbox(allowsClone: false)
        defer { box.cleanUp() }
        let folder = box.src.appending(path: "folder")
        try box.write("folder/sub/x")
        let result = await box.transfer(mode, [folder], to: folder.appending(path: "sub"))
        #expect(result.errors.map(\.message) == ["不能放进它自己里面。"])
        #expect(box.names(folder.appending(path: "sub")) == ["x"])
    }

    @Test func refusesToReplaceFolderContainingSource() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        // 把 src/x/x 移到 src：目标 src/x 正是源的父目录
        let inner = try box.write("x/x")
        let result = await box.transfer(.move, [inner], to: box.src, answer: ConflictAnswer(.replace))
        #expect(result.errors.count == 1)
        #expect(box.names(box.trashDir).isEmpty)
        #expect(box.read(inner) == "x")
    }

    /// 文件夹拷到一半失败（中间有个没有读权限的文件），目标里不留半成品
    @Test func failedCopyCleansUpPartialFolder() async throws {
        let box = try Sandbox(allowsClone: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.src.appending(path: "folder/b.txt").path)
            box.cleanUp()
        }
        try box.write("folder/a.txt")
        let locked = try box.write("folder/b.txt")
        try box.write("folder/c.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        let result = await box.transfer(.copy, [box.src.appending(path: "folder")])
        #expect(result.errors.count == 1)
        #expect(box.names(box.dst).isEmpty)
    }

    @Test func cancelStopsBeforeNextItem() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.write("a.txt")
        let b = try box.write("b.txt")
        // 第二项开始时取消
        let holder = Mutex<FileTransfer?>(nil)
        let transfer = FileTransfer(mode: .copy, sources: [a, b], destination: box.dst, fileSystem: box.fileSystem) { progress in
            if progress.currentName == "b.txt" { holder.withLock { $0?.cancel() } }
        }
        holder.withLock { $0 = transfer }
        let result = await transfer.run { _ in ConflictAnswer(.stop) }
        #expect(result.wasCancelled)
        #expect(box.names(box.dst) == ["a.txt"])
        // 已完成的部分仍然可以撤销
        #expect(result.undoSteps == [.trash(box.dst.appending(path: "a.txt"))])
    }

    @Test func reportsProgress() async throws {
        let box = try Sandbox(allowsClone: false)
        defer { box.cleanUp() }
        let big = box.src.appending(path: "big.bin")
        try Data(count: 8 * 1024 * 1024).write(to: big)
        let last = Mutex<TransferProgress?>(nil)
        _ = await FileTransfer(mode: .copy, sources: [big], destination: box.dst, fileSystem: box.fileSystem) { progress in
            last.withLock { $0 = progress }
        }.run { _ in ConflictAnswer(.stop) }
        let final = try #require(last.withLock { $0 })
        #expect(final.totalBytes == 8 * 1024 * 1024)
        #expect(final.completedBytes == final.totalBytes)
        #expect(final.completedItems == 1)
    }
}

@Suite struct FileActionsTests {
    @Test func createRenameTrashAndUndo() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let folder = try FileActions.createFolder(in: box.src, name: "未命名文件夹")
        let second = try FileActions.createFolder(in: box.src, name: "未命名文件夹")
        #expect(second.lastPathComponent == "未命名文件夹 2")

        let renamed = try FileActions.rename(folder, to: "项目")
        #expect(box.names(box.src) == ["未命名文件夹 2", "项目"])
        // 只改大小写
        let file = try box.write("readme.md")
        let upper = try FileActions.rename(file, to: "README.md")
        #expect(box.names(box.src).contains("README.md"))
        // 重名报错
        #expect(throws: FileOperationError.self) { try FileActions.rename(upper, to: "项目") }

        let (undo, errors) = FileActions.trash([renamed], fileSystem: box.fileSystem)
        #expect(errors.isEmpty)
        #expect(!box.names(box.src).contains("项目"))
        _ = FileActions.perform(undo, fileSystem: box.fileSystem)
        #expect(box.names(box.src).contains("项目"))
    }

    /// 不区分大小写的卷上，撤销 readme.md → README.md 不能变成「readme 2.md」
    @Test func undoCaseOnlyRename() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let file = try box.write("readme.md")
        let renamed = try FileActions.rename(file, to: "README.md")
        let (inverse, errors) = FileActions.perform([.move(from: renamed, to: file)], fileSystem: box.fileSystem)
        #expect(errors.isEmpty)
        #expect(box.names(box.src) == ["readme.md"])
        _ = FileActions.perform(inverse, fileSystem: box.fileSystem)
        #expect(box.names(box.src) == ["README.md"])
    }

    @Test func undoRecreatesMissingParentAndAvoidsOverwrite() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let file = try box.write("sub/a.txt", "first")
        let (undo, _) = FileActions.trash([file], fileSystem: box.fileSystem)
        try FileManager.default.removeItem(at: box.src.appending(path: "sub"))
        _ = FileActions.perform(undo, fileSystem: box.fileSystem)
        #expect(box.read(file) == "first")

        // 原位置被占用时不覆盖
        let (undo2, _) = FileActions.trash([file], fileSystem: box.fileSystem)
        try box.write("sub/a.txt", "second")
        _ = FileActions.perform(undo2, fileSystem: box.fileSystem)
        #expect(box.names(box.src.appending(path: "sub")) == ["a 2.txt", "a.txt"])
        #expect(box.read(file) == "second")
    }
}
