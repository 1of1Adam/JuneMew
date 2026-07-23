//
//  GeneraSettingsView.swift
//  MewNotch
//
//  Created by Monu Kumar on 27/02/25.
//

import SwiftUI
import LaunchAtLogin

struct GeneraSettingsView: View {

    @ObservedObject var appDefaults = AppDefaults.shared
    @ObservedObject var updaterManager = UpdaterManager.shared

    /// Sparkle 自己在 defaults 里持久化这个开关，不走本项目的
    /// `@PrimitiveUserDefault` —— 用本地 @State 镜像它并双向同步。
    @State private var automaticallyChecksForUpdates =
        UpdaterManager.shared.updater.automaticallyChecksForUpdates

    var body: some View {
        Form {
            Section {
                SettingsRow(
                    title: "Launch at Login",
                    subtitle: "Automatically start JuneMew when you log in",
                    icon: MewNotch.Assets.icLaunchAtLogin,
                    color: MewNotch.Colors.style
                ) {
                    LaunchAtLogin.Toggle {
                        Text("")
                    }
                    .labelsHidden()
                }

                SettingsRow(
                    title: "Status Icon",
                    subtitle: "Show icon in menu bar for easy access",
                    icon: MewNotch.Assets.icStatusIcon,
                    color: MewNotch.Colors.general
                ) {
                    Toggle("", isOn: $appDefaults.showMenuIcon)
                }
            } header: {
                Text("App")
            }

            Section {
                SettingsRow(
                    title: "Automatic Updates",
                    subtitle: "Check GitHub daily and offer new versions. "
                        + "Updates are verified with an ed25519 signature.",
                    icon: MewNotch.Assets.icLaunchAtLogin,
                    color: MewNotch.Colors.session
                ) {
                    Toggle("", isOn: Binding(
                        get: { automaticallyChecksForUpdates },
                        set: { newValue in
                            automaticallyChecksForUpdates = newValue
                            updaterManager.updater.automaticallyChecksForUpdates = newValue
                        }
                    ))
                }

                SettingsRow(
                    title: "Check Now",
                    subtitle: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
                    icon: MewNotch.Assets.icReset,
                    color: MewNotch.Colors.general
                ) {
                    Button("Check for Updates…") {
                        updaterManager.checkForUpdates()
                    }
                    .disabled(!updaterManager.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

#Preview {
    GeneraSettingsView()
}
