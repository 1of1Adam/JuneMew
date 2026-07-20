//
//  GeneraSettingsView.swift
//  MewNotch
//
//  Created by Monu Kumar on 27/02/25.
//

import SwiftUI
import LaunchAtLogin

struct GeneraSettingsView: View {
    
    @StateObject var appDefaults = AppDefaults.shared

    var body: some View {
        Form {
            Section {
                SettingsRow(
                    title: "Launch at Login",
                    subtitle: "Automatically start MewNotch when you log in",
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
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

#Preview {
    GeneraSettingsView()
}
