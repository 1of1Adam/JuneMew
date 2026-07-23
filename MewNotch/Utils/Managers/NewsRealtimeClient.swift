//
//  NewsRealtimeClient.swift
//  MewNotch
//

import AppKit
import Foundation
import OSLog
import KLineCore

/// FinancialJuice 实时推送通道（Centrifugo over WebSocket）。
///
/// 协议（与 hangzhou 的 news-feed-store 行为逐条对齐）：
/// 1. GET `centrifugo-token.ashx` → `{token: JWT}`
/// 2. 连 `wss://rt.financialjuice.com/connection/websocket`，
///    open 后发 `{"id":1,"connect":{"token",…}}`
/// 3. 一帧可含多行（\n 分隔）；`{}` 是 ping，原样回 `{}`
/// 4. `push.pub.data.ev == "sendUpdates"` 的 `msg` 是条目 JSON 数组字符串
/// 5. `error` / `disconnect` 帧 → 关闭；关闭码 3500–3999 是终止性的，
///    不重试（Centrifugo 保留段，重试只会空转）
///
/// 生命周期：断线指数退避重连（1s 起、60s 封顶）；token 过期由服务器
/// 断开 → 走同一条重连路径重新领 token，不单独维护 refresh 状态机。
/// 系统唤醒时清零退避立即重连。上层的 60 秒轮询仍在 —— 这条通道
/// 挂掉的最坏结果只是退回轮询延迟。
@MainActor
final class NewsRealtimeClient {

    /// 新条目到达（已解析、未合并）。
    var onItems: (([FJNewsItem]) -> Void)?
    /// 连接状态变化（true = 实时通道在线）。
    var onStateChange: ((Bool) -> Void)?

    private(set) var isConnected = false {
        didSet { if isConnected != oldValue { onStateChange?(isConnected) } }
    }

    private let logger = Logger(subsystem: "io.github.1of1adam.JuneMew", category: "news-rt")

    private var socket: URLSessionWebSocketTask?
    /// 换代计数：旧 socket 的迟到回调对不上号就直接丢弃。
    private var generation = 0
    private var reconnectAttempts = 0
    private var reconnectTimer: Timer?
    private var active = false
    private var wakeObserver: NSObjectProtocol?

    private static let tokenURL = "https://feed.financialjuice.com/widgets/centrifugo-token.ashx"
    private static let wsURL = "wss://rt.financialjuice.com/connection/websocket"
    private static let reconnectBaseDelay: TimeInterval = 1
    private static let reconnectMaxDelay: TimeInterval = 60

    // MARK: - 生命周期

