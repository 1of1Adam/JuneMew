//
//  NotchCalendarSection.swift
//  MewNotch
//

import SwiftUI
import KLineCore

/// 仪表盘里的经济日历区。
///
/// 回答的问题只有一个：「接下来什么数据会动市场，什么时候」。
/// 显示从今天（ET 日界）起的前两个有事件的日子 —— 盘中就是今天+明天，
/// 周末自动落到下周一。
///
/// 视觉语法（与面板设计语言同源）：
/// - 琥珀 = 「现在」：TODAY 组头、下一个待发布事件的竖条与倒计时、
///   actual 大幅偏离预期 —— 都是同一个语义。
/// - 方向用箭头（▴▾）、强度用亮度与琥珀，不引入红绿轴。
/// - 已发布的行沉下去（半透明），待发布的下一条浮上来（微底 + 竖条）。
/// - **区内没有常驻动画。** 倒计时 30 秒一跳、数字硬切。
struct NotchCalendarSection: View {

    @ObservedObject private var store = EconomicCalendarStore.shared
    @ObservedObject private var defaults = CountdownDefaults.shared

    // 列宽契约：数据行与列头共用，保证像素级对齐。
    static let timeWidth: CGFloat = 36
    static let dotWidth: CGFloat = 5
    static let valueWidth: CGFloat = 46
    static let actualWidth: CGFloat = 50
    static let columnSpacing: CGFloat = 6
    /// 行内容的水平内边距 —— NEXT 高亮底比内容宽出这一圈，呼吸感来源。
    static let rowInset: CGFloat = 10
    /// 超过这个行数就交给 ScrollView，别让岛长过半个屏。
    private static let inlineRowLimit = 8

    var body: some View {
        // 30s 心跳驱动倒计时、NEXT 判定和已过变暗。粒度足够：
        // 这里是「还有多久」的量级感，秒级精度属于主倒计时。
        TimelineView(.periodic(from: .now, by: 30)) { context in
            sectionContent(now: context.date)
        }
        .onAppear { store.panelWillShow() }
    }

    @ViewBuilder
    private func sectionContent(now: Date) -> some View {
        VStack(spacing: 3) {
            header(now: now)

            if let feed = store.feed {
                let groups = displayGroups(feed: feed, now: now)
                if groups.isEmpty {
                    emptyRow
                } else {
                    columnCaptions
                    eventList(groups: groups, now: now)
                }
            } else if store.lastError != nil {
                unavailableRow
            } else {
                loadingRow
            }
        }
    }

    // MARK: - 头部

    private func header(now: Date) -> some View {
        HStack(spacing: 6) {
            Text("经济日历")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(-0.15)
                .foregroundStyle(Color.white.opacity(0.38))

            // 刷新失败但还有旧数据：琥珀点如实报告，不打断
            if store.lastError != nil, let feed = store.feed {
                Circle()
                    .fill(MewNotch.CountdownColors.concernAmber)
                    .frame(width: 4, height: 4)
                    .help("刷新失败 — 当前显示 \(Self.staleFormatter.localizedString(for: feed.fetchedAt, relativeTo: now))抓取的数据")
            }

            Spacer(minLength: 8)

            importanceFilterChip
        }
        .padding(.horizontal, Self.rowInset)
    }

    /// 三档循环：All → Med+ → High。常驻一层微底 —— 可点的东西要长得可点。
    private var importanceFilterChip: some View {
        FilterChip(label: filterLabel) {
            let next: Int = switch defaults.calendarMinImportance {
            case ..<0: 0
            case 0: 1
            default: -1
            }
            defaults.calendarMinImportance = next
        }
        .help("重要度筛选 — 点击切换档位")
    }

    private var filterLabel: String {
        switch defaults.calendarMinImportance {
        case ..<0: return "全部"
        case 0: return "中高"
        default: return "高"
        }
    }

