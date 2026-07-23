//
//  FinancialJuiceFeedTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

final class FinancialJuiceFeedTests: XCTestCase {

    // MARK: - 历史响应解析

    /// 实测响应的最小重现：ASMX XML `<string>` 包 JSON 数组、
    /// 无时区 UTC 日期、小数秒位数不定。
    private let sampleXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <string xmlns="http://tempuri.org/">[\
    {"NewsID":9690606,"Title":"Canadian Core Retail Sales MoM Actual 1.2% (Forecast 1.3%)",\
    "DatePublished":"2026-07-23T12:30:01.523","PostedShort":"12:30","Breaking":false,\
    "Level":"news-general","EURL":"https://www.financialjuice.com/News/9690606"},\
    {"NewsID":9690607,"Title":"Fed&#39;s Powell: Rates &amp; policy on track","DatePublished":"2026-07-23T12:31:02.11",\
    "PostedShort":"12:31","Breaking":true,"Level":"news-critical","EURL":""},\
    {"NewsID":9690606,"Title":"Duplicate row","DatePublished":"2026-07-23T12:32:00","PostedShort":"12:32",\
    "Breaking":false,"Level":"","EURL":""}\
    ]</string>
    """

    func testParseHistoryResponse() throws {
        let items = try FinancialJuiceFeed.parseHistoryResponse(sampleXML)
        // 重复 NewsID 去重
        XCTAssertEqual(items.count, 2)

        let first = items[0]
        XCTAssertEqual(first.id, 9690606)
        XCTAssertFalse(first.critical)
        XCTAssertFalse(first.important)

        let powell = items[1]
        // 实体解码
        XCTAssertEqual(powell.title, "Fed's Powell: Rates & policy on track")
        XCTAssertTrue(powell.breaking)
        XCTAssertTrue(powell.critical)
        XCTAssertTrue(powell.important)

        // 无时区后缀按 UTC 解
        XCTAssertEqual(
            first.published,
            FinancialJuiceFeed.parseDate("2026-07-23T12:30:01.523")
        )
        let expected = ISO8601DateFormatter().date(from: "2026-07-23T12:30:01Z")
        XCTAssertEqual(first.published, expected)
    }

    /// WebSocket 推送的 msg 是裸 JSON 数组（无 XML 外壳），schema 同 history。
    func testParseRealtimePayload() throws {
        let payload = """
        [{"NewsID":9700001,"Title":"Fed cuts rates by 25bps","DatePublished":"2026-07-29T18:00:01.5",\
        "PostedShort":"18:00","Breaking":true,"Level":"news-critical","EURL":""}]
        """
        let items = try FinancialJuiceFeed.parseItemsJSON(payload)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].critical)
        XCTAssertThrowsError(try FinancialJuiceFeed.parseItemsJSON("not json"))
    }

    func testParseRejectsGarbage() {
        XCTAssertThrowsError(try FinancialJuiceFeed.parseHistoryResponse("<html>nope</html>"))
        XCTAssertThrowsError(try FinancialJuiceFeed.parseHistoryResponse(
            #"<string>[{"NewsID":0,"Title":"x","DatePublished":"2026-01-01T00:00:00"}]</string>"#
        ))
    }

    func testParseDateVariants() {
        XCTAssertNotNil(FinancialJuiceFeed.parseDate("2026-07-23T12:31:02.11"))
        XCTAssertNotNil(FinancialJuiceFeed.parseDate("2026-07-23T12:31:02.747"))
        XCTAssertNotNil(FinancialJuiceFeed.parseDate("2026-07-23T12:31:02"))
        XCTAssertNil(FinancialJuiceFeed.parseDate("not a date"))
    }

    func testDecodeEntities() {
        XCTAssertEqual(
            FinancialJuiceFeed.decodeEntities("S&amp;P 500 hits &#39;record&#39; &#x2014; up 1%"),
            "S&P 500 hits 'record' — up 1%"
        )
    }

    func testSanitizeForTranslation() {
        XCTAssertEqual(
            FinancialJuiceFeed.sanitizeForTranslation("Taiwan president meets US officials"),
            "Taiwan regional leader meets US officials"
        )
        XCTAssertEqual(
            FinancialJuiceFeed.sanitizeForTranslation("President of Taiwan speaks"),
            "leader of Taiwan region speaks"
        )
        XCTAssertEqual(
            FinancialJuiceFeed.sanitizeForTranslation("US President signs order"),
            "US President signs order"
        )
    }

    // MARK: - DeepSeek 响应解析

    func testDeepSeekParseComplete() {
        let content = #"{"translations":[{"id":1,"title":"标题一"},{"id":2,"title":"标题二"}]}"#
        let result = DeepSeekTranslationParser.parse(content, expectedIds: [1, 2], allowPartial: false)
        XCTAssertEqual(result, [1: "标题一", 2: "标题二"])
    }

    func testDeepSeekParseRejectsUnknownId() {
        // 幻觉出预期之外的 id → 整包拒收
        let content = #"{"translations":[{"id":99,"title":"幻觉"}]}"#
        XCTAssertNil(DeepSeekTranslationParser.parse(content, expectedIds: [1], allowPartial: true))
    }

    func testDeepSeekParsePartial() {
        let content = #"{"translations":[{"id":1,"title":"标题一"}]}"#
        // 严格模式：缺 id 2 → nil
        XCTAssertNil(DeepSeekTranslationParser.parse(content, expectedIds: [1, 2], allowPartial: false))
        // 宽松模式：部分成功可用
        XCTAssertEqual(
            DeepSeekTranslationParser.parse(content, expectedIds: [1, 2], allowPartial: true),
            [1: "标题一"]
        )
    }

    func testDeepSeekParseRejectsNonJSON() {
        XCTAssertNil(DeepSeekTranslationParser.parse("thinking…", expectedIds: [1], allowPartial: true))
        XCTAssertNil(DeepSeekTranslationParser.parse(#"{"translations":"nope"}"#, expectedIds: [1], allowPartial: true))
    }

    func testDeepSeekParseStringIds() {
        // 上游偶尔把 id 回成字符串
        let content = #"{"translations":[{"id":"7","title":"标题"}]}"#
        XCTAssertEqual(
            DeepSeekTranslationParser.parse(content, expectedIds: [7], allowPartial: false),
            [7: "标题"]
        )
    }
}
