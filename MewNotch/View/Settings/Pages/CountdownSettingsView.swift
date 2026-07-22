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
                    title: "Enabled",
                    subtitle: "Show the bar countdown on the notch",
                    icon: MewNotch.Assets.icCandle,
                    color: MewNotch.Colors.countdown
                ) {
                    Toggle("", isOn: $defaults.isEnabled)
                }

                SettingsRow(
                    title: "Period",
                    subtitle: "CME Globex futures (ES / NQ / MES / MNQ)",
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
                    title: "Position",
                    subtitle: "Right sits next to the status icons, which you can rearrange",
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
                    title: "Show Period Label",
                    subtitle: defaults.showPeriodLabel
                        ? "Renders \"\(defaults.period.displayName) 04:32\""
                        : "Renders \"04:32\"",
                    icon: MewNotch.Assets.icLabel,
                    color: MewNotch.Colors.general
                ) {
                    Toggle("", isOn: $defaults.showPeriodLabel)
                }

                SettingsRow(
                    title: "Show Icon",
                    subtitle: "Sits on the \(defaults.position.opposite.displayName.lowercased()) "
                        + "side, opposite the digits",
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

            } header: {
                Text("Countdown")
            }

            Section {
                SettingsRow(
                    title: "Warning",
                    subtitle: "Turns amber with \(defaults.warningThreshold)s left",
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
                    title: "Urgent",
                    subtitle: "Turns red and glows with \(defaults.urgentThreshold)s left",
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
                Text("Thresholds")
            } footer: {
                Text("Absolute seconds, not a share of the period — your reaction window "
                     + "doesn't shrink just because the bar is shorter.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                SettingsRow(
                    title: "Play Sound",
                    subtitle: "A 5m period fires roughly 288 times per session",
                    icon: MewNotch.Assets.icBell,
                    color: MewNotch.Colors.alert
                ) {
                    Toggle("", isOn: $defaults.soundEnabled)
                }

                if defaults.soundEnabled {
                    SettingsRow(
                        title: "Sound",
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
                            Button("Test") {
                                CandleAlertPlayer.shared.play(
                                    named: defaults.soundName,
                                    repeating: false
                                )
                            }
                        }
                    }

                    SettingsRow(
                        title: "Alert Mode",
                        subtitle: defaults.alertMode == .once
                            ? "One beep per bar"
                            : "Keeps ringing until you stop it from the menu bar icon",
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
                        title: "Alert At",
                        subtitle: "\(defaults.soundThreshold)s before the bar closes",
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
                                Text("**Click the notch to stop it.** The notch turns into a "
                                     + "stop button while ringing — it sits at the top edge of "
                                     + "the screen, so flicking the pointer upwards always hits it.")
                            } icon: {
                                Image(systemName: "hand.tap.fill")
                            }
                            .foregroundStyle(.primary)

                            Text("The menu bar icon becomes a bell and also stops it. "
                                 + "The sound stops on its own when the market closes, when you "
                                 + "turn the countdown off, or if the clock becomes unreliable — "
                                 + "but it will not stop just because the bar closed.")
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 44)
                        .padding(.top, 2)
                    }
                }
            } header: {
                Text("Sound")
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
                    title: "Verify System Clock",
                    subtitle: "Compares against two HTTPS endpoints every 30 minutes",
                    icon: MewNotch.Assets.icClockCheck,
                    color: MewNotch.Colors.session
                ) {
                    Toggle("", isOn: $defaults.clockCalibrationEnabled)
                }

                SettingsRow(
                    title: "Clock Status",
                    subtitle: clockStatusText,
                    icon: MewNotch.Assets.icGlobe,
                    color: MewNotch.Colors.diagnostics
                )

                SettingsRow(
                    title: "Session",
                    subtitle: engine.todaySessionDescription,
                    icon: MewNotch.Assets.icMoon,
                    color: MewNotch.Colors.session
                )

                SettingsRow(
                    title: "Holiday Table",
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
                Text("Diagnostics")
            } footer: {
                Text("Bar boundaries are anchored to the session open (18:00 ET), not to UTC "
                     + "midnight. Compare against your charting platform if anything looks off.")
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
