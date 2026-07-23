//
//  CountdownSettingsView.swift
//  MewNotch
//

import SwiftUI
import KLineCore

struct CountdownSettingsView: View {

    @ObservedObject private var defaults = CountdownDefaults.shared
    @ObservedObject private var engine = CountdownEngine.shared

    private let availableSounds = CandleAlertPlayer.availableSoundNames()

    var body: some View {
        Form {
            Section {
                SettingsRow(
                    title: "启用",
                    subtitle: "在刘海上显示 K 线收线倒计时",
                    icon: MewNotch.Assets.icCandle,
                    color: MewNotch.Colors.countdown
                ) {
                    Toggle("", isOn: $defaults.isEnabled)
                }

                SettingsRow(
                    title: "周期",
                    subtitle: "CME Globex 期货（ES / NQ / MES / MNQ）",
                    icon: MewNotch.Assets.icTimer,
                    color: MewNotch.Colors.timer
                ) {
                    Picker("", selection: Binding(
                        get: { defaults.period },
                        set: { newPeriod in
                            // 两道保险，缺一不可：
                            // ① 值没变就什么都不做。SwiftUI 的 Picker 在视图重建或
                            //    重复选中同一项时也会调 setter。
                            // ② 只夹取、不重置。阈值是用户手调的绝对秒数，
                            //    换周期不该把它们冲掉。
                            // 这两条正是「响铃阈值改成 30 秒却还是 15 秒响」的修复。
                            guard newPeriod != defaults.period else { return }
                            defaults.period = newPeriod
                            defaults.clampThresholdsToPeriod()
                        }
                    )) {
                        ForEach(BarPeriod.userSelectable) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }

                SettingsRow(
                    title: "位置",
                    subtitle: "右侧紧邻菜单栏状态图标",
                    icon: MewNotch.Assets.icPosition,
                    color: MewNotch.Colors.notch
                ) {
                    Picker("", selection: $defaults.position) {
                        ForEach(CountdownPosition.allCases) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingsRow(
                    title: "显示周期标签",
                    subtitle: defaults.showPeriodLabel
                        ? "显示为 \"\(defaults.period.displayName) 04:32\""
                        : "显示为 \"04:32\"",
                    icon: MewNotch.Assets.icLabel,
                    color: MewNotch.Colors.general
                ) {
                    Toggle("", isOn: $defaults.showPeriodLabel)
                }

                SettingsRow(
                    title: "显示图标",
                    subtitle: "位于数字对侧，让刘海两边平衡",
                    icon: Image(systemName: CountdownIcon.systemName),
                    color: MewNotch.Colors.countdown
                ) {
                    // 图标槽的增删不经过 engine.presentation，所以要在这里
                    // 自己开动画事务，否则图标会瞬间消失、刘海宽度硬跳。
                    Toggle("", isOn: Binding(
                        get: { defaults.showIcon },
                        set: { newValue in
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                                defaults.showIcon = newValue
                            }
                        }
                    ))
                }

                SettingsRow(
                    title: "刘海仪表盘",
                    subtitle: "悬停放大提示，点击展开全周期矩阵、经济日历与快讯",
                    icon: MewNotch.Assets.icHover,
                    color: MewNotch.Colors.hover
                ) {
                    Toggle("", isOn: $defaults.dashboardEnabled)
                }

            } header: {
                Text("倒计时")
            }

            Section {
                SettingsRow(
                    title: "警告",
                    subtitle: "剩 \(defaults.warningThreshold) 秒时变琥珀色",
                    icon: MewNotch.Assets.icPaintbrush,
                    color: MewNotch.Colors.height
                ) {
                    Stepper(
                        "",
                        value: $defaults.warningThreshold,
                        in: 5...max(5, defaults.period.seconds - 1),
                        step: 5
                    )
                    .labelsHidden()
                }

                SettingsRow(
                    title: "紧急",
                    subtitle: "剩 \(defaults.urgentThreshold) 秒时变橙红并发辉光",
                    icon: MewNotch.Assets.icWarning,
                    color: MewNotch.Colors.alert
                ) {
                    Stepper(
                        "",
                        value: $defaults.urgentThreshold,
                        in: 1...max(1, defaults.warningThreshold - 1),
                        step: 1
                    )
                    .labelsHidden()
                }
            } header: {
                Text("阈值")
            } footer: {
                Text("绝对秒数而非周期比例 —— 反应窗口不随 K 线变短而缩水。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                SettingsRow(
                    title: "经济日历",
                    subtitle: "仪表盘里显示美国数据（CPI、非农、FOMC…），预期与实际值实时更新",
                    icon: MewNotch.Assets.icCalendar,
                    color: MewNotch.Colors.session
                ) {
                    Toggle("", isOn: $defaults.calendarEnabled)
                }

                if defaults.calendarEnabled {
                    SettingsRow(
                        title: "重要度",
                        subtitle: importanceSubtitle,
                        icon: MewNotch.Assets.icWarning,
                        color: MewNotch.Colors.alert
                    ) {
                        Picker("", selection: $defaults.calendarMinImportance) {
                            Text("全部").tag(-1)
                            Text("中高").tag(0)
                            Text("高").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            } header: {
                Text("经济日历")
            } footer: {
                Text("时刻表与数值来自 TradingView 公开经济日历，每 20 分钟刷新一次，"
                     + "数据发布后即时补拉。关闭后完全停止相关网络请求。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                SettingsRow(
                    title: "快讯",
                    subtitle: "仪表盘里显示 FinancialJuice 快讯，每分钟轮询",
                    icon: MewNotch.Assets.icGlobe,
                    color: MewNotch.Colors.general
                ) {
                    Toggle("", isOn: $defaults.newsEnabled)
                }

                if defaults.newsEnabled {
                    SettingsRow(
                        title: "中文化",
                        subtitle: NewsStore.translationAvailable
                            ? "快讯标题与日历指标名由 DeepSeek 译写，悬停可看英文原文"
                            : "此构建不可用 — 未注入 API key",
                        icon: MewNotch.Assets.icLabel,
                        color: MewNotch.Colors.timer
                    ) {
                        Toggle("", isOn: $defaults.newsTranslationEnabled)
                            .disabled(!NewsStore.translationAvailable)
                    }
                }
            } header: {
                Text("快讯")
            } footer: {
                Text("快讯来自 FinancialJuice 公开信息流。关闭后完全停止相关网络请求。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                SettingsRow(
                    title: "收线响铃",
                    subtitle: "5 分钟周期每个交易日约响 288 次",
                    icon: MewNotch.Assets.icBell,
                    color: MewNotch.Colors.alert
                ) {
                    Toggle("", isOn: $defaults.soundEnabled)
                }

                if defaults.soundEnabled {
                    SettingsRow(
                        title: "铃声",
                        icon: MewNotch.Assets.icAudio,
                        color: MewNotch.Colors.audio
                    ) {
                        HStack {
                            Picker("", selection: $defaults.soundName) {
                                ForEach(availableSounds, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)

                            // 试听永远只响一次，不受 Alert Mode 影响 ——
                            // 点「试听」结果开始无限循环会很吓人。
                            Button("试听") {
                                CandleAlertPlayer.shared.play(
                                    named: defaults.soundName,
                                    repeating: false
                                )
                            }
                        }
                    }

                    SettingsRow(
                        title: "响铃模式",
                        subtitle: defaults.alertMode == .once
                            ? "每根 K 线响一声"
                            : "持续响铃，直到点击刘海或菜单栏图标停止",
                        icon: MewNotch.Assets.icBell,
                        color: MewNotch.Colors.alert
                    ) {
                        Picker("", selection: $defaults.alertMode) {
                            ForEach(AlertMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    SettingsRow(
                        title: "响铃时机",
                        subtitle: "收线前 \(defaults.soundThreshold) 秒",
                        icon: MewNotch.Assets.icTimer,
                        color: MewNotch.Colors.timer
                    ) {
                        // step 5 而不是 1：这是「设一次就不动」的参数，
                        // 从 15 调到 30 点 3 下比点 15 下合理。
                        Stepper(
                            "",
                            value: $defaults.soundThreshold,
                            in: 5...max(5, defaults.period.seconds - 1),
                            step: 5
                        )
                        .labelsHidden()
                    }

                    if defaults.alertMode == .untilDismissed {
                        VStack(alignment: .leading, spacing: 6) {
                            Label {
                                Text("**点击刘海即可停止。** 响铃时整个刘海就是停止按钮 —— "
                                     + "它贴着屏幕顶边，鼠标向上一甩必中。")
                            } icon: {
                                Image(systemName: "hand.tap.fill")
                            }
                            .foregroundStyle(.primary)

                            Text("菜单栏图标此时变为响铃标志，点击同样可停。休市、关闭倒计时、"
                                 + "时钟不可信时会自动停止 —— 但不会仅因 K 线收线而自动停。")
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 44)
                        .padding(.top, 2)
                    }
                }
            } header: {
                Text("声音")
            }

            Section {
                // 没有刘海屏时 notchSize 退化为 .zero，倒计时静默地什么都不画。
                // 用户会以为 app 坏了 —— 必须把这个状态说出来。
                if let problem = renderabilityProblem {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(problem.headline)
                        } icon: {
                            MewNotch.Assets.icWarning
                        }
                        .font(.callout)
                        .foregroundStyle(.orange)

                        Text(problem.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if problem.offersSimulation {
                            Button("Show on all displays") {
                                NotchDefaults.shared.notchDisplayVisibility = .AllDisplays
                                NotchManager.shared.refreshNotches(killAllWindows: true)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }

                SettingsRow(
                    title: "校验系统时钟",
                    subtitle: "每 30 分钟对照两个 HTTPS 端点",
                    icon: MewNotch.Assets.icClockCheck,
                    color: MewNotch.Colors.session
                ) {
                    Toggle("", isOn: $defaults.clockCalibrationEnabled)
                }

                SettingsRow(
                    title: "时钟状态",
                    subtitle: clockStatusText,
                    icon: MewNotch.Assets.icGlobe,
                    color: MewNotch.Colors.diagnostics
                )

                SettingsRow(
                    title: "交易时段",
                    subtitle: engine.todaySessionDescription,
                    icon: MewNotch.Assets.icMoon,
                    color: MewNotch.Colors.session
                )

                SettingsRow(
                    title: "假期表",
                    subtitle: holidayTableText,
                    icon: MewNotch.Assets.icCalendar,
                    color: MewNotch.Colors.diagnostics
                )

                if case .fault = engine.presentation {
                    Label {
                        Text(faultBanner)
                    } icon: {
                        MewNotch.Assets.icWarning
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 44)
                }
            } header: {
                Text("诊断")
            } footer: {
                Text("K 线边界锚定在时段开盘（18:00 ET）而非 UTC 零点。"
                     + "若有出入，请以你的交易平台为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Countdown")
        .toolbarTitleDisplayMode(.inline)
    }

    // MARK: - 可渲染性自检

    private struct RenderabilityProblem {
        let headline: String
        let detail: String
        let offersSimulation: Bool
    }

    /// 检查当前设置下倒计时是否真的画得出来。
    ///
    /// `NotchUtils.notchSize` 在「屏幕没有物理刘海」且 `notchDisplayVisibility`
    /// 为 `.NotchedDisplayOnly`（默认值）时返回 `.zero`，槽位高度归零，
    /// 于是什么都不显示 —— 而且不报任何错。在 Mac mini / Mac Studio 或接外接屏
    /// 的场景下，用户会以为 app 没装好。
    private var renderabilityProblem: RenderabilityProblem? {
        let notchDefaults = NotchDefaults.shared
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let physicallyNotched = screens.filter { NotchUtils.shared.hasNotch(screen: $0) }

        // 有真刘海屏就不必提示
        if !physicallyNotched.isEmpty { return nil }

        if notchDefaults.notchDisplayVisibility == .NotchedDisplayOnly {
            return RenderabilityProblem(
                headline: "No notched display detected — nothing will be drawn",
                detail: "\"Show Notch On\" is set to \"Notched Displays Only\", and none of your "
                    + "displays has a physical notch. Switch it to \"All Displays\" to draw a "
                    + "simulated notch at the top centre of the screen, or use the menu bar icon instead.",
                offersSimulation: true
            )
        }

        // 已经强制模拟，但仍可能高度为 0（副屏没有菜单栏）
        let renderable = screens.filter { screen in
            NotchUtils.shared.notchSize(screen: screen, force: true).height > 1
        }
        if renderable.isEmpty {
            return RenderabilityProblem(
                headline: "Simulated notch has zero height on every display",
                detail: "A simulated notch takes its height from the menu bar, and none of your "
                    + "displays reports one. Move the menu bar to this display in System Settings > "
                    + "Displays > Arrange, or use the menu bar icon instead.",
                offersSimulation: false
            )
        }
        if renderable.count < screens.count {
            let names = screens
                .filter { NotchUtils.shared.notchSize(screen: $0, force: true).height <= 1 }
                .map(\.localizedName)
                .joined(separator: ", ")
            return RenderabilityProblem(
                headline: "Not visible on: \(names)",
                detail: "A simulated notch takes its height from the menu bar, which macOS only "
                    + "puts on the primary display. The countdown will only appear on the display "
                    + "that has the menu bar.",
                offersSimulation: false
            )
        }

        return nil
    }

    // MARK: - 日历文案

    private var importanceSubtitle: String {
        switch defaults.calendarMinImportance {
        case ..<0: return "全部显示，包括每周例行小数据"
        case 0: return "隐藏例行小数据，保留会动市场的"
        default: return "只看大事 —— CPI、非农、FOMC、GDP"
        }
    }

    // MARK: - Diagnostics 文案

    private var clockStatusText: String {
        switch engine.clockTrust {
        case let .verified(offset, uncertainty, at):
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .medium
            return String(
                format: "Offset %+.2fs ± %.2fs, checked at %@",
                offset, uncertainty, f.string(from: at)
            )
        case let .unverified(since, lastError):
            let hours = Int(Date().timeIntervalSince(since) / 3600)
            return "Not verified for \(hours)h — \(lastError)"
        case let .jumped(delta, _):
            return String(format: "Clock jumped %+.1fs; recalibrating", delta)
        }
    }

    private var holidayTableText: String {
        guard let table = try? HolidayTable.bundled() else {
            return "Could not be read — countdown is disabled"
        }
        let status = table.status == .verified
            ? "verified"
            : "UNVERIFIED DRAFT — check against the exchange calendar"
        return "Covers \(table.verifiedFrom) to \(table.verifiedThrough) (\(status))"
    }

    private var faultBanner: String {
        guard case let .fault(fault) = engine.presentation else { return "" }
        switch fault {
        case .clockOffsetExceedsTolerance:
            return "The countdown is hidden because the system clock cannot be trusted. "
                 + "Turn on automatic time in System Settings > General > Date & Time."
        case .clockJumped:
            return "The system clock changed; the countdown is hidden until it is re-verified."
        case .holidayTableExpired:
            return "The holiday table has expired. Session boundaries can no longer be trusted."
        case .holidayTableUnreadable:
            return "The holiday table could not be read. The countdown is disabled."
        case .calendarInconsistent:
            return "The trading calendar produced an inconsistent result. See Console for details."
        }
    }
}

#Preview {
    CountdownSettingsView()
}
