import Foundation
import Testing
@testable import HarborCore

@Suite struct SmartQueryTests {
    @Test func buildsClauses() {
        let image = SmartQuery.category(.image).metadataQueryString
        #expect(image == #"kMDItemContentType != "public.folder" && (kMDItemContentTypeTree == "public.image")"#)

        let video = SmartQuery.category(.video).metadataQueryString
        #expect(video.hasSuffix(#"kMDItemContentType != "public.mpeg-2-transport-stream""#))

        let recent = SmartQuery.recent.metadataQueryString
        #expect(recent.hasSuffix("kMDItemLastUsedDate >= $time.today(-30)"))

        let full = SmartQuery(keyword: " 报告 ", kinds: [.document, .archive], tag: "红色", dateField: .created, range: .today)
            .metadataQueryString
        #expect(full.contains(#"kMDItemFSName == "*报告*"cd"#))
        #expect(full.contains(#"kMDItemContentTypeTree == "com.adobe.pdf" || "#))
        #expect(full.contains(#"kMDItemContentTypeTree == "public.archive""#))
        #expect(full.contains(#"kMDItemUserTags == "红色""#))
        #expect(full.contains("kMDItemContentCreationDate >= $time.today(0)"))
    }

    @Test func escapesUserInput() {
        // 引号、反斜杠、通配符都要转义，不能借关键词改写查询
        let query = SmartQuery(keyword: #"a"||kMDItemFSName=="*\x"#).metadataQueryString
        #expect(query.contains(#"kMDItemFSName == "*a\"||kMDItemFSName==\"\*\\x*"cd"#))
        #expect(NSPredicate(fromMetadataQueryString: query) != nil)
    }

    @Test func everyQueryParses() {
        // 系统真的能解析生成的字符串（拼错时这里返回 nil）
        var queries = SmartQuery.Kind.allCases.map(SmartQuery.category)
        queries.append(.recent)
        for range in SmartQuery.DateRange.allCases {
            for field in SmartQuery.DateField.allCases {
                queries.append(SmartQuery(keyword: "x", kinds: [.video], tag: "工作", dateField: field, range: range))
            }
        }
        for query in queries {
            #expect(NSPredicate(fromMetadataQueryString: query.metadataQueryString) != nil, "\(query.metadataQueryString)")
        }
    }

    @Test func nameSearch() {
        #expect(SmartQuery.nameSearchString(" 报告 ") == #"kMDItemFSName == "*报告*"cd"#)
        let tricky = SmartQuery.nameSearchString(#"a"*b"#)
        #expect(tricky == #"kMDItemFSName == "*a\"\*b*"cd"#)
        #expect(NSPredicate(fromMetadataQueryString: tricky) != nil)
    }

    @Test func codableRoundTrip() throws {
        let category = SmartCategory(name: "本周报告", query: SmartQuery(keyword: "报告", kinds: [.document], range: .week), autoUpdate: false)
        let decoded = try JSONDecoder().decode(SmartCategory.self, from: JSONEncoder().encode(category))
        #expect(decoded == category)
    }

    @Test func filtersUnbrowsablePaths() {
        #expect(SpotlightFilter.isBrowsable("/Users/me/Pictures/a.png"))
        #expect(SpotlightFilter.isBrowsable("/Users/me/Downloads/Harbor.app"))
        #expect(!SpotlightFilter.isBrowsable("/Users/me/.cache/a.png"))
        #expect(!SpotlightFilter.isBrowsable("/Users/me/code/x/node_modules/pkg/logo.png"))
        #expect(!SpotlightFilter.isBrowsable("/Users/me/Applications/Foo.app/Contents/Resources/icon.png"))
        #expect(!SpotlightFilter.isBrowsable("/Users/me/Pictures/Photos Library.photoslibrary/originals/1.jpg"))
    }
}
