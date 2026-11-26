import Foundation
import Testing

@testable import CallCapture

@Suite("Range and Content-Disposition headers")
struct ServerHeaderTests {
    @Test("single byte ranges per RFC 9110; anything else serves the full body")
    func rangeParsing() {
        let size = 1000
        let cases: [(String?, HTTPRange)] = [
            (nil, .full),
            ("bytes=0-99", .partial(0...99)),
            ("bytes=100-", .partial(100...999)),
            ("bytes=-50", .partial(950...999)),
            ("bytes=-5000", .partial(0...999)),
            ("bytes=990-2000", .partial(990...999)),
            ("bytes=999-999", .partial(999...999)),
            ("BYTES=0-0", .partial(0...0)),
            ("bytes= 0-9 ", .partial(0...9)),
            ("bytes=1000-", .unsatisfiable),
            ("bytes=999999999-", .unsatisfiable),
            ("bytes=-0", .unsatisfiable),
            ("bytes=99999999999999999999999-", .unsatisfiable),
            ("bytes=0-99999999999999999999999", .partial(0...999)),
            ("bytes=-99999999999999999999999", .partial(0...999)),
            ("bytes=5-2", .full),
            ("bytes=0-1,5-6", .full),
            ("bytes=0-1, 5-6", .full),
            ("items=0-5", .full),
            ("bytes=abc", .full),
            ("bytes=", .full),
            ("bytes=-", .full),
            ("bytes=1-2-3", .full),
            ("bytes=+1-2", .full),
            ("bytes=0x10-", .full),
            ("bytes 0-5", .full),
        ]
        for (header, expected) in cases {
            #expect(HTTPRange.parse(header, size: size) == expected, "\(header ?? "nil")")
        }
    }

    @Test("an empty file has no satisfiable range")
    func emptyFileRanges() {
        #expect(HTTPRange.parse(nil, size: 0) == .full)
        #expect(HTTPRange.parse("bytes=0-", size: 0) == .unsatisfiable)
        #expect(HTTPRange.parse("bytes=-5", size: 0) == .unsatisfiable)
    }

    @Test("ASCII titles are sanitized into a quoted filename")
    func asciiDisposition() {
        #expect(ContentDisposition.attachment(title: "Weekly sync", fileExtension: "md")
            == #"attachment; filename="Weekly sync.md""#)
        #expect(ContentDisposition.attachment(title: "Q3 \"plan\": a/b\\c\r\nx", fileExtension: "md")
            == #"attachment; filename="Q3 -plan-- a-b-cx.md""#)
        #expect(ContentDisposition.attachment(title: "", fileExtension: "txt")
            == #"attachment; filename="session.txt""#)
        #expect(ContentDisposition.attachment(title: " \r\n\t", fileExtension: "md")
            == #"attachment; filename="session.md""#)
        let long = ContentDisposition.attachment(title: String(repeating: "a", count: 300), fileExtension: "md")
        #expect(long == "attachment; filename=\"\(String(repeating: "a", count: 100)).md\"")
    }

    @Test("non-ASCII titles add filename* with an ASCII fallback")
    func unicodeDisposition() throws {
        #expect(ContentDisposition.attachment(title: "План: Q3", fileExtension: "md")
            == #"attachment; filename="Plan- Q3.md"; filename*=UTF-8''%D0%9F%D0%BB%D0%B0%D0%BD-%20Q3.md"#)

        let ukrainian = ContentDisposition.attachment(title: "Зустріч з командою", fileExtension: "json")
        let parts = ukrainian.components(separatedBy: "; ")
        try #require(parts.count == 3)
        #expect(parts[0] == "attachment")
        #expect(parts[1].hasPrefix("filename=\"") && parts[1].hasSuffix(".json\""))
        let fallback = parts[1].dropFirst("filename=\"".count).dropLast()
        #expect(fallback.count > ".json".count)
        #expect(fallback.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" })
        #expect(parts[2].hasPrefix("filename*=UTF-8''"))
        #expect(parts[2].dropFirst("filename*=UTF-8''".count).removingPercentEncoding == "Зустріч з командою.json")

        let emoji = ContentDisposition.attachment(title: "🎉", fileExtension: "md")
        #expect(emoji == #"attachment; filename="session.md"; filename*=UTF-8''%F0%9F%8E%89.md"#)
    }
}
