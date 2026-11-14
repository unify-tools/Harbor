import Foundation
import Testing
@testable import HarborCore

@Suite struct FuzzyMatcherTests {
    @Test func subsequenceAndCase() {
        #expect(FuzzyMatcher.match("dl", in: "Downloads") != nil)
        #expect(FuzzyMatcher.match("DOWN", in: "Downloads")?.positions == [0, 1, 2, 3])
        #expect(FuzzyMatcher.match("dx", in: "Downloads") == nil)
        #expect(FuzzyMatcher.match("", in: "anything")?.score == 0)
        // 空格忽略
        #expect(FuzzyMatcher.match("new f", in: "New Folder") != nil)
    }

    @Test func prefersWordStartsAndRuns() {
        let start = FuzzyMatcher.match("pro", in: "projects")!.score
        let middle = FuzzyMatcher.match("pro", in: "reproduce")!.score
        #expect(start > middle)
        // 取最好的起点，而不是第一个出现的位置
        let match = FuzzyMatcher.match("src", in: "resources/src")!
        #expect(match.positions == [10, 11, 12])
        // 驼峰的大写字母算词首
        #expect(FuzzyMatcher.match("fs", in: "FileSystem")!.positions == [0, 4])
    }

    @Test func pinyinKeys() {
        let keys = PinyinKeys.make("新建文件夹")
        #expect(keys?.full == "xinjianwenjianjia")
        #expect(keys?.initials == "xjwjj")
        #expect(PinyinKeys.make("Downloads") == nil)
        // 第二次走缓存，结果一致
        #expect(PinyinKeys.make("新建文件夹") == keys)
    }
}

@Suite struct VisitStoreTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func countsAndRecency() {
        var store = VisitStore()
        let a = URL(filePath: "/a"), b = URL(filePath: "/b/")
        store.record(a, at: now.addingTimeInterval(-30 * 86400))
        store.record(a, at: now.addingTimeInterval(-30 * 86400))
        store.record(a, at: now.addingTimeInterval(-30 * 86400))
        store.record(b, at: now.addingTimeInterval(-60))
        // 末尾斜杠归一
        #expect(store.entries["/b"]?.count == 1)
        // a：3 次 × 0.25 = 0.75；b：1 次 × 4 = 4
        #expect(store.ranked(now: now).map(\.entry.path) == ["/b", "/a"])
    }

    @Test func agingDropsRareEntries() {
        var store = VisitStore(totalLimit: 10)
        store.record(URL(filePath: "/once"), at: now)
        for _ in 0..<10 { store.record(URL(filePath: "/often"), at: now) }
        // 总数 11 > 10：全部 ×0.9，/once 掉到 0.9 被丢弃
        #expect(store.entries["/once"] == nil)
        #expect(store.entries["/often"]!.count == 9)
        // 触发衰减的那次新访问本身不会被丢掉
        store.record(URL(filePath: "/new"), at: now)
        store.record(URL(filePath: "/new2"), at: now)
        #expect(store.entries["/new2"] != nil)
    }

    @Test func codableRoundTrip() throws {
        var store = VisitStore()
        store.record(URL(filePath: "/x"), at: now)
        let decoded = try JSONDecoder().decode(VisitStore.self, from: JSONEncoder().encode(store))
        #expect(decoded == store)
    }

    @Test func jumpRanking() {
        var store = VisitStore()
        for _ in 0..<5 { store.record(URL(filePath: "/Users/me/work/harbor"), at: now) }
        store.record(URL(filePath: "/Users/me/Downloads/harbor-old"), at: now)
        store.record(URL(filePath: "/Users/me/work"), at: now)
        store.record(URL(filePath: "/Users/me/文档/项目"), at: now)

        // 空查询：按 frecency
        #expect(JumpRanking.rank("", in: store, now: now).first?.path == "/Users/me/work/harbor")
        // 名字匹配排在只有上层路径匹配的前面
        let harbor = JumpRanking.rank("harb", in: store, now: now).map(\.path)
        #expect(harbor.prefix(2) == ["/Users/me/work/harbor", "/Users/me/Downloads/harbor-old"])
        let work = JumpRanking.rank("work", in: store, now: now)
        #expect(work.first?.path == "/Users/me/work")
        #expect(work.first?.namePositions == [0, 1, 2, 3])
        // 拼音首字母
        #expect(JumpRanking.rank("xm", in: store, now: now).first?.path == "/Users/me/文档/项目")
        #expect(JumpRanking.rank("zzz", in: store, now: now).isEmpty)
    }
}
