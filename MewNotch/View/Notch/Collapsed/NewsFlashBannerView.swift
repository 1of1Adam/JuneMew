//
//  NewsFlashBannerView.swift
//  MewNotch
//

import SwiftUI

/// 红色快讯的灵动岛弹幅：脉冲红点 + 「红色快讯」标签 + 相对时间 + 两行标题。
///
/// 形体变化由 NotchView 负责（顶排撑宽、黑色形体向下生长），这里只是
/// 被形体边缘揭示的内容层 —— 与 NotchDashboardView 的分工完全一致。
///
/// # 视觉语言
///
/// - 身份色是 `CountdownColors.urgent` 暖橙红 —— 它在这个 app 里的既有
///   语义就是「需要立刻抬眼」，红色快讯与倒计时最后 15 秒共享同一信号；
/// - 亮度阶梯沿用面板体系：标题 0.92 主、时间 0.45 弱；
/// - 脉冲涟漪是全 app 第三处常驻动画（前两处：响铃铃铛、及无）——
///   常态的绝对静止让此刻的运动在余光里格外醒目，这正是把运动
///   留给报警时刻的全部意义。
struct NewsFlashBannerView: View {

    /// 弹幅态的岛宽。定宽 —— 宽度随标题抖动的岛读起来像故障；
    /// 384pt 放得下两行中文标题，又明确窄于仪表盘（552）的量级：
    /// 一眼就能分辨「这是路过的通知，不是我打开的面板」。
    static let islandWidth: CGFloat = 384

    let flash: NewsFlashCenter.Flash

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            PulsingDot(critical: flash.critical, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // tracking 克制在 0.5：大字距是拉丁 overline 的手法，
                    // 中文四字标签拉开只会读成「红 色 快 讯」。
                    Text("红色快讯")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(MewNotch.CountdownColors.urgent)
                        .shadow(
                            color: flash.critical
                                ? MewNotch.CountdownColors.urgentGlow
                                : .clear,
                            radius: 3
                        )

                    // 相对时间每 30 秒硬切一次 —— 与快讯区同一套新鲜度语言。
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(relativeAge(now: context.date))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.45))
                    }

                    Spacer(minLength: 0)
                }

                // 12pt：比面板快讯行（11）大半档 —— 这是打断级通知；
                // 又低于菜单栏时钟量级 —— 它是路过的横幅，不是常驻 UI。
                Text(flash.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(-0.1)
                    .lineSpacing(1)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    // 译文到位原位淡换，不闪不跳 —— 与快讯区同参。
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: flash.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 15)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(width: Self.islandWidth)
        .background(
            // 悬停浮一层底色：回答「这一整条都能点」。圆角略小于
            // 形体底角，光斑不会探出岛缘。
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(hovering ? 0.05 : 0))
                .padding(.horizontal, 5)
                .padding(.bottom, 5)
        )
        .animation(.easeOut(duration: 0.13), value: hovering)
        .contentShape(Rectangle())
        // 子视图手势优先于父级 —— 点弹幅开原文，点顶排（刘海/倒计时）
        // 仍是展开仪表盘，两个语义在各自的区域里互不越界。
        .onTapGesture(perform: open)
        .onHover { inside in
            hovering = inside
            // 悬停 = 在读，停留计时挂起；这与 NotchView 自身的 onHover
            // （悬停放大提示）并行触发、互不干扰。
            NewsFlashCenter.shared.setHovering(inside)
        }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("红色快讯：\(flash.title)")
        .accessibilityHint(flash.url.isEmpty ? "点击收起" : "点击打开原文")
    }

    private func open() {
        if let url = URL(string: flash.url), !flash.url.isEmpty {
            NSWorkspace.shared.open(url)
        }
        NewsFlashCenter.shared.dismissCurrent()
    }

    private func relativeAge(now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(flash.published))
        if seconds < 60 { return "刚刚" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private var tooltip: String {
        var lines = [flash.title]
        if flash.isTranslated { lines.append("(DeepSeek 译写)") }
        lines.append(flash.url.isEmpty ? "点击收起" : "点击打开原文")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 脉冲红点

/// 实心核 + 双涟漪。涟漪 1.8 秒一轮、双环相位差半轮 —— 呼吸的节律，
/// 不是警报器的爆闪；critical 级别只加强核的辉光，不加快节奏。
private struct PulsingDot: View {

    let critical: Bool
    let reduceMotion: Bool

    @State private var rippling = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                ripple(delay: 0)
                ripple(delay: 0.9)
            }

            Circle()
                .fill(MewNotch.CountdownColors.urgent)
                .frame(width: 7, height: 7)
                .shadow(
                    color: MewNotch.CountdownColors.urgentGlow,
                    radius: critical ? 6 : 4
                )
        }
        // 26×26 的舞台刚好容下涟漪最大扩散（7 × 3.1 ≈ 22pt），
        // 不会探出形体被 clipShape 切平。
        .frame(width: 26, height: 26)
        .onAppear { rippling = true }
        .onDisappear { rippling = false }
    }

    private func ripple(delay: Double) -> some View {
        Circle()
            .stroke(MewNotch.CountdownColors.urgent, lineWidth: 1.5)
            .frame(width: 7, height: 7)
            .scaleEffect(rippling ? 3.1 : 0.5)
            .opacity(rippling ? 0 : 0.85)
            .animation(
                .easeOut(duration: 1.8)
                    .repeatForever(autoreverses: false)
                    .delay(delay),
                value: rippling
            )
    }
}
