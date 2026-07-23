//
//  SecretVault.swift
//  MewNotch
//

import Foundation

/// 构建期注入的密钥。
///
/// key 本体永远不进 git：`scripts/gen-secrets.sh` 把本机
/// `~/Documents/JuneMew-deepseek-key` XOR 混淆后写进 bundle 资源
/// （`deepseek.key.enc`，已 .gitignore）。这里运行时解出。
///
/// 边界要诚实：XOR 是混淆不是加密 —— 防的是 GitHub 上的 secret
/// 扫描机器人和对二进制的 `strings` 扫描；有耐心逆向 .app 的人
/// 仍能取出 key。key 要当成「可随时作废重开」的凭证来管理。
enum SecretVault {

    /// 与 scripts/gen-secrets.sh 中严格一致的混淆 pad。
    /// pad 本身不是秘密，只是让密文在二进制里呈现为乱码。
    private static let pad: [UInt8] = [
        0xaa, 0xd8, 0x3a, 0x72, 0x85, 0x1f, 0x00, 0xcf,
        0xc2, 0xa6, 0xb4, 0x62, 0xa9, 0xc5, 0xc7, 0x97,
        0x87, 0xa3, 0x04, 0xef, 0x4b, 0x18, 0x22, 0xcb,
        0x48, 0x53, 0xcd, 0xc6, 0xfa, 0xe4, 0x9d, 0x92,
    ]

    /// DeepSeek API key。资源缺失（未跑 gen-secrets 的构建、他人 clone
    /// 的构建）时为 nil —— 翻译功能整体不启用，新闻显示英文原文。
    static let deepSeekAPIKey: String? = {
        guard let url = Bundle.main.url(forResource: "deepseek.key", withExtension: "enc"),
              let blob = try? Data(contentsOf: url), !blob.isEmpty else {
            return nil
        }
        let bytes = blob.enumerated().map { index, byte in
            byte ^ pad[index % pad.count]
        }
        guard let key = String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }()
}
