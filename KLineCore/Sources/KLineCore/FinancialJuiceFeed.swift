//
//  FinancialJuiceFeed.swift
//  KLineCore
//

import Foundation

/// 一条 FinancialJuice 快讯。
public struct FJNewsItem: Equatable, Identifiable, Sendable, Codable {
    public let id: Int
    public let title: String
    /// 发布时刻。上游给的是**无时区后缀的 UTC**（"2026-07-23T12:31:02.11"）。
    public let published: Date
    public let breaking: Bool
    public let critical: Bool
    public let important: Bool
    public let url: String

    public init(
        id: Int,
        title: String,
        published: Date,
        breaking: Bool,
        critical: Bool,
        important: Bool,
        url: String
    ) {
        self.id = id
        self.title = title
        self.published = published
        self.breaking = breaking
        self.critical = critical
        self.important = important
        self.url = url
    }
}

/// FinancialJuice 快讯流的解码与纯函数工具。网络在 app 层。
public enum FinancialJuiceFeed {

    public enum ParseError: Error, Equatable {
        /// 响应不是 `<string>[…]</string>` 包 JSON 数组的形态。
        case notWrappedJSONArray
        case invalidJSON
        case malformedItem(index: Int, reason: String)
    }

    // MARK: - 解析

    /// 解析 `GetPreviousNews` 的响应：ASMX 的 XML `<string>` 包裹一个
    /// JSON 数组。任何一条非法都整包失败 —— 与经济日历同一哲学。
    public static func parseHistoryResponse(_ body: String) throws -> [FJNewsItem] {
        guard let range = body.range(
            of: #"<string[^>]*>\s*(\[[\s\S]*\])\s*</string>"#,
            options: .regularExpression
        ) else {
            throw ParseError.notWrappedJSONArray
        }
        let wrapped = String(body[range])
        guard let start = wrapped.firstIndex(of: "["),
              let end = wrapped.lastIndex(of: "]") else {
            throw ParseError.notWrappedJSONArray
        }
        return try parseItemsJSON(String(wrapped[start...end]))
    }

    /// 解析裸 JSON 数组形态的条目（WebSocket 推送的 `msg` 字段就是这种：
    /// 与 history 相同的 item schema，只是没有 XML 外壳）。
    public static func parseItemsJSON(_ payload: String) throws -> [FJNewsItem] {
        let rawItems: [RawItem]
        do {
            rawItems = try JSONDecoder().decode([RawItem].self, from: Data(payload.utf8))
        } catch {
            throw ParseError.invalidJSON
        }

        var seen = Set<Int>()
        var items: [FJNewsItem] = []
        for (index, raw) in rawItems.enumerated() {
            guard raw.NewsID > 0 else {
                throw ParseError.malformedItem(index: index, reason: "invalid NewsID")
            }
            guard !raw.Title.isEmpty else {
                throw ParseError.malformedItem(index: index, reason: "empty title")
            }
            guard let published = parseDate(raw.DatePublished) else {
                throw ParseError.malformedItem(index: index, reason: "unparsable date \(raw.DatePublished)")
            }
            // 上游偶发重复推同一条
            guard seen.insert(raw.NewsID).inserted else { continue }

            let level = (raw.Level ?? "").lowercased()
            let critical = level.contains("critical")
            let breaking = raw.Breaking
            items.append(FJNewsItem(
                id: raw.NewsID,
                title: decodeEntities(raw.Title),
                published: published,
                breaking: breaking,
                critical: critical,
                important: breaking || critical || level.contains("important"),
                url: raw.EURL ?? ""
            ))
        }
        return items
    }

    /// "2026-07-23T12:31:02.11" —— 无时区后缀的 UTC，小数位数不定。
    public static func parseDate(_ string: String) -> Date? {
        // 截掉小数秒再解析：位数不定（.11 / .747 / 无），秒级精度足够
        let base = string.split(separator: ".").first.map(String.init) ?? string
        return utcFormatter.date(from: base)
    }

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// 上游 JSON 的原样映射（字段名就是上游的 PascalCase）。
    private struct RawItem: Decodable {
        let NewsID: Int
        let Title: String
        let DatePublished: String
        let Breaking: Bool
        let Level: String?
        let EURL: String?
    }

    /// 标题里的 HTML 实体（&#39; &amp; &#x27; …）。
    public static func decodeEntities(_ value: String) -> String {
        var result = value
        // 数字实体（十进制与十六进制）
        for pattern in [#"&#(\d+);"#, #"&#[xX]([0-9a-fA-F]+);"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let isHex = pattern.contains("[xX]")
            while let match = regex.firstMatch(
                in: result, range: NSRange(result.startIndex..., in: result)
            ) {
                guard let full = Range(match.range, in: result),
                      let codeRange = Range(match.range(at: 1), in: result),
                      let code = UInt32(result[codeRange], radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(code) else { break }
                result.replaceSubrange(full, with: String(Character(scalar)))
            }
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: - 翻译前处理

    /// 发给翻译服务前的敏感表述归一化（与译文规则配套）。
    public static func sanitizeForTranslation(_ title: String) -> String {
        var result = title
        for (pattern, replacement) in [
            (#"taiwan(?:'s)?\s+president"#, "Taiwan regional leader"),
            (#"president\s+of\s+taiwan"#, "leader of Taiwan region"),
        ] {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }
}

/// DeepSeek 翻译响应的解析。
///
/// 约定返回 `{"translations":[{"id":number,"title":string}]}`。
/// 出现**预期之外的 id** 视为幻觉、整包拒收；`allowPartial` 时
/// 允许部分 id 缺失（批量里个别条目失败不拖累全批）。
public enum DeepSeekTranslationParser {

    public static func parse(
        _ content: String,
        expectedIds: [Int],
        allowPartial: Bool
    ) -> [Int: String]? {
        guard let data = content.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = root["translations"] as? [[String: Any]] else {
            return nil
        }

        let expected = Set(expectedIds)
        var result: [Int: String] = [:]

        for item in translations {
            guard let id = coerceId(item["id"]), expected.contains(id) else { return nil }
            if let title = (item["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                result[id] = title
            }
        }

        if result.count == expectedIds.count { return result }
        return allowPartial && !result.isEmpty ? result : nil
    }

    private static func coerceId(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
