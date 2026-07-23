//
//  NotchOptionsView.swift
//  MewNotch
//
//  Created by Monu Kumar on 15/05/25.
//

import SwiftUI

/// 同时供菜单栏图标和刘海的右键菜单使用。
struct NotchOptionsView: View {

    enum OptionsType {
        case ContextMenu
        case MenuBar
    }

    @Environment(\.openSettings) private var openSettings

    @ObservedObject private var appDefaults = AppDefaults.shared
    @ObservedObject private var countdownDefaults = CountdownDefaults.shared
    @ObservedObject private var alertPlayer = CandleAlertPlayer.shared
    @ObservedObject private var updaterManager = UpdaterManager.shared

    var type: OptionsType = .ContextMenu

    var body: some View {
        // 响铃时的兜底入口。主入口是「点击刘海」——
        // 那个目标在屏幕顶边、又宽，比翻菜单快得多。
        //
        // 这里刻意**不加** keyboardShortcut：本 app 是 .accessory 策略，
        // 永远不会成为 active app，菜单项的快捷键只在菜单已经打开时才响应，
        // 标在这里只会误导用户以为存在全局热键。真要做全局热键得上
        // Carbon RegisterEventHotKey，那是另一件事。
        if alertPlayer.isAlerting {
            Button("🔕  Stop Alert") {
                CandleAlertPlayer.shared.dismiss()
            }

            Divider()
        }

        // Toggle 在 macOS 菜单里会渲染成带勾选标记的菜单项。
        // 放在前面 —— 这是盘中最常用的一项，不该埋在下面。
        Toggle(
            "Show Countdown",
            isOn: $countdownDefaults.isEnabled
        )
        .keyboardShortcut(
            "K",
            modifiers: [.command, .shift]
        )

        Divider()

        Button("Refresh Notch") {
            NotchManager.shared.refreshNotches(killAllWindows: true)
        }
        .keyboardShortcut("R", modifiers: .command)

        // 后台已发现新版本时，换成明确的安装入口 —— 「检查」这个动作
        // 已经完成了，菜单不该还让用户去「检查」。
        if let version = updaterManager.pendingUpdateVersion {
            Button("Install Update v\(version)…") {
                updaterManager.checkForUpdates()
            }
        } else {
            Button("Check for Updates…") {
                updaterManager.checkForUpdates()
            }
            .disabled(!updaterManager.canCheckForUpdates)
        }

        Button("Settings") {
            openSettings()
        }
        .keyboardShortcut(
            ",",
            modifiers: .command
        )

        Divider()

        Button("Quit") {
            AppManager.shared.kill()
        }
        // 原本这里错标成 ⌘R（那是 Refresh 的惯例键），退出应当是 ⌘Q。
        .keyboardShortcut("Q", modifiers: .command)
    }
}

#Preview {
    NotchOptionsView()
}
