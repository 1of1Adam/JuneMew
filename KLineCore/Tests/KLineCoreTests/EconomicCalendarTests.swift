//
//  EconomicCalendarTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

final class EconomicCalendarTests: XCTestCase {

    // MARK: - 解码

    /// 实测上游响应的最小重现：字段名、可空性、日期格式都以真实 API 为准。
    private let sampleJSON = """
    {
        "status": "ok",
        "result": [
            {
                "id": "396328",
                "title": "MBA 30-Year Mortgage Rate",
                "country": "US",
                "indicator": "Mortgage Rate",
                "comment": "Average 30-year fixed mortgage lending rate.",
                "period": "Jul/17",
                "source": "MBA",
                "actual": 6.69,
                "previous": 6.65,
                "forecast": null,
                "actualRaw": 6.69,
                "previousRaw": 6.65,
                "forecastRaw": null,
                "currency": "USD",
                "unit": "%",
                "importance": 0,
                "date": "2026-07-22T11:00:00.000Z"
            },
            {
                "id": "396400",
                "title": "Fed Chair Speech",
                "country": "US",
                "indicator": "Fed Speech",
                "currency": "USD",
                "importance": 1,
                "date": "2026-07-22T17:30:00Z"
            }
        ]
    }
    """

    func testDecodeRealisticFeed() throws {
        let events = try EconomicCalendarFeed.decode(Data(sampleJSON.utf8))
        XCTAssertEqual(events.count, 2)

        let mba = events[0]
        XCTAssertEqual(mba.id, "396328")
        XCTAssertEqual(mba.importance, .medium)
        XCTAssertEqual(mba.actual, 6.69)
        XCTAssertNil(mba.forecast)
        XCTAssertEqual(mba.unit, "%")
        XCTAssertTrue(mba.hasNumericContent)
        XCTAssertEqual(
            mba.date,
            EconomicCalendarFeed.parseDate("2026-07-22T11:00:00.000Z")
        )

        // 讲话类事件：无任何数值，且日期不带毫秒也要能解析
        let speech = events[1]
        XCTAssertEqual(speech.importance, .high)
        XCTAssertFalse(speech.hasNumericContent)
        XCTAssertNotNil(EconomicCalendarFeed.parseDate("2026-07-22T17:30:00Z"))
    }

    /// 裸字段是与 scale 配套的已缩放显示值（1.41 + "M"），Raw 是未缩放
    /// 标量（1410000）—— 裸值必须赢，Raw 只兜底。实测数据：
    /// Building Permits {previous: 1.41, previousRaw: 1410000, scale: "M"}。
    func testBareValuesTakePrecedenceOverRaw() throws {
        let json = """
        {"status":"ok","result":[{
            "id":"1","title":"Building Permits Final","importance":0,
            "date":"2026-07-24T12:00:00.000Z","scale":"M",
            "previous":1.41,"previousRaw":1410000,
            "forecast":1.367,"forecastRaw":1367000,
            "actual":null,"actualRaw":null
        }]}
        """
        let events = try EconomicCalendarFeed.decode(Data(json.utf8))
        XCTAssertEqual(events[0].previous, 1.41)
        XCTAssertEqual(events[0].forecast, 1.367)
        XCTAssertNil(events[0].actual)
        XCTAssertEqual(
            EconomicCalendarFeed.formatValue(
                events[0].previous, unit: events[0].unit, scale: events[0].scale
            ),
            "1.41M"
        )

        // 裸字段缺失时兜底用 Raw
        let fallback = """
        {"status":"ok","result":[{
            "id":"2","title":"GDP","importance":1,
            "date":"2026-07-30T12:30:00.000Z",
            "forecast":null,"forecastRaw":2.0
        }]}
        """
        let events2 = try EconomicCalendarFeed.decode(Data(fallback.utf8))
        XCTAssertEqual(events2[0].forecast, 2.0)
    }

    func testDecodeRejectsBadStatus() {
        let json = #"{"status":"error","result":[]}"#
        XCTAssertThrowsError(try EconomicCalendarFeed.decode(Data(json.utf8))) { error in
            XCTAssertEqual(
                error as? EconomicCalendarFeed.DecodeError,
                .upstreamStatus("error")
            )
        }
    }

    /// 单条事件字段非法 → 整包失败。残缺日历比没有日历更危险。
    func testDecodeRejectsMalformedEvent() {
        let json = """
        {"status":"ok","result":[
            {"id":"1","title":"CPI","importance":1,"date":"2026-07-30T12:30:00.000Z"},
            {"id":"2","title":"PPI","importance":7,"date":"2026-07-30T12:30:00.000Z"}
        ]}
        """
        XCTAssertThrowsError(try EconomicCalendarFeed.decode(Data(json.utf8))) { error in
            guard case let .malformedEvent(index, _)? = error as? EconomicCalendarFeed.DecodeError else {
                return XCTFail("expected malformedEvent, got \(error)")
            }
            XCTAssertEqual(index, 1)
        }
    }

    func testDecodeRejectsNonJSON() {
        XCTAssertThrowsError(try EconomicCalendarFeed.decode(Data("<html>".utf8)))
    }

    // MARK: - 格式化

