import Foundation

/// 访问过的目录，按「频率 × 最近程度」排序（和 zoxide 的算法类似）。
/// 访问次数总和超过上限时整体打九折，掉到 1 以下的条目丢弃，这样老位置会慢慢淡出。
public struct VisitStore: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var count: Double
        public var lastVisit: Date
    }

    public private(set) var entries: [String: Entry] = [:]
    private var totalLimit: Double

    public init(totalLimit: Double = 2000) {
        self.totalLimit = totalLimit
    }

    public mutating func record(_ url: URL, at date: Date = .now) {
        let key = url.pathKey
        if var entry = entries[key] {
            entry.count += 1
            entry.lastVisit = date
            entries[key] = entry
        } else {
            entries[key] = Entry(path: key, count: 1, lastVisit: date)
        }
        let total = entries.values.reduce(0) { $0 + $1.count }
        if total > totalLimit {
            for other in entries.keys { entries[other]!.count *= 0.9 }
            // 刚访问的这一条即使掉到 1 以下也留着
            entries = entries.filter { $0.value.count >= 1 || $0.key == key }
        }
    }

    public mutating func remove(_ path: String) {
        entries[path] = nil
    }

    /// 最近一小时内访问过 ×4，一天内 ×2，一周内 ×0.5，更早 ×0.25
    public static func frecency(_ entry: Entry, now: Date) -> Double {
        let age = now.timeIntervalSince(entry.lastVisit)
        let weight: Double = age < 3600 ? 4 : age < 86400 ? 2 : age < 604_800 ? 0.5 : 0.25
        return entry.count * weight
    }

    /// 按 frecency 从高到低
    public func ranked(now: Date = .now) -> [(entry: Entry, frecency: Double)] {
        entries.values
            .map { ($0, Self.frecency($0, now: now)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }
    }
}

/// 快速跳转的排序：查询为空时纯按 frecency；否则模糊匹配目录名（权重高）和完整路径，再叠加 frecency。
public enum JumpRanking {
    public struct Result: Sendable {
        public let path: String
        public let score: Double
        /// 命中的字符在目录名里的位置；只匹配到上层路径时为空
        public let namePositions: [Int]
    }

    public static func rank(_ query: String, in store: VisitStore, now: Date = .now, limit: Int = 50) -> [Result] {
        var results: [Result] = []
        for (entry, frecency) in store.ranked(now: now) {
            let boost = log2(1 + frecency) * 4
            if query.isEmpty {
                results.append(Result(path: entry.path, score: boost, namePositions: []))
                continue
            }
            let name = (entry.path as NSString).lastPathComponent
            var best: Double?
            var positions: [Int] = []
            if let match = FuzzyMatcher.match(query, in: name) {
                best = Double(match.score + 20)
                positions = match.positions
            }
            if let keys = PinyinKeys.make(name) {
                for key in [keys.initials, keys.full] {
                    if let match = FuzzyMatcher.match(query, in: key), best == nil || Double(match.score + 20) > best! {
                        best = Double(match.score + 20)
                        positions = []
                    }
                }
            }
            if best == nil, let match = FuzzyMatcher.match(query, in: entry.path) {
                best = Double(match.score)
            }
            guard let best else { continue }
            results.append(Result(path: entry.path, score: best + boost, namePositions: positions))
        }
        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        return Array(results.prefix(limit))
    }
}
