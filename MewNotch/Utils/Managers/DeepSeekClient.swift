//
//  DeepSeekClient.swift
//  MewNotch
//

import Foundation
import KLineCore

/// DeepSeek chat/completions 的最小翻译客户端，快讯与经济日历共用。
///
/// 参数按「确定性重写任务」调校：json_object、temperature 0、thinking
/// 关闭（推理输出只会跟 JSON 正文抢 completion 预算）。响应经
/// `DeepSeekTranslationParser` 校验 —— 幻觉 id 整包拒收。
enum DeepSeekClient {

    static func translate(
        items: [(id: Int, text: String)],
        systemPrompt: String,
        apiKey: String
    ) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }

        let payload = items.map { ["id": $0.id, "title": $0.text] as [String: Any] }
        let body: [String: Any] = [
            "model": "deepseek-v4-flash",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": jsonString(["headlines": payload])],
            ],
            "thinking": ["type": "disabled"],
            "response_format": ["type": "json_object"],
            "temperature": 0,
            "stream": false,
            "max_tokens": max(1024, items.count * 128),
        ]

        var request = URLRequest(
            url: URL(string: "https://api.deepseek.com/chat/completions")!,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let snippet = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "DeepSeek HTTP \(http.statusCode): \(snippet)"
            ])
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw URLError(.cannotParseResponse, userInfo: [
                NSLocalizedDescriptionKey: "DeepSeek returned no assistant content"
            ])
        }

        guard let byId = DeepSeekTranslationParser.parse(
            content,
            expectedIds: items.map(\.id),
            allowPartial: items.count > 1
        ) else {
            throw URLError(.cannotParseResponse, userInfo: [
                NSLocalizedDescriptionKey: "DeepSeek returned invalid translation payload"
            ])
        }
        return byId
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
