//
//  AboutAppView.swift
//  MewNotch
//
//  Created by Monu Kumar on 27/02/25.
//

import SwiftUI

struct AboutAppView: View {

    /// Sparkle 移除后直读 bundle。读不到说明构建产物异常，
    /// 显示 "unknown" 而不是隐藏这一行 —— 让异常可见。
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    var body: some View {
        VStack(spacing: 32) {
            
            VStack(spacing: 16) {

                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .shadow(radius: 10)
                
                VStack(spacing: 8) {
                    Text("MewNotch")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(MewNotch.Colors.notch.color)
                    
                    Text("Version \(currentVersion)")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            Capsule()
                                .fill(.tertiary.opacity(0.2))
                        }
                }
            }

            VStack(spacing: 16) {
                Button(action: {
                    if let url = URL(string: "https://github.com/monuk7735/mew-notch") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("View on GitHub")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: 160)
                }
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
    }
}

#Preview {
    AboutAppView()
}
