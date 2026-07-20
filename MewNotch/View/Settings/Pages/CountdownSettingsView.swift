//
//  CountdownSettingsView.swift
//  MewNotch
//

import SwiftUI
import KLineCore

struct CountdownSettingsView: View {

    @StateObject private var defaults = CountdownDefaults.shared
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
                            defaults.period = newPeriod
                            defaults.applyRecommendedThresholds(for: newPeriod)
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

                            Button("Test") {
                                CandleAlertPlayer.shared.play(named: defaults.soundName)
                            }
                        }
                    }

                    SettingsRow(
                        title: "Sound Threshold",
                        subtitle: "Fires once per bar, \(defaults.soundThreshold)s before close",
                        icon: MewNotch.Assets.icTimer,
                        color: MewNotch.Colors.timer
                    ) {
                        Stepper(
                            "",
                            value: $defaults.soundThreshold,
                            in: 1...max(1, defaults.period.seconds - 1),
                            step: 1
                        )
                        .labelsHidden()
                    }
                }
            } header: {
                Text("Sound")
            }

            Section {
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