    func start() {
        guard !active else { return }
        active = true
        reconnectAttempts = 0

        // 睡醒后老连接多半已死但 close 事件会迟到 —— 主动换代重连，
        // 清零退避让恢复立即发生。
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.logger.info("实时通道：系统唤醒，立即重连")
                self.reconnectAttempts = 0
                self.connect()
            }
        }

        connect()
    }

    func stop() {
        active = false
        generation += 1
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - 连接

    private func connect() {
        guard active else { return }
        generation += 1
        let gen = generation

        reconnectTimer?.invalidate()
        reconnectTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false

        Task {
            do {
                let token = try await Self.fetchToken()
                guard self.active, self.generation == gen else { return }
                self.openSocket(token: token, gen: gen)
            } catch {
                guard self.active, self.generation == gen else { return }
                self.logger.error("实时通道：token 获取失败：\(String(describing: error), privacy: .public)")
                self.scheduleReconnect()
            }
        }
    }

    private static func fetchToken() async throws -> String {
        var request = URLRequest(url: URL(string: tokenURL)!, timeoutInterval: 10)
        request.setValue("https://feed.financialjuice.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "token endpoint returned \(http.statusCode)"
            ])
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? String, !token.isEmpty else {
            throw URLError(.cannotParseResponse, userInfo: [
                NSLocalizedDescriptionKey: "token response did not contain a token"
            ])
        }
        return token
    }

    private func openSocket(token: String, gen: Int) {
        var request = URLRequest(url: URL(string: Self.wsURL)!, timeoutInterval: 10)
        request.setValue("https://feed.financialjuice.com", forHTTPHeaderField: "Origin")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()

        task.send(.string(Self.connectFrame(token: token))) { [weak self] error in
            Task { @MainActor in
                guard let self, self.active, self.generation == gen else { return }
                if let error {
                    self.logger.error("实时通道：connect 帧发送失败：\(String(describing: error), privacy: .public)")
                    self.scheduleReconnect()
                    return
                }
                self.receiveLoop(task: task, gen: gen)
            }
        }
    }

    private static func connectFrame(token: String) -> String {
        let frame: [String: Any] = [
            "id": 1,
            "connect": ["token": token, "name": "junemew-news", "version": "1.0.0"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    // MARK: - 收发

    private func receiveLoop(task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.active, self.generation == gen else { return }
                switch result {
                case let .success(message):
                    if case let .string(text) = message {
                        self.handleFrames(text, task: task, gen: gen)
                    }
                    // 二进制帧按协议不该出现；出现也不致命，忽略继续收
                    guard self.generation == gen else { return }
                    self.receiveLoop(task: task, gen: gen)

                case let .failure(error):
                    let code = task.closeCode.rawValue
                    // Centrifugo 3500–3999 = 终止性断开，重试只会空转
                    let terminal = (3500...3999).contains(code)
                    self.logger.warning("实时通道断开（code \(code)）：\(String(describing: error), privacy: .public)")
                    self.isConnected = false
                    if terminal {
                        self.logger.error("实时通道：终止性关闭码 \(code)，停止重试（轮询兜底仍在）")
                    } else {
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    private func handleFrames(_ text: String, task: URLSessionWebSocketTask, gen: Int) {
        for line in text.split(separator: "\n") {
            let frame = line.trimmingCharacters(in: .whitespaces)
            if frame.isEmpty { continue }

            // ping → pong，原样空对象
            if frame == "{}" {
                task.send(.string("{}")) { _ in }
                continue
            }

            guard let data = frame.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("实时通道：非法 JSON 帧，重连")
                scheduleReconnect()
                return
            }

            if let errorInfo = message["error"] as? [String: Any] {
                logger.error("实时通道：协议错误：\(String(describing: errorInfo), privacy: .public)")
                scheduleReconnect()
                return
            }
            if message["disconnect"] != nil {
                logger.warning("实时通道：服务器要求断开，重连")
                scheduleReconnect()
                return
            }
            if message["connect"] != nil {
                reconnectAttempts = 0
                isConnected = true
                logger.info("实时通道：已连接")
                continue
            }
            if let push = message["push"] as? [String: Any],
               let pub = push["pub"] as? [String: Any],
               let payload = pub["data"] as? [String: Any],
               payload["ev"] as? String == "sendUpdates",
               let msg = payload["msg"] as? String {
                do {
                    let items = try FinancialJuiceFeed.parseItemsJSON(msg)
                    if !items.isEmpty {
                        logger.info("实时推送：\(items.count) 条")
                        onItems?(items)
                    }
                } catch {
                    // 单条推送坏了不值得断连 —— 记下来，等下一条
                    logger.error("实时推送解析失败：\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: - 重连

    private func scheduleReconnect() {
        guard active, reconnectTimer == nil else { return }
        isConnected = false
        let attempt = reconnectAttempts
        let delay = min(Self.reconnectMaxDelay, Self.reconnectBaseDelay * pow(2, Double(attempt)))
        reconnectAttempts = min(attempt + 1, 8)
        logger.info("实时通道：\(String(format: "%.0f", delay)) 秒后重连（第 \(attempt + 1) 次）")

        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.reconnectTimer = nil
                self?.connect()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
    }
}