    func testFormatValuePrecisionLadder() {
        // ≥100：免小数、带千分位
        XCTAssertEqual(EconomicCalendarFeed.formatValue(1234.5, unit: nil, scale: nil), "1,234")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(264, unit: nil, scale: nil), "264")
        // 10–100：一位
        XCTAssertEqual(EconomicCalendarFeed.formatValue(48.55, unit: nil, scale: nil), "48.6")
        // <10：两位，但不补零
        XCTAssertEqual(EconomicCalendarFeed.formatValue(6.69, unit: "%", scale: nil), "6.69%")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(2.5, unit: "%", scale: nil), "2.5%")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(-0.257, unit: "%", scale: nil), "-0.26%")
    }

    func testFormatValueTails() {
        XCTAssertEqual(EconomicCalendarFeed.formatValue(nil, unit: "%", scale: nil), "–")
        // scale 紧贴数字（数量级），unit 空格隔开（计量单位）
        XCTAssertEqual(EconomicCalendarFeed.formatValue(208, unit: nil, scale: "K"), "208K")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(0.58, unit: nil, scale: "M"), "0.58M")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(-79.5, unit: nil, scale: "B"), "-79.5B")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(226, unit: "K", scale: nil), "226 K")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(1.2, unit: "USD", scale: "M"), "1.2M USD")
        // scale "units" 是上游的「无缩放」哨兵，不显示
        XCTAssertEqual(EconomicCalendarFeed.formatValue(50.3, unit: nil, scale: "units"), "50.3")
    }

    /// 无单位大数自动缩写 —— Jobless Claims 208000 必须显示成 "208K"
    /// 而不是撑爆列宽的 "208,000"。
    func testFormatValueAutoCompact() {
        XCTAssertEqual(EconomicCalendarFeed.formatValue(208_000, unit: nil, scale: nil), "208K")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(580_000, unit: nil, scale: nil), "580K")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(12_500, unit: nil, scale: nil), "12.5K")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(1_250_000, unit: nil, scale: nil), "1.25M")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(21_400_000_000, unit: nil, scale: nil), "21.4B")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(-45_000, unit: nil, scale: nil), "-45K")
        // 阈值之下与带单位的都不缩写
        XCTAssertEqual(EconomicCalendarFeed.formatValue(9_999, unit: nil, scale: nil), "9,999")
        XCTAssertEqual(EconomicCalendarFeed.formatValue(208_000, unit: "K", scale: nil), "208,000 K")
    }

    // MARK: - Surprise

    func testSurprise() {
        XCTAssertNil(EconomicSurprise.compute(actual: nil, forecast: 2.0))
        XCTAssertNil(EconomicSurprise.compute(actual: 2.0, forecast: nil))

        let flat = EconomicSurprise.compute(actual: 2.0, forecast: 2.0)
        XCTAssertEqual(flat?.sign, .flat)

        let beat = EconomicSurprise.compute(actual: 2.6, forecast: 2.5)
        XCTAssertEqual(beat?.sign, .up)
        XCTAssertEqual(beat!.isLarge, false)

        let bigMiss = EconomicSurprise.compute(actual: 150, forecast: 200)
        XCTAssertEqual(bigMiss?.sign, .down)
        XCTAssertEqual(bigMiss!.isLarge, true)

        // forecast 为 0：用绝对差判 large（变化率类指标）
        let fromZero = EconomicSurprise.compute(actual: 0.05, forecast: 0)
        XCTAssertEqual(fromZero?.sign, .up)
        XCTAssertEqual(fromZero!.isLarge, false)
    }

    // MARK: - ET 分组

    private func event(id: String, iso: String, importance: EconomicImportance = .medium) -> EconomicEvent {
        EconomicEvent(
            id: id, title: "E\(id)", indicator: "", country: "US", currency: "USD",
            date: EconomicCalendarFeed.parseDate(iso)!,
            importance: importance, period: "",
            previous: nil, forecast: nil, actual: nil,
            unit: nil, scale: nil, comment: nil
        )
    }

    func testGroupByETDaySplitsAtETMidnight() {
        // UTC 03:00 = ET 前一天 23:00（夏令时 UTC-4）；UTC 05:00 = ET 当天 01:00
        let lateNight = event(id: "a", iso: "2026-07-23T03:00:00Z")   // ET Jul 22 23:00
        let earlyMorning = event(id: "b", iso: "2026-07-23T05:00:00Z") // ET Jul 23 01:00

        let groups = EconomicCalendarFeed.groupByETDay([earlyMorning, lateNight])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].events.map(\.id), ["a"])
        XCTAssertEqual(groups[1].events.map(\.id), ["b"])
        XCTAssertLessThan(groups[0].dayStart, groups[1].dayStart)
    }

    func testGroupOrdersByTimeThenImportance() {
        // 08:30 ET 同时发布：high 必须排在 medium 前
        let minor = event(id: "minor", iso: "2026-07-23T12:30:00Z", importance: .medium)
        let major = event(id: "major", iso: "2026-07-23T12:30:00Z", importance: .high)
        let later = event(id: "later", iso: "2026-07-23T14:00:00Z", importance: .high)

        let groups = EconomicCalendarFeed.groupByETDay([later, minor, major])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].events.map(\.id), ["major", "minor", "later"])
    }

    // MARK: - 倒计时文案

    func testFormatCountdown() {
        let now = EconomicCalendarFeed.parseDate("2026-07-23T12:00:00Z")!
        func at(_ seconds: TimeInterval) -> String {
            EconomicCalendarFeed.formatCountdown(to: now.addingTimeInterval(seconds), now: now)
        }
        XCTAssertEqual(at(-10), "即将")
        XCTAssertEqual(at(30), "1m")
        XCTAssertEqual(at(25 * 60), "25m")
        XCTAssertEqual(at(60 * 60), "1h")
        XCTAssertEqual(at(65 * 60), "1h05")
        XCTAssertEqual(at(14 * 3600), "14h")
        XCTAssertEqual(at(50 * 3600), "2d")
    }
}
