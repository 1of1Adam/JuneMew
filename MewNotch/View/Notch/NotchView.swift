//
//  NotchView.swift
//  MewNotch
//
//  Created by Monu Kumar on 25/02/25.
//

import SwiftUI

struct NotchView: View {

    @StateObject var notchDefaults = NotchDefaults.shared
    @StateObject var countdownDefaults = CountdownDefaults.shared

    @StateObject var notchViewModel: NotchViewModel

    init(
        screen: NSScreen
    ) {
        self._notchViewModel = .init(
            wrappedValue: .init(
                screen: screen
            )
        )
    }

    var body: some View {
        VStack {
            HStack {
                Spacer()

                HStack(
                    spacing: 0
                ) {
                    if countdownDefaults.position == .left {
                        CountdownView(
                            notchViewModel: notchViewModel,
                            variant: .left
                        )
                    }

                    OnlyNotchView(
                        notchSize: notchViewModel.notchSize
                    )

                    if countdownDefaults.position == .right {
                        CountdownView(
                            notchViewModel: notchViewModel,
                            variant: .right
                        )
                    }
                }
                .glassEffect(when: notchDefaults.applyGlassEffect, in: NotchShape(
                    topRadius: notchViewModel.cornerRadius.top,
                    bottomRadius: notchViewModel.cornerRadius.bottom
                ))
                .background {
                    if !notchDefaults.applyGlassEffect {
                        Color.black
                    }
                }
                .mask {
                    NotchShape(
                        topRadius: notchViewModel.cornerRadius.top,
                        bottomRadius: notchViewModel.cornerRadius.bottom
                    )
                }
                // 1.1 会让盯盘时鼠标无意划过导致刘海连同倒计时弹跳 10%。
                .scaleEffect(
                    notchViewModel.isHovered ? 1.05 : 1.0,
                    anchor: .top
                )
                .shadow(
                    radius: notchViewModel.isHovered ? 5 : 0
                )
                .onHover {
                    notchViewModel.onHover($0)
                }

                Spacer()
            }

            Spacer()
        }
        .preferredColorScheme(.dark)
        .contextMenu {
            NotchOptionsView()
        }
        // 从已删除的 CollapsedNotchView 搬来。这是设置变更后重算刘海尺寸的唯一
        // 触发点 —— 不搬的话改 heightMode / notchDisplayVisibility 将完全无响应。
        .onReceive(
            notchDefaults.objectWillChange
        ) {
            notchViewModel.refreshNotchSize()
        }
    }
}
