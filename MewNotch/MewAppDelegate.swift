//
//  MewAppDelegate.swift
//  MewNotch
//
//  Created by Monu Kumar on 25/02/25.
//

import SwiftUI
import UserNotifications

class MewAppDelegate: NSObject, NSApplicationDelegate {
    
    @Environment(\.openWindow) var openWindow
    @Environment(\.openSettings) var openSettingsWindow
    
    private var timer: Timer? = nil
    
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        return false
    }
    
    func applicationWillTerminate(
        _ notification: Notification
    ) {
        NotificationCenter.default.removeObserver(self)
    }
    
    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        // 必须先于任何 Defaults 单例被读取。这些单例都是 lazy 的，
        // 此处是它们首次被触碰之前的最后机会。
        Self.migrateDefaultsFromOldBundleID()

        // 触发 Sparkle 启动（startingUpdater: true 会开始后台定时检查）。
        _ = UpdaterManager.shared

        // 必须在任何通知可能投递之前挂上，否则点击通知只会激活 app、
        // 不会进入安装流程。
        UNUserNotificationCenter.current().delegate = self

        timer = .scheduledTimer(
            withTimeInterval: 30,
            repeats: false
        ) { _ in
            NotchManager.shared.refreshNotches(killAllWindows: true)
        }

        NotchManager.shared.refreshNotches(
            addToSeparateSpace: false
        )

        CountdownEngine.shared.start()

        // 经济日历与快讯：读缓存秒显 + 后台刷新。各自检查开关。
        EconomicCalendarStore.shared.start()
        NewsStore.shared.start()

        // `--news-flash-demo`：启动 3 秒后自动播放红色快讯演示队列。
        // 开发/验收专用 —— 不用等一条真实的红色新闻才能看到弹幅。
        if ProcessInfo.processInfo.arguments.contains("--news-flash-demo") {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                Task { @MainActor in
                    NewsFlashCenter.shared.enqueueDemo()
                }
            }
        }

        NSApp.setActivationPolicy(.accessory)
    }

    /// 从旧 bundle ID（`com.monuk7735.mew.notch`，fork 自 MewNotch 时沿用）
    /// 的 defaults 域一次性搬到当前域。
    ///
    /// 改 bundle ID 是对外发布前的最后窗口，但换域会让 UserDefaults 从零
    /// 开始 —— 用户手调的阈值、周期、音效不能就这么清零。只搬本项目
    /// 自己的三个前缀，Sparkle/系统的 key 不碰；只填空缺，不覆盖新域
    /// 已有的值（迁移必须幂等且不可能倒退）。
    private static func migrateDefaultsFromOldBundleID() {
        let marker = "MigratedFromMewNotchDomain"
        let standard = UserDefaults.standard
        guard !standard.bool(forKey: marker) else { return }
        defer { standard.set(true, forKey: marker) }

        guard let old = UserDefaults(suiteName: "com.monuk7735.mew.notch") else { return }

        let prefixes = ["App_", "Notch_", "Countdown_"]
        for (key, value) in old.dictionaryRepresentation()
        where prefixes.contains(where: { key.hasPrefix($0) }) {
            if standard.object(forKey: key) == nil {
                standard.set(value, forKey: key)
            }
        }
    }
    
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            openSettingsWindow.callAsFunction()
        }
        
        return !hasVisibleWindows
    }
    
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        timer?.invalidate()

        return .terminateNow
    }
}

// MARK: - 更新通知点击

extension MewAppDelegate: UNUserNotificationCenterDelegate {

    /// 点击「有新版本」通知 → 直达 Sparkle 安装流程（恢复挂起的会话）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == UpdaterManager.updateNotificationID
        else { return }

        await MainActor.run {
            UpdaterManager.shared.installPendingOrCheck()
        }
    }
}
