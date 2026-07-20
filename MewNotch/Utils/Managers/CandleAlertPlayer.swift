//
//  CandleAlertPlayer.swift
//  MewNotch
//

import AppKit
import OSLog

/// 播放收线提醒音。
///
/// 用系统音而非打包音频：零体积、遵循用户的系统音频路由，
/// 而且可以枚举 `/System/Library/Sounds` 让用户在设置里挑 + 试听。
final class CandleAlertPlayer {

    static let shared = CandleAlertPlayer()

    private let logger = Logger(subsystem: "com.monuk7735.mew.notch", category: "alert")

    /// 必须强引用：`NSSound` 实例被释放后会立刻停止播放。
    private var sound: NSSound?
    private var loadedName: String?

    private init() {}

    /// 系统可用音效名。
    ///
    /// 按实际文件枚举而不是硬编码列表：不同 macOS 版本的音效集会变，
    /// 而且这样能顺带把用户放在 `~/Library/Sounds` 的自定义音效也列进来。
    /// （实测 macOS 27 仍是经典音效集：Basso / Funk / Glass / Ping / Tink …）
    static func availableSoundNames() -> [String] {
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

    func play(named name: String) {
        if loadedName != name || sound == nil {
            guard let loaded = NSSound(named: NSSound.Name(name)) else {
                // 不静默失败：音效名可能因系统升级而失效（macOS 15 换过音效集）
                logger.error("系统音 \"\(name, privacy: .public)\" 不可用，本次提醒未发声")
                return
            }
            sound = loaded
            loadedName = name
        }

        guard let sound else { return }
        // 对正在播放的实例调 play() 会返回 false，先停再播
        if sound.isPlaying { sound.stop() }
        if !sound.play() {
            logger.error("系统音 \"\(name, privacy: .public)\" 播放失败")
        }
    }
}
