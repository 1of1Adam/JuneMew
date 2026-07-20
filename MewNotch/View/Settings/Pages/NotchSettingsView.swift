//
//  NotchSettingsView.swift
//  MewNotch
//
//  Created by Monu Kumar on 23/03/25.
//

import SwiftUI


struct NotchSettingsView: View {
    
    @Environment(\.scenePhase) private var scenePhase
    
    @StateObject private var viewModel = NotchSettingsViewModel()
    
    @StateObject var notchDefaults = NotchDefaults.shared

    var body: some View {
        Form {
            Section {
                SettingsRow(
                    title: "Show Notch On",
                    icon: MewNotch.Assets.icDisplay,
                    color: MewNotch.Colors.notch
                ) {
                    Picker("", selection: ~$notchDefaults.notchDisplayVisibility) {
                        ForEach(NotchDisplayVisibility.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                }
                
                if notchDefaults.notchDisplayVisibility == .Custom {
                    VStack(spacing: 8) {
                        Text("Choose Displays to show notch on")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(viewModel.screens, id: \.self) { screen in
                                    ScreenSelectionCard(screen: screen, notchDefaults: notchDefaults)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                SettingsRow(
                    title: "Show on Lock Screen",
                    subtitle: "Keep the countdown visible while the screen is locked",
                    icon: MewNotch.Assets.icLock,
                    color: MewNotch.Colors.lock
                ) {
                    Toggle("", isOn: $notchDefaults.shownOnLockScreen)
                        .onChange(of: notchDefaults.shownOnLockScreen) { _, _ in
                            viewModel.refreshNotchesAndKillWindows()
                        }
                }
                
                SettingsRow(
                    title: "Hide on Full Screen",
                    subtitle: "Hides the notch when a full screen app is detected",
                    icon: MewNotch.Assets.icDisplay,
                    color: MewNotch.Colors.notch
                ) {
                    Toggle("", isOn: $notchDefaults.hideOnFullScreen)
                        .onChange(of: notchDefaults.hideOnFullScreen) { _, _ in
                            viewModel.refreshNotches()
                        }
                }
                
            } header: {
                Text("Displays")
            }
            
            Section {
                SettingsRow(
                    title: "Height",
                    icon: MewNotch.Assets.icHeight,
                    color: MewNotch.Colors.height
                ) {
                    Picker("", selection: $notchDefaults.heightMode) {
                        ForEach([NotchHeightMode.Match_Notch, NotchHeightMode.Match_Menu_Bar]) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                }
                
                if #available(macOS 26.0, *) {
                    SettingsRow(
                        title: "Apply Glass Effect",
                        subtitle: "Use the Liquid Glass material for the notch body",
                        icon: MewNotch.Assets.icGlass,
                        color: MewNotch.Colors.glass
                    ) {
                        Toggle("", isOn: ~$notchDefaults.applyGlassEffect)
                    }
                }
            } header: {
                Text("Interface")
            }

            Section {
                SettingsRow(
                    title: "Haptic Feedback",
                    subtitle: "Play haptic feedback when hovering over the notch",
                    icon: MewNotch.Assets.icHaptic,
                    color: MewNotch.Colors.haptic
                ) {
                    Toggle("", isOn: $notchDefaults.hapticFeedback)
                }
            } header: {
                Text("Interaction")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notch")
        .toolbarTitleDisplayMode(.inline)
        .onChange(
            of: notchDefaults.shownOnDisplay
        ) { _, _ in
             viewModel.refreshNotches()
        }
    }
}

struct ScreenSelectionCard: View {
    let screen: NSScreen
    @ObservedObject var notchDefaults: NotchDefaults
    
    private var isSelected: Bool {
        notchDefaults.shownOnDisplay[screen.localizedName] == true
    }
    
    var body: some View {
        Text(screen.localizedName)
            .font(.subheadline)
            .frame(minHeight: 50)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
                    .padding(1)
            )
            .onTapGesture {
                let old = notchDefaults.shownOnDisplay[screen.localizedName] ?? false
                withAnimation(.easeInOut(duration: 0.2)) {
                    notchDefaults.shownOnDisplay[screen.localizedName] = !old
                }
            }
    }
}

#Preview {
    NotchSettingsView()
}
