//
//  MewNotchApp.swift
//  MewNotch
//
//  Created by Monu Kumar on 25/02/25.
//

import SwiftUI

@main
struct MewNotchApp: App {

    @NSApplicationDelegateAdaptor(MewAppDelegate.self) var mewAppDelegate

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @ObservedObject private var appDefaults = AppDefaults.shared
    @ObservedObject private var alertPlayer = CandleAlertPlayer.shared

    @State private var isMenuShown: Bool = true

    init() {
        self._isMenuShown = .init(
            initialValue: self.appDefaults.showMenuIcon
        )
    }

    var body: some Scene {
        MenuBarExtra(
            isInserted: $isMenuShown,
            content: {
                Text("JuneMew")
                
                NotchOptionsView()
            }
        ) {
            // 第二入口：刘海可能被全屏应用挡住、或在另一块屏上，
            // 而菜单栏图标始终可见。响铃时它换成铃铛，既是状态提示
            // 也是「这里能关」的指引。
            if alertPlayer.isAlerting {
                Image(systemName: "bell.fill")
            } else {
                MewNotch.Assets.iconMenuBar
                    .renderingMode(.template)
            }
        }
        .onChange(
            of: appDefaults.showMenuIcon
        ) { oldVal, newVal in
            if oldVal != newVal {
                isMenuShown = newVal
            }
        }
        
        Settings {
            MewSettingsView()
        }
        .windowResizability(.contentSize)
    }
}
