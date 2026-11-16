import Foundation
import Testing
@testable import HarborCore

@Suite struct FileGrouperTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    /// 2026-11-16 15:00（上海）
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15))! }

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: now)! }

    private func file(_ name: String, modified: Date? = nil, size: Int64? = 10, folder: Bool = false) -> FileItem {
        FileItem(name: name, kind: folder ? .directory : .file, isPackage: false, isHidden: false,
                 size: folder ? nil : size, modified: modified ?? now, created: now)
    }

    private func group(_ items: [FileItem], _ grouping: FileGrouping) -> [String: [String]] {
        let (arranged, groups) = FileGrouper.group(items, by: grouping, in: URL(filePath: "/tmp"), now: now, calendar: calendar)
        return Dictionary(uniqueKeysWithValues: groups.map { ($0.title, arranged[$0.range].map(\.name)) })
    }

    @Test func noneKeepsOrder() {
        let items = [file("b"), file("a")]
        let (arranged, groups) = FileGrouper.group(items, by: .none, in: URL(filePath: "/tmp"))
        #expect(arranged == items && groups.isEmpty)
    }

    @Test func dateBuckets() {
        let items = [file("old", modified: calendar.date(from: DateComponents(year: 2024, month: 3, day: 1))!),
                     file("today", modified: day(0)), file("yesterday", modified: day(1)),
                     file("week", modified: day(5)), file("month", modified: day(20)),
                     file("thisYear", modified: calendar.date(from: DateComponents(year: 2026, month: 2, day: 3))!)]
        let (arranged, groups) = FileGrouper.group(items, by: .modified, in: URL(filePath: "/tmp"), now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["今天", "昨天", "过去 7 天", "过去 30 天", "2 月", "2024 年"])
        #expect(arranged.map(\.name) == ["today", "yesterday", "week", "month", "thisYear", "old"])
    }

    @Test func nameInitials() {
        let groups = group([file("banana"), file("Apple"), file("新建文件夹"), file("123"), file("_x"), file("apricot")], .name)
        #expect(groups["A"] == ["Apple", "apricot"])
        #expect(groups["B"] == ["banana"])
        #expect(groups["X"] == ["新建文件夹"])
        #expect(groups["0–9"] == ["123"])
        #expect(groups["#"] == ["_x"])
        let (_, ordered) = FileGrouper.group([file("_x"), file("123"), file("b"), file("a")], by: .name, in: URL(filePath: "/tmp"))
        #expect(ordered.map(\.title) == ["A", "B", "0–9", "#"])
    }

    @Test func sizeBuckets() {
        let (arranged, groups) = FileGrouper.group(
            [file("small", size: 50_000), file("dir", folder: true), file("big", size: 2_000_000_000), file("mid", size: 5_000_000), file("empty", size: 0)],
            by: .size, in: URL(filePath: "/tmp"))
        #expect(groups.map(\.title) == ["大于 1 GB", "1 MB – 100 MB", "小于 100 KB", "零字节", FileGrouper.folderTitle])
        #expect(arranged.map(\.name) == ["big", "mid", "small", "empty", "dir"])
    }

    @Test func rangesAreContiguousAndStable() {
        // 组内保持传入的顺序（已经按排序规则排好）
        let items = (0..<50).map { file("f\($0)", modified: day($0 % 3 == 0 ? 0 : 40)) }
        let (arranged, groups) = FileGrouper.group(items, by: .modified, in: URL(filePath: "/tmp"), now: now, calendar: calendar)
        #expect(groups.first?.range.lowerBound == 0 && groups.last?.range.upperBound == arranged.count)
        for (a, b) in zip(groups, groups.dropFirst()) { #expect(a.range.upperBound == b.range.lowerBound) }
        let today = arranged[groups[0].range].map(\.name)
        #expect(today == items.filter { Int($0.name.dropFirst())! % 3 == 0 }.map(\.name))
    }

    @Test func applicationUsesProvider() {
        let groups = group([file("a.txt"), file("b.md"), file("dir", folder: true)], .application)
        // 默认 provider 返回空字符串，归到「其他」；文件夹单独一组
        #expect(groups["其他"]?.count == 2 && groups[FileGrouper.folderTitle] == ["dir"])
    }
}
