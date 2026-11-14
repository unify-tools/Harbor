import Foundation
import Testing
@testable import HarborCore

/// 每个测试用自己的临时目录
func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "harbor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct DirectoryReaderTests {
    @Test func readsSameEntriesAsFileManager() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try Data(repeating: 1, count: 1234).write(to: dir.appending(path: "a.txt"))
        try Data().write(to: dir.appending(path: ".hidden"))
        try Data("x".utf8).write(to: dir.appending(path: "中文 文件.md"))
        try Data().write(to: dir.appending(path: "emoji😀.png"))
        // NFD 分解形式的 é
        try Data().write(to: dir.appending(path: "cafe\u{301}.txt"))
        try fm.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: false)
        try fm.createDirectory(at: dir.appending(path: "Demo.app"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: dir.appending(path: "link"), withDestinationURL: dir.appending(path: "sub"))

        let items = try DirectoryReader.read(dir)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        let expected = try fm.contentsOfDirectory(atPath: dir.path)
        #expect(Set(byName.keys) == Set(expected))

        #expect(byName["a.txt"]?.kind == .file)
        #expect(byName["a.txt"]?.size == 1234)
        #expect(byName["sub"]?.kind == .directory)
        #expect(byName["sub"]?.size == nil)
        #expect(byName["sub"]?.isFolder == true)
        #expect(byName["Demo.app"]?.isPackage == true)
        #expect(byName["Demo.app"]?.isFolder == false)
        #expect(byName["link"]?.kind == .symlink)
        #expect(byName[".hidden"]?.isHidden == true)
        #expect(byName["a.txt"]?.isHidden == false)

        let attrs = try fm.attributesOfItem(atPath: dir.appending(path: "a.txt").path)
        let modified = try #require(attrs[.modificationDate] as? Date)
        #expect(abs(byName["a.txt"]!.modified.timeIntervalSince(modified)) < 0.001)
    }

    @Test func honorsHiddenFlag() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var file = dir.appending(path: "flagged.txt")
        try Data().write(to: file)
        var values = URLResourceValues()
        values.isHidden = true
        try file.setResourceValues(values)
        let item = try #require(try DirectoryReader.read(dir).first)
        #expect(item.isHidden)
    }

    @Test func readsMoreThanOneBuffer() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 名字够长，保证一个 256KB 缓冲区装不下
        let longPrefix = String(repeating: "n", count: 200)
        for i in 0..<1500 {
            FileManager.default.createFile(atPath: dir.appending(path: "\(longPrefix)\(i)").path, contents: nil)
        }
        #expect(try DirectoryReader.read(dir).count == 1500)
    }

    @Test func reportsMissingDirectory() {
        let missing = URL(filePath: "/nonexistent-\(UUID().uuidString)")
        #expect {
            try DirectoryReader.read(missing)
        } throws: { error in
            (error as? DirectoryReadError)?.isMissing == true
        }
    }
}
