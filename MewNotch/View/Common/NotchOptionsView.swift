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

    @StateObject private var appDefaults = AppDefaults.shared
    @StateObject private var countdownDefaults = CountdownDefaults.shared

    var type: OptionsType = .ContextMenu

    var body: some View {
        // Toggle 在 macOS 菜单里会渲染成带勾选标记的菜单项。
        // 放在最前面 —— 这是盘中最常用的一项，不该埋在下面。
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
