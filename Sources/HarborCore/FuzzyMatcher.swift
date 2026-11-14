import Foundation
import Synchronization

/// 命令面板和快速跳转用的模糊匹配：查询的字符按顺序出现在候选里就算匹配。
/// 连续命中、命中词首（开头、分隔符后、大写字母）加分，中间跳过的字符扣分。
public enum FuzzyMatcher {
    public struct Match: Sendable, Equatable {
        public var score: Int
        /// 命中的字符在候选里的位置（按 Character 计），用来高亮
        public var positions: [Int]
    }

    /// 不匹配返回 nil。空查询匹配一切，得分 0。
    public static func match(_ query: String, in candidate: String) -> Match? {
        let pattern = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !pattern.isEmpty else { return Match(score: 0, positions: []) }
        let original = Array(candidate)
        let text = original.map { Character($0.lowercased()) }
        guard pattern.count <= text.count else { return nil }

        // 先确认是子序列，顺便找出最晚的可行起点
        var probe = 0
        for char in text where probe < pattern.count && char == pattern[probe] { probe += 1 }
        guard probe == pattern.count else { return nil }

        // 从每个可能的起点出发贪心匹配，取最高分。候选都很短（文件名、菜单标题），开销可以忽略。
        var best: Match?
        for start in text.indices where text[start] == pattern[0] {
            guard let match = greedy(pattern, text, original, from: start) else { break }
            if best == nil || match.score > best!.score { best = match }
        }
        return best
    }

    private static func greedy(_ pattern: [Character], _ text: [Character], _ original: [Character], from start: Int) -> Match? {
        var positions: [Int] = []
        positions.reserveCapacity(pattern.count)
        var index = start
        for char in pattern {
            while index < text.count, text[index] != char { index += 1 }
            guard index < text.count else { return nil }
            positions.append(index)
            index += 1
        }

        var score = 0
        for (offset, position) in positions.enumerated() {
            score += 1
            if isWordStart(position, original) { score += 8 }
            if offset > 0 {
                let gap = position - positions[offset - 1] - 1
                score += gap == 0 ? 5 : -min(gap, 3)
            }
        }
        // 越靠前越好
        score -= min(start, 10)
        return Match(score: score, positions: positions)
    }

    private static func isWordStart(_ index: Int, _ text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        if " /-_.·›".contains(previous) { return true }
        let current = text[index]
        return current.isUppercase && previous.isLowercase
    }
}

/// 中文的拼音检索键：「新建文件夹」→ 全拼 xinjianwenjianjia、首字母 xjwjj。
/// 不含中文时返回 nil。
public enum PinyinKeys {
    public struct Keys: Sendable, Equatable {
        public let full: String
        public let initials: String
    }

    /// 转换比较慢（每次几十微秒），按原文缓存
    private static let cache = Mutex<[String: Keys?]>([:])

    public static func make(_ text: String) -> Keys? {
        guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        if let cached = cache.withLock({ $0[text] }) { return cached }
        let keys = compute(text)
        cache.withLock { cache in
            if cache.count > 5000 { cache.removeAll() }
            cache[text] = keys
        }
        return keys
    }

    private static func compute(_ text: String) -> Keys? {
        guard let latin = text.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() else { return nil }
        // 转换后每个汉字的拼音之间有空格，非中文部分原样保留
        let syllables = latin.split(whereSeparator: { $0.isWhitespace })
        let full = syllables.joined()
        let initials = String(syllables.compactMap(\.first))
        return Keys(full: full, initials: initials)
    }
}
