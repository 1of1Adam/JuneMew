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

                // 图标与数字分居刘海两侧：数字在设定的一边，图标在对侧。
                // 这沿用了项目原有的语法（左槽图标、右槽数值），也让刘海
                // 两边都有内容而不是一头沉。
                HStack(
                    spacing: 0
                ) {
                    CountdownView(
                        notchViewModel: notchViewModel,
                        variant: .left,
                        role: countdownDefaults.position == .left ? .digits : .icon
                    )

                    OnlyNotchView(
                        notchSize: notchViewModel.notchSize
                    )

                    CountdownView(
                        notchViewModel: notchViewModel,
                        variant: .right,
                        role: countdownDefaults.position == .right ? .digits : .icon
                    )
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
                // 刻意不做任何 hover 反馈：盯盘时鼠标无意划过刘海不该引起
                // 任何视觉变化。右键菜单仍然可用（见下方 contextMenu）。

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
