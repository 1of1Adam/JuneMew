//
//  CandleAlertPlayer.swift
//  MewNotch
//

import AppKit
import Combine
import OSLog

/// 播放收线提醒音。
///
/// 用系统音而非打包音频：零体积、遵循用户的系统音频路由，
/// 而且可以枚举 `/System/Library/Sounds` 让用户在设置里挑 + 试听。
@MainActor
final class CandleAlertPlayer: NSObject, ObservableObject {

    static let shared = CandleAlertPlayer()

    private let logger = Logger(subsystem: "io.github.1of1adam.JuneMew", category: "alert")

    /// 正在持续响铃。UI 据此显示「停止」入口 ——
    /// 一个停不掉的循环提示音是灾难，停止入口必须始终可达。
    @Published private(set) var isAlerting = false

    /// 必须强引用：`NSSound` 实例被释放后会立刻停止播放。
    private var sound: NSSound?
    private var loadedName: String?

    private override init() {
        super.init()
    }

    /// 系统可用音效名。
    ///
    /// 按实际文件枚举而不是硬编码列表：不同 macOS 版本的音效集会变，
    /// 而且这样能顺带把用户放在 `~/Library/Sounds` 的自定义音效也列进来。
    /// （实测 macOS 27 仍是经典音效集：Basso / Funk / Glass / Ping / Tink …）
    nonisolated static func availableSoundNames() -> [String] {
        let directories = [
            "/System/Library/Sounds",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds")
        ]

        var names: Set<String> = []
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for file in files {
                let name = (file as NSString).deletingPathExtension
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names.sorted()
    }

    /// 播放提醒。
    ///
    /// - Parameters:
    ///   - name: 系统音名
    ///   - repeating: true 则循环播放直到 `dismiss()` 被调用
    func play(named name: String, repeating: Bool) {
        // 已经在持续响了就不重启 —— 否则下一根 K 线到阈值时声音会从头跳一下，
        // 听感上像卡带。用户没停之前，就让它一直响同一轮。
        if isAlerting, repeating {
            return
        }

        guard let loaded = loadSound(named: name) else { return }

        // 对正在播放的实例调 play() 会返回 false，先停再播
        if loaded.isPlaying { loaded.stop() }

        loaded.loops = repeating
        loaded.delegate = repeating ? self : nil

        if loaded.play() {
            isAlerting = repeating
        } else {
            logger.error("系统音 \"\(name, privacy: .public)\" 播放失败")
        }
    }

    /// 停止持续响铃。手动关闭、休市、功能关闭时调用。
    ///
    /// 幂等：没在响时调用是安全的空操作。
    func dismiss() {
        if let sound, sound.isPlaying {
            sound.stop()
        }
        if isAlerting {
            isAlerting = false
        }
    }

    private func loadSound(named name: String) -> NSSound? {
        if loadedName == name, let sound {
            return sound
        }
        guard let loaded = NSSound(named: NSSound.Name(name)) else {
            // 不静默失败：音效名可能因系统升级而失效（macOS 15 换过音效集）
            logger.error("系统音 \"\(name, privacy: .public)\" 不可用，本次提醒未发声")
            return nil
        }
        sound = loaded
        loadedName = name
        return loaded
    }
}

extension CandleAlertPlayer: NSSoundDelegate {
    /// 循环播放时理论上不会走到这里；真走到了说明循环被系统中断
    /// （例如音频设备切换），此时如实把状态改回来，不留一个「假装还在响」的
    /// 停止按钮。
    nonisolated func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        Task { @MainActor in
            guard self.isAlerting else { return }
            self.logger.notice("循环提醒被中断（finished=\(finished, privacy: .public)），状态已复位")
            self.isAlerting = false
        }
    }
}
