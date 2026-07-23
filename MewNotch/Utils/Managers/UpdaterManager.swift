//
//  UpdaterManager.swift
//  MewNotch
//

import Combine
import Sparkle

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
@MainActor
final class UpdaterManager: ObservableObject {

    static let shared = UpdaterManager()

    /// 标准控制器自带完整更新 UI（提示、进度、发行说明），
    /// 本 app 无自定义诉求，不接 delegate。
    private let controller: SPUStandardUpdaterController

    /// 供「Check for Updates…」菜单项做 disabled 绑定 ——
    /// 检查已在进行时再点一次应当被拒绝，而不是叠一层进度窗。
    @Published private(set) var canCheckForUpdates = false

    var updater: SPUUpdater { controller.updater }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// 用户主动检查。与后台定时检查不同，这条路径始终弹 UI 给结果，
    /// 包括「已是最新版本」。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
