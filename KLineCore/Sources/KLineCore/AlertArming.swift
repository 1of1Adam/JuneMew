//
//  AlertArming.swift
//  KLineCore
//

import Foundation

/// 决定「这一刻该不该响」的纯状态机。
///
/// 两个设计要点，都是为了避免真实存在的坏体验：
///
/// **一、幂等键用 K 线的 `closeTime`，不用剩余秒数。**
/// 这一个选择白送了四条正确性：
///   - K 线滚动 → `closeTime` 前进 → 守卫自动重置，不需要手动清状态
///   - tick 被合并或丢失 → 仍然只响一次（只是晚一点）
///   - 睡眠唤醒 → `closeTime` 已推进到新 K 线，不会为错过的旧 K 线补响
///   - 系统时间调整 / 夏令时 → 天然正确
///
/// **二、`armed` 标志抑制启动瞬间的误响。**
/// 如果 app 恰好在剩 8 秒时启动、阈值 15 秒，不加这个标志会立刻响一声。
/// 「我刚打开怎么就叫了」是个很糟的第一印象。必须先观察到一次「阈值之外」
/// 的状态才武装。
public struct AlertArming: Equatable, Sendable {

    private var armed: Bool = false
    private var firedFor: Date?

    public init() {}

    /// 是否应当在此刻播放提醒。
    ///
    /// - Parameters:
    ///   - remainingSeconds: 距收线的剩余秒数
    ///   - barCloses: 当前 K 线的收线时刻，用作幂等键
    ///   - threshold: 提醒阈值（秒）
    /// - Returns: true 表示应当播放；同一根 K 线只会返回一次 true
    public mutating func shouldFire(
        remainingSeconds: Int,
        barCloses: Date,
        threshold: Int
    ) -> Bool {
        // 见过这根 K 线在阈值之外的状态，才允许它触发
        if remainingSeconds > threshold {
            armed = true
            return false
        }

        guard armed, firedFor != barCloses else { return false }

        firedFor = barCloses
        return true
    }

    /// 休市、改周期、改阈值、功能关闭时调用。
    ///
    /// 重置后必须重新观察一次「阈值之外」才会再响 —— 这正是我们要的：
    /// 改完设置不应该立刻听到一声。
    public mutating func disarm() {
        armed = false
        firedFor = nil
    }
}
