import Foundation
import Testing
@testable import HarborCore

private func item(_ name: String, folder: Bool = false, size: Int64 = 0, modified: TimeInterval = 0) -> FileItem {
    FileItem(name: name, kind: folder ? .directory : .file, isPackage: false, isHidden: name.hasPrefix("."),
             size: folder ? nil : size, modified: Date(timeIntervalSince1970: modified), created: .distantPast)
}

@Suite struct FileSorterTests {
    @Test func nameOrderMatchesLocalizedStandardCompare() {
        let names = ["file10", "file2", "File1", "file1", "苹果", "香蕉", "阿姨", "_tmp", "-dash", "Zebra", "apple",
                     "Äpfel", "a b", "ab", "a.txt", "a-b", "a_b", "123", "9", "#hash", "~tilde", "é", "e", "f", "ée", "eé", "éa", "eb", "E", "中文2", "中文10"]
        let sorted = FileSorter.sorted(names.map { item($0) }, by: FileSortOrder(key: .name)).map(\.name)
        let expected = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        #expect(sorted == expected)
    }

    @Test func foldersFirstAndDescending() {
        let items = [item("b"), item("a"), item("z", folder: true), item("c", folder: true)]
        let asc = FileSorter.sorted(items, by: FileSortOrder(key: .name)).map(\.name)
        #expect(asc == ["c", "z", "a", "b"])
        let desc = FileSorter.sorted(items, by: FileSortOrder(key: .name, ascending: false)).map(\.name)
        #expect(desc == ["z", "c", "b", "a"])
        let mixed = FileSorter.sorted(items, by: FileSortOrder(key: .name, foldersFirst: false)).map(\.name)
        #expect(mixed == ["a", "b", "c", "z"])
    }

    @Test func sizeAndDateUseNameAsTieBreaker() {
        let items = [item("b", size: 10), item("a", size: 10), item("c", size: 5)]
        #expect(FileSorter.sorted(items, by: FileSortOrder(key: .size)).map(\.name) == ["c", "a", "b"])
        #expect(FileSorter.sorted(items, by: FileSortOrder(key: .size, ascending: false)).map(\.name) == ["a", "b", "c"])
        let dated = [item("x", modified: 3), item("y", modified: 1), item("z", modified: 2)]
        #expect(FileSorter.sorted(dated, by: FileSortOrder(key: .modified)).map(\.name) == ["y", "z", "x"])
    }

    @Test func arrangeFiltersHidden() {
        let items = [item(".git", folder: true), item("README")]
        #expect(FileSorter.arrange(items, showHidden: false, order: .init()).map(\.name) == ["README"])
        #expect(FileSorter.arrange(items, showHidden: true, order: .init()).count == 2)
    }

    @Test func emptyInput() {
        #expect(FileSorter.sorted([], by: .init()).isEmpty)
    }
}
