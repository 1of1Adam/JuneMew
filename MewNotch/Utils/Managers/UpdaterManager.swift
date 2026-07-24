//
//  UpdaterManager.swift
//  MewNotch
//

import Combine
import OSLog
import Sparkle
import KLineCore
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
/// # 全自动更新（默认，v1.6 起）
///
/// 检测、下载、安装全程零操作：Sparkle 每天后台检查，发现新版本
/// **静默下载**（`SUAutomaticallyUpdate`，Info.plist 默认开）。下载就绪后
/// Sparkle 的默认动作是「退出时安装」—— 但常驻 accessory app 几乎永不
/// 退出，等于永不安装。所以接管 `willInstallUpdateOnQuit`，把 Sparkle
/// 递来的立即安装块存下，在**安全窗口**自动执行（安装即重启，刘海
/// 消失几秒）：
///
/// - 休市（`dormant(.marketClosed)`）—— CME 每天 17:00 ET 起必有维护
///   时段，最坏等待不过一个交易日；
/// - 倒计时功能关闭（`dormant(.featureDisabled)`）—— 没人在用它盯盘。
///
/// **盘中（counting）与故障态绝不重启** —— 交易工具的刘海在盘中消失
/// 哪怕几秒都不可接受；fault 虽不可信但用户可能正盯着图，同样不动。
/// 等待期间仪表盘控制行亮「新版本已就绪」，点击立即安装不必等窗口。
///
/// # 提示模型（gentle reminders，自动安装关闭时的回退）
///
/// 设置里关掉自动安装后退回旧模型：后台检查发现更新时**不弹窗**
///（盘中抢焦点是最坏结局），改由 app 自己提示 ——
///
/// 1. 系统通知（每个版本只发一次，点击直达安装流程）；
/// 2. 刘海仪表盘控制行常驻「新版本」入口（通知被拒/被划走的兜底）；
/// 3. 菜单栏菜单项换成「Install Update…」。
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

    /// Sparkle 递来的「立即安装并重启」执行块。非 nil = 新版本已下载
    /// 验签完毕躺在本地，只差一次 relaunch。
    private var pendingInstallBlock: (() -> Void)?

    /// 安全窗口观察（订阅倒计时引擎的形态变化）。只在有待装更新时挂着。
    private var safeWindowCancellable: AnyCancellable?

    /// `--auto-update-eager`：无视安全窗口，下载就绪立即安装；并在启动
    /// 后立刻触发一次后台检查（绕过 24h 定时）。开发/验收专用。
    private nonisolated static var eager: Bool {
        ProcessInfo.processInfo.arguments.contains("--auto-update-eager")
    }

    var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        if Self.eager {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
                Task { @MainActor in
                    Self.logger.notice("eager 模式：立即触发后台检查")
                    self.updater.checkForUpdatesInBackground()
                }
            }
        }
    }

    /// 用户主动检查（菜单 / 设置页 / 更新提示入口）。始终弹 UI 给结果，
    /// 包括「已是最新版本」；若有挂起的后台更新会话则直接恢复呈现。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 仪表盘「新版本」入口的统一动作：已下载就绪的直接装（重启秒完），
    /// 只是发现了还没下载的走标准检查 UI。
    func installPendingOrCheck() {
        if let block = takePendingInstall() {
            Self.logger.notice("用户点击入口，立即安装已就绪的更新")
            block()
        } else {
            checkForUpdates()
        }
    }

    // MARK: - 安全窗口自动安装

    /// 取走安装块并撤下观察 —— 安装是一次性动作，取走后不可重入。
    private func takePendingInstall() -> (() -> Void)? {
        guard let block = pendingInstallBlock else { return nil }
        pendingInstallBlock = nil
        safeWindowCancellable?.cancel()
        safeWindowCancellable = nil
        return block
    }

    /// 挂起安全窗口观察：倒计时引擎形态一变就复核一次。
    /// dropFirst 不需要 —— installIfSafeNow 已单独做即时复核，
    /// @Published 的当前值重放在 guard 里天然幂等。
    private func armSafeWindowWatcher() {
        guard safeWindowCancellable == nil else { return }
        safeWindowCancellable = CountdownEngine.shared.$presentation
            .receive(on: RunLoop.main)
            .sink { [weak self] presentation in
                self?.installIfSafe(presentation)
            }
    }

    private func installIfSafeNow() {
        installIfSafe(CountdownEngine.shared.presentation)
    }

    private func installIfSafe(_ presentation: CountdownPresentation) {
        guard pendingInstallBlock != nil else { return }
        guard Self.eager || Self.isSafeInstallWindow(presentation) else { return }
        guard let block = takePendingInstall() else { return }
        Self.logger.notice("安全窗口到达，自动安装更新并重启")
        block()
    }

    /// 盘中（counting）与故障态绝不重启；休市与功能关闭是安全窗口。
    private static func isSafeInstallWindow(_ presentation: CountdownPresentation) -> Bool {
        if case .dormant = presentation { return true }
        return false
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

// MARK: - SPUUpdaterDelegate

extension UpdaterManager: SPUUpdaterDelegate {

    /// 自动下载验签完成，Sparkle 准备「退出时安装」。常驻 accessory app
    /// 几乎永不退出 —— 返回 true 接管安装时机：存下立即安装块，
    /// 安全窗口（或用户点击入口）时执行。
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            Self.logger.notice("v\(version, privacy: .public) 已自动下载就绪，等待安全窗口安装")
            self.pendingUpdateVersion = version
            self.pendingInstallBlock = immediateInstallHandler
            self.armSafeWindowWatcher()
            self.installIfSafeNow()
        }
        return true
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
    /// 安装块一并作废 —— 会话结束后它指向的临时产物不再可信，
    /// 明天的定时检查会重新下载、重新递一个新块进来。
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            self.pendingUpdateVersion = nil
            self.pendingInstallBlock = nil
            self.safeWindowCancellable?.cancel()
            self.safeWindowCancellable = nil
        }
    }
}