    /// 列头与数据行共用同一列结构 —— 对齐不是碰巧，是同一份契约。
    private var columnCaptions: some View {
        HStack(spacing: Self.columnSpacing) {
            Color.clear.frame(width: Self.timeWidth, height: 1)
            Color.clear.frame(width: Self.dotWidth, height: 1)
            Spacer(minLength: 0)
            ForEach(["前值", "预期", "实际"], id: \.self) { caption in
                Text(caption)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .tracking(-0.1)
                    .foregroundStyle(Color.white.opacity(0.32))
                    .frame(
                        width: caption == "实际" ? Self.actualWidth : Self.valueWidth,
                        alignment: .trailing
                    )
            }
        }
        .padding(.horizontal, Self.rowInset)
    }

    // MARK: - 列表

    @ViewBuilder
    private func eventList(groups: [DisplayGroup], now: Date) -> some View {
        let nextID = nextEventID(groups: groups, now: now)
        let totalRows = groups.reduce(0) { $0 + $1.events.count }

        let list = VStack(spacing: 1) {
            ForEach(groups) { group in
                dayHeader(group)
                ForEach(group.events) { event in
                    CalendarEventRow(
                        event: event,
                        displayTitle: store.titleTranslations[event.title] ?? event.title,
                        now: now,
                        isNext: event.id == nextID,
                        isNextImminent: event.id == nextID && group.isToday
                    )
                }
            }
        }
        // 换档（行集合突变）与数据刷新走同一段 spring —— 行的增删
        // 与位移平滑落位，而不是两帧之间换了一个世界。
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: defaults.calendarMinImportance)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: store.feed?.fetchedAt)

        if totalRows > Self.inlineRowLimit {
            // 滚动条必须 .never —— 系统设置「始终显示滚动条」时 legacy
            // scroller 会占掉 ~15pt 内容宽度，行里的值列被挤得和外面的
            // 列头错位（.hidden 在该设置下被系统忽略，实测如此）。
            // 「还有更多」的暗示交给底部渐隐：最后一行淡出屏幕，
            // 比一根灰条更像灵动岛。
            ScrollView(.vertical) {
                list
            }
            .scrollIndicators(.never)
            .frame(height: 192)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.92),
                        .init(color: .black.opacity(0.05), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else {
            list
        }
    }

    /// 日组头。TODAY 的「今天」用琥珀 —— 它是「现在」的锚点，
    /// 与主倒计时、当前周期卡是同一个语义家族。
    private func dayHeader(_ group: DisplayGroup) -> some View {
        HStack(spacing: 5) {
            Text(group.title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(-0.15)
                .foregroundStyle(
                    group.isToday
                        ? MewNotch.CountdownColors.icon.opacity(0.85)
                        : Color.white.opacity(0.5)
                )

            Text(group.dateLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .tracking(-0.15)
                .foregroundStyle(Color.white.opacity(0.35))

            Spacer()
        }
        .padding(.horizontal, Self.rowInset)
        .padding(.top, 3)
        .padding(.bottom, 1)
    }

    // MARK: - 特殊状态行

    private var emptyRow: some View {
        Text("近几日无美国数据发布")
            .font(.system(size: 10.5, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.4))
            .padding(.vertical, 4)
    }

    private var loadingRow: some View {
        Text("日历加载中…")
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
                Text("日历加载失败 — 点击重试")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 数据整形

    private struct DisplayGroup: Identifiable {
        let id: Date
        /// "今天" / "明天" / "周一"
        let title: String
        /// "7月23日"
        let dateLabel: String
        let isToday: Bool
        let events: [EconomicEvent]
    }

    /// 筛出「今天（ET）0 点以后 + 达到重要度档位」的事件，按 ET 日分组，
    /// 取前两个非空日组。今天已发布的保留 —— 「CPI 刚才出了多少」和
    /// 「下一个是什么」同样是盘中要回答的问题。
    private func displayGroups(feed: EconomicCalendarStore.Feed, now: Date) -> [DisplayGroup] {
        let todayStart = Self.etCalendar.startOfDay(for: now)
        let minImportance = defaults.calendarMinImportance

        let visible = feed.events.filter {
            $0.importance.rawValue >= minImportance && $0.date >= todayStart
        }

        return EconomicCalendarFeed.groupByETDay(visible).prefix(2).map { group in
            let isToday = group.dayStart == todayStart
            let isTomorrow = Self.etCalendar.date(
                byAdding: .day, value: 1, to: todayStart
            ) == group.dayStart

            return DisplayGroup(
                id: group.dayStart,
                title: isToday
                    ? "今天"
                    : isTomorrow
                        ? "明天"
                        : Self.weekdayFormatter.string(from: group.dayStart),
                dateLabel: Self.monthDayFormatter.string(from: group.dayStart),
                isToday: isToday,
                events: group.events
            )
        }
    }

    private func nextEventID(groups: [DisplayGroup], now: Date) -> String? {
        groups
            .flatMap(\.events)
            .filter { $0.date > now }
            .min { $0.date < $1.date }?
            .id
    }

    // MARK: - ET 基建

    static let etTimeZone: TimeZone = {
        guard let tz = TimeZone(identifier: "America/New_York") else {
            preconditionFailure("America/New_York must exist")
        }
        return tz
    }()

    private static let etCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = etTimeZone
        return calendar
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = etTimeZone
        f.dateFormat = "EEE"          // "周一"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = etTimeZone
        f.dateFormat = "M月d日"
        return f
    }()

    private static let staleFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}

// MARK: - 事件行

private struct CalendarEventRow: View {

    let event: EconomicEvent
    /// 中文译名（缓存命中时）或英文原名。tooltip 恒给英文原文。
    let displayTitle: String
    let now: Date
    /// 全列表中下一个待发布的事件 —— 结构标记（竖条 + 微底），指路用。
    let isNext: Bool
    /// 下一个且就在今天 —— 才升级成琥珀套装。琥珀的语义是「临近/注意」，
    /// 周末面板里「下周一的数据」得到结构标记即可，不该拉响警示色。
    let isNextImminent: Bool

    @State private var hovering = false

    private var isPast: Bool { event.date <= now }
    private var surprise: EconomicSurprise? {
        EconomicSurprise.compute(actual: event.actual, forecast: event.forecast)
    }

    /// NEXT 标记色：今天琥珀，远期中性白。
    private var markerColor: Color {
        isNextImminent
            ? MewNotch.CountdownColors.icon
            : Color.white.opacity(0.6)
    }

    var body: some View {
        HStack(spacing: NotchCalendarSection.columnSpacing) {
            Text(Self.etTimeFormatter.string(from: event.date))
                .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(
                    isNext ? markerColor : Color.white.opacity(0.55)
                )
                .frame(width: NotchCalendarSection.timeWidth, alignment: .leading)

            Circle()
                .fill(importanceColor)
                .frame(
                    width: NotchCalendarSection.dotWidth,
                    height: NotchCalendarSection.dotWidth
                )

            Text(displayTitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .tracking(-0.2)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: displayTitle)
                .foregroundStyle(Color.white.opacity(isNext ? 0.95 : 0.75))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            valueCell(event.previous)
            valueCell(event.forecast)
            actualCell
        }
        .padding(.vertical, 3.5)
        .padding(.horizontal, NotchCalendarSection.rowInset)
        .background(rowBackground)
        .opacity(isPast && !isNext ? 0.5 : 1)
        // NEXT 迁移（事件发布后高亮滑向下一行）与已过变暗是状态转移，
        // 给一段 spring；hover 是即时反馈，130ms 就够。
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isNext)
        .animation(.easeOut(duration: 0.13), value: hovering)
        // actual 落地时（"即将" → "187K▾"）值以 pop 进场 —— 数据发布是
        // 这一行的高光时刻，值得一次性的强调；每 30 秒的倒计时跳动
        // 不在此列（value 绑 actual，不绑 now）。
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: event.actual)
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    /// NEXT 行：微底 + 左侧琥珀竖条 —— 「进行中」的标记，
    /// 与周期矩阵里当前卡的琥珀描边同一语义。悬停任何行给一层
    /// 更浅的底，暗示 tooltip 的存在。
    private var rowBackground: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(isNext ? 0.065 : hovering ? 0.035 : 0))

            if isNext {
                Capsule()
                    .fill(markerColor.opacity(0.9))
                    .frame(width: 2.5)
                    .padding(.vertical, 3)
            }
        }
    }

    // MARK: 列

    private func valueCell(_ value: Double?) -> some View {
        Text(EconomicCalendarFeed.formatValue(value, unit: event.unit, scale: event.scale))
            .font(.system(size: 10.5, design: .rounded).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.58))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: NotchCalendarSection.valueWidth, alignment: .trailing)
    }

    /// Act 列一格四态：已有值（带 surprise 标记）→ 值；下一个待发布 → 倒计时；
    /// 已到时但数据未挂出 → "…"；讲话类无数值事件与远期 → "–"。
    @ViewBuilder
    private var actualCell: some View {
        Group {
            if event.actual != nil {
                Text(actualText)
                    .foregroundStyle(actualColor)
                    .transition(.scale(scale: 0.55).combined(with: .opacity))
            } else if isNext {
                Text(EconomicCalendarFeed.formatCountdown(to: event.date, now: now))
                    .foregroundStyle(markerColor)
            } else if isPast && event.hasNumericContent {
                Text("…")
                    .foregroundStyle(Color.white.opacity(0.45))
            } else {
                Text("–")
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(width: NotchCalendarSection.actualWidth, alignment: .trailing)
    }

    /// 方向用箭头、意外强度用颜色 —— 不碰红绿轴：
    /// 大幅偏离预期 = 琥珀（全项目的「注意」色），符合预期 = 常态白。
    private var actualText: String {
        let value = EconomicCalendarFeed.formatValue(
            event.actual, unit: event.unit, scale: event.scale
        )
        switch surprise?.sign {
        case .up: return value + "▴"
        case .down: return value + "▾"
        default: return value
        }
    }

    private var actualColor: Color {
        guard let surprise else { return MewNotch.CountdownColors.normal }
        return surprise.isLarge
            ? MewNotch.CountdownColors.icon
            : MewNotch.CountdownColors.normal
    }

    private var importanceColor: Color {
        switch event.importance {
        case .high: return MewNotch.CountdownColors.urgent
        case .medium: return MewNotch.CountdownColors.concernAmber
        case .low: return MewNotch.CountdownColors.concernGray
        }
    }

    // MARK: tooltip

    private var tooltip: String {
        var lines: [String] = []
        var headline = event.title
        if !event.period.isEmpty { headline += " — \(event.period)" }
        lines.append(headline)
        lines.append(
            "\(Self.etTimeFormatter.string(from: event.date)) ET · 本地 \(Self.localTimeFormatter.string(from: event.date))"
        )
        if let surprise {
            let direction = switch surprise.sign {
            case .up: "高于"
            case .down: "低于"
            case .flat: "符合"
            }
            lines.append("实际值\(direction)预期")
        }
        if let comment = event.comment, !comment.isEmpty {
            lines.append("")
            lines.append(comment)
        }
        return lines.joined(separator: "\n")
    }

    private static let etTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = NotchCalendarSection.etTimeZone
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let localTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()
}

// MARK: - 筛选按钮

/// 重要度档位按钮。与 HoverChip 的差别只有一处：常驻微底 ——
/// 这是面板里唯一「不 hover 就看不出可点」的控件，得长得像个开关。
private struct FilterChip: View {

    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(hovering ? 0.75 : 0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(hovering ? 0.1 : 0.055))
                )
                .animation(.easeOut(duration: 0.13), value: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
