//
//  NotchNewsSection.swift
//  MewNotch
//

import SwiftUI
import KLineCore

/// 仪表盘里的快讯区。
///
/// 只展示最近几条 —— 刘海面板是「瞟一眼」的地方，不是新闻终端。
/// 中文标题（已翻）优先，悬停 tooltip 给英文原文；critical 红点、
/// breaking 琥珀点，与日历重要度点同一套语言。点击行打开原文链接。
///
/// **没有常驻动画，但事件有入场。** 新条目从顶部滑入一次即静止 ——
/// 「有新东西」值得 300ms 的强调；相对时间的 30 秒跳动保持硬切。
struct NotchNewsSection: View {

    @ObservedObject private var store = NewsStore.shared
    @ObservedObject private var defaults = CountdownDefaults.shared

    /// 不超过这个行数直接平铺；超过则进滚动区。
    private static let inlineLimit = 5
    /// 滚动区高度 ≈ 5 行多一点：第 6 行露出一截，配合渐隐暗示「往下还有」。
    private static let scrollHeight: CGFloat = 122

    var body: some View {
        VStack(spacing: 3) {
            header

            if store.items.isEmpty {
                if store.lastError != nil {
                    unavailableRow
                } else {
                    loadingRow
                }
            } else {
                // TimelineView 驱动相对时间（"3m"）每 30 秒刷新
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    newsList(now: context.date)
                }
            }
        }
    }

    @ViewBuilder
    private func newsList(now: Date) -> some View {
        let list = VStack(spacing: 1) {
            ForEach(store.items) { item in
                NewsRow(item: item, now: now)
                    // 新快讯从顶部滑入，旧行被平滑推下去 —— 实时推送
                    // 值得一个「来了」的入场，但只此一次，落位即静止。
                    .transition(.asymmetric(
                        insertion: .offset(y: -10).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: store.items.map(\.id))

        if store.items.count <= Self.inlineLimit {
            list
        } else {
            // 滚动条 .never：与日历同因 —— legacy 常驻滚动条会占宽挤歪布局
            ScrollView(.vertical) {
                list
            }
            .scrollIndicators(.never)
            .frame(height: Self.scrollHeight)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.9),
                        .init(color: .black.opacity(0.05), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("快讯")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(-0.15)
                .foregroundStyle(Color.white.opacity(0.38))

            if store.lastError != nil, !store.items.isEmpty {
                Circle()
                    .fill(MewNotch.CountdownColors.concernAmber)
                    .frame(width: 4, height: 4)
                    .help("刷新失败 — 显示最后一次抓到的快讯")
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, NotchCalendarSection.rowInset)
    }

    private var loadingRow: some View {
        Text("快讯加载中…")
            .font(.system(size: 10.5, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.4))
            .padding(.vertical, 4)
    }

    private var unavailableRow: some View {
        HoverChip {
            store.refresh()
        } content: {
            HStack(spacing: 5) {
                MewNotch.Assets.icWarning
                    .font(.system(size: 10))
                    .foregroundStyle(MewNotch.CountdownColors.concernAmber)
                Text("快讯加载失败 — 点击重试")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 快讯行

private struct NewsRow: View {

    let item: NewsStore.DisplayItem
    let now: Date

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: NotchCalendarSection.columnSpacing) {
                Text(relativeAge)
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: NotchCalendarSection.timeWidth, alignment: .leading)

                Circle()
                    .fill(dotColor)
                    .frame(
                        width: NotchCalendarSection.dotWidth,
                        height: NotchCalendarSection.dotWidth
                    )

                Text(item.title)
                    .font(.system(size: 11, weight: item.important ? .semibold : .medium, design: .rounded))
                    .tracking(-0.2)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: item.isTranslated)
                    .foregroundStyle(Color.white.opacity(item.important ? 0.92 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3.5)
            .padding(.horizontal, NotchCalendarSection.rowInset)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(hovering ? 0.035 : 0))
            )
            .animation(.easeOut(duration: 0.13), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private func open() {
        guard let url = URL(string: item.url), !item.url.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    /// "刚刚" / "3m" / "1h" / "2d" —— 快讯要的是新鲜度，不是钟点。
    /// 单位与倒计时、周期卡同一套 m/h/d 语言。
    private var relativeAge: String {
        let seconds = max(0, now.timeIntervalSince(item.published))
        if seconds < 60 { return "刚刚" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private var dotColor: Color {
        if item.critical { return MewNotch.CountdownColors.urgent }
        if item.breaking || item.important { return MewNotch.CountdownColors.concernAmber }
        return MewNotch.CountdownColors.concernGray
    }

    private var tooltip: String {
        var lines = [item.originalTitle]
        if item.isTranslated { lines.append(item.title) }
        lines.append(Self.timeFormatter.string(from: item.published) + " ET")
        if !item.url.isEmpty { lines.append("点击打开原文") }
        return lines.joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = NotchCalendarSection.etTimeZone
        f.dateFormat = "HH:mm"
        return f
    }()
}
