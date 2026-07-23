//
//  UpdaterManager.swift
//  MewNotch
//

import Combine
import OSLog
import Sparkle
// UNUserNotificationCenter 实际线程安全，但 SDK 的 Sendable 注解未跟上 ——
// preconcurrency 抑制的是注解缺口，不是真实的数据竞争。
@preconcurrency import UserNotifications

/// Sparkle 更新器宿主。
///
/// 无 Apple Developer 账号下的更新安全模型：发版时用本机保管的 ed25519
/// 私钥给更新包签名（`sign_update`），app 用 Info.plist 里的 `SUPublicEDKey`
/// 公钥验证 —— 整条链路不依赖苹果的签名体系，ad-hoc 分发也能安全自更新。
///
/// 附带的体验收益：Sparkle 自己下载安装的更新不带 quarantine 标记，
/// 用户只在**首次**安装时需要手动放行 Gatekeeper，之后的每次更新
/// 都不会再弹「已损坏」。对无公证 app 来说，自动更新反而比让用户
/// 重新下载 DMG 更顺滑。
///
/// # 提示模型（gentle reminders）
///
/// 本 app 是 `.accessory` 策略的后台刘海应用 —— Sparkle 默认的
/// 「定时检查发现更新就弹标准窗口」在这里是最坏的两种结局之一：
/// 盘中突然抢焦点，或者弹窗压在别人窗口后面根本没人看见。
/// 所以接管 `SPUStandardUserDriverDelegate`：后台检查发现更新时
/// **不弹窗**，改由 app 自己提示 ——
///
/// 1. 系统通知（每个版本只发一次，点击直达安装流程）；
/// 2. 刘海仪表盘控制行常驻「新版本」入口（通知被拒/被划走的兜底）；
/// 3. 菜单栏菜单项换成「Install Update…」。
///
/// 用户从任一入口进来都走 `checkForUpdates()` —— Sparkle 会恢复
/// 挂起的更新会话，直接呈现已发现的版本，不重新检查。
@MainActor
final class UpdaterManager: NSObject, ObservableObject {

    static let shared = UpdaterManager()

    /// 更新通知的固定 identifier —— AppDelegate 用它识别点击来源；
    /// 固定值也让新版本的通知自动替换旧版本的，通知中心不堆积。
    /// nonisolated：通知系统的回调在任意线程，这些不可变常量必须能被
    /// 非隔离上下文读取。
    nonisolated static let updateNotificationID = "io.github.1of1adam.JuneMew.update"

    private nonisolated static let lastNotifiedVersionKey = "Update_LastNotifiedVersion"

    private nonisolated static let logger = Logger(
        subsystem: "io.github.1of1adam.JuneMew",
        category: "updater"
    )

    /// 标准控制器自带完整更新 UI（提示、进度、发行说明）；
    /// userDriverDelegate 只接管「定时检查发现更新时如何提醒」这一步。
    private var controller: SPUStandardUpdaterController!

    /// 供「Check for Updates…」菜单项做 disabled 绑定 ——
    /// 检查已在进行时再点一次应当被拒绝，而不是叠一层进度窗。
    @Published private(set) var canCheckForUpdates = false

    /// 后台定时检查发现、用户尚未处理的新版本号。非 nil 时仪表盘
    /// 控制行与菜单显示更新入口；更新会话结束（装了或明确放弃）时清空。
    /// 变化频率：天级 —— 订阅它不会破坏面板的低频重绘模型。
    @Published private(set) var pendingUpdateVersion: String?

    var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// 用户主动检查（菜单 / 设置页 / 更新提示入口）。始终弹 UI 给结果，
    /// 包括「已是最新版本」；若有挂起的后台更新会话则直接恢复呈现。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - 系统通知

    /// 每个版本只发一次 —— Sparkle 每天定时检查，用户没装的话
    /// 每天都会重新走到这里，不能每天横幅骚扰一遍；刘海入口
    /// 会一直亮着，常驻提醒交给它。
    private func postNotificationOncePerVersion(_ version: String) {
        guard UserDefaults.standard.string(forKey: Self.lastNotifiedVersionKey) != version else {
            return
        }

        let center = UNUserNotificationCenter.current()
        // 权限请求刻意延迟到第一次真有更新要提示的时刻 —— 启动即索要
        // 通知权限的 app，用户只会下意识点拒绝。
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Self.logger.error("通知授权失败：\(error.localizedDescription, privacy: .public)")
                return
            }
            guard granted else {
                Self.logger.notice("通知权限被拒 — 更新提示仅保留刘海入口")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "JuneMew 有新版本"
            content.body = "v\(version) 已就绪 — 点击开始安装"

            let request = UNNotificationRequest(
                identifier: Self.updateNotificationID,
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    Self.logger.error("投递更新通知失败：\(error.localizedDescription, privacy: .public)")
                    return
                }
                UserDefaults.standard.set(version, forKey: Self.lastNotifiedVersionKey)
            }
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdaterManager: SPUStandardUserDriverDelegate {

    /// 声明支持温和提醒 —— Sparkle 由此把「怎么提示定时更新」交给我们。
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 定时检查发现了更新：要不要立刻弹标准窗口？
    /// 只有 app 恰好持有焦点时才允许（accessory 策略下几乎不会发生）；
    /// 其余情况返回 false —— Sparkle 挂起会话，提醒由我们来。
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Sparkle 自己弹窗的场合（用户主动检查 / immediateFocus）无需插手。
        guard !handleShowingUpdate else { return }

        let version = update.displayVersionString
        Task { @MainActor in
            Self.logger.notice("后台发现新版本 v\(version, privacy: .public)，转入温和提醒")
            self.pendingUpdateVersion = version
            self.postNotificationOncePerVersion(version)
        }
    }

    /// 用户已亲眼看到 Sparkle 的更新 UI —— 系统通知的使命完成，撤掉。
    nonisolated func standardUserDriverDidReceiveUserAttention(
        forUpdate update: SUAppcastItem
    ) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.updateNotificationID]
        )
    }

    /// 更新会话收尾（安装重启、或用户明确放弃）：撤下所有入口。
    /// 若用户选了「跳过此版本」，Sparkle 之后不会再报这个版本；
    /// 若只是关掉窗口，明天的定时检查会重新点亮入口。
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            self.pendingUpdateVersion = nil
        }
    }
}
