import Foundation

/// 按条件找文件（Spotlight）：主页的分类卡片、最近打开、标签、自建的智能分类都用它。
/// 这里只负责把条件拼成 Spotlight 查询字符串，执行在界面层（NSMetadataQuery）
public struct SmartQuery: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case document, image, video, audio, archive

        public var title: String {
            switch self {
            case .document: "文档"
            case .image: "图片"
            case .video: "视频"
            case .audio: "音频"
            case .archive: "压缩包"
            }
        }

        /// 匹配 kMDItemContentTypeTree（类型及其所有上级类型）
        var contentTypes: [String] {
            switch self {
            case .document:
                // 不含 Markdown：开发项目（node_modules）里成千上万的 README 会淹没真正的文档
                ["com.adobe.pdf", "public.composite-content", "public.presentation", "public.spreadsheet", "public.rtf"]
            case .image: ["public.image"]
            // 不用 public.movie：.ts 源码文件被识别成 MPEG-2 传输流（属于 public.movie），开发机上有几十万个，
            // 先全拿出来再排除会很慢。直接列常见视频格式，每个都是一次索引查找
            case .video: ["public.mpeg-4", "com.apple.m4v-video", "com.apple.quicktime-movie", "public.avi", "public.mpeg",
                          "public.3gpp", "public.3gpp2", "com.microsoft.windows-media-wmv", "org.webmproject.webm",
                          "public.avchd-mpeg-2-transport-stream", "com.adobe.flash.video", "public.dv-movie"]
            case .audio: ["public.audio"]
            case .archive: ["public.archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive"]
            }
        }
    }

    public enum DateField: String, Codable, CaseIterable, Sendable {
        case modified, created, lastUsed

        public var title: String {
            switch self {
            case .modified: "修改日期"
            case .created: "创建日期"
            case .lastUsed: "最近打开"
            }
        }

        var attribute: String {
            switch self {
            case .modified: "kMDItemContentModificationDate"
            case .created: "kMDItemContentCreationDate"
            case .lastUsed: "kMDItemLastUsedDate"
            }
        }
    }

    public enum DateRange: String, Codable, CaseIterable, Sendable {
        case any, today, week, month, year

        public var title: String {
            switch self {
            case .any: "不限"
            case .today: "今天"
            case .week: "近 7 天"
            case .month: "近 30 天"
            case .year: "近一年"
            }
        }

        /// $time.today(-n)：今天零点往前 n 天
        var daysBack: Int? {
            switch self {
            case .any: nil
            case .today: 0
            case .week: 7
            case .month: 30
            case .year: 365
            }
        }
    }

    /// 文件名包含的文字（不区分大小写和变音符号），空表示不限
    public var keyword: String
    /// 空表示任意类型
    public var kinds: [Kind]
    /// Finder 标签名
    public var tag: String?
    public var dateField: DateField
    public var range: DateRange

    public init(keyword: String = "", kinds: [Kind] = [], tag: String? = nil,
                dateField: DateField = .modified, range: DateRange = .any) {
        self.keyword = keyword
        self.kinds = kinds
        self.tag = tag
        self.dateField = dateField
        self.range = range
    }

    /// 最近打开过的文件（主页）
    public static let recent = SmartQuery(dateField: .lastUsed, range: .month)

    public static func category(_ kind: Kind) -> SmartQuery {
        SmartQuery(kinds: [kind])
    }

    /// Spotlight 查询字符串，给 NSPredicate(fromMetadataQueryString:) 用。
    /// 文件夹不算结果（分类、最近都只要文件）
    public var metadataQueryString: String {
        var clauses = [#"kMDItemContentType != "public.folder""#]
        let types = kinds.flatMap(\.contentTypes)
        if !types.isEmpty {
            clauses.append("(" + types.map { #"kMDItemContentTypeTree == "\#($0)""# }.joined(separator: " || ") + ")")
        }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            clauses.append(#"kMDItemFSName == "*\#(Self.escape(trimmed))*"cd"#)
        }
        if let tag, !tag.isEmpty {
            clauses.append(#"kMDItemUserTags == "\#(Self.escape(tag))""#)
        }
        if let days = range.daysBack {
            clauses.append("\(dateField.attribute) >= $time.today(\(-days))")
        }
        return clauses.joined(separator: " && ")
    }

    /// 快速搜索：文件名包含这段文字（不区分大小写和变音符号），文件夹也算
    public static func nameSearchString(_ text: String) -> String {
        #"kMDItemFSName == "*\#(escape(text.trimmingCharacters(in: .whitespacesAndNewlines)))*"cd"#
    }

    /// 查询字符串里的引号、反斜杠、通配符 * 要转义，否则用户输入能改写查询
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "\"" || character == "*" { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// 自建的智能分类：名称 + 条件。智能更新开着时结果随文件变化自动刷新
public struct SmartCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var query: SmartQuery
    public var autoUpdate: Bool

    public init(id: UUID = UUID(), name: String, query: SmartQuery, autoUpdate: Bool = true) {
        self.id = id
        self.name = name
        self.query = query
        self.autoUpdate = autoUpdate
    }
}

public enum SpotlightFilter {
    /// Spotlight 结果里哪些值得给用户看：隐藏目录、node_modules、包内部（.app、照片图库……）里的文件不要
    public static func isBrowsable(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            if component.hasPrefix(".") || component == "node_modules" { return false }
            let isLast = index == components.count - 1
            if !isLast, let dot = component.lastIndex(of: "."),
               FileTypes.isPackageExtension(String(component[component.index(after: dot)...])) {
                return false
            }
        }
        return true
    }
}
