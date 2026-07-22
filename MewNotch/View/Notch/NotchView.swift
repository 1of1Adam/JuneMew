//
//  NotchView.swift
//  MewNotch
//
//  Created by Monu Kumar on 25/02/25.
//

import SwiftUI

struct NotchView: View {

    @ObservedObject var notchDefaults = NotchDefaults.shared
    @ObservedObject var countdownDefaults = CountdownDefaults.shared
    @ObservedObject var alertPlayer = CandleAlertPlayer.shared

    @StateObject var notchViewModel: NotchViewModel

    /// 响铃时鼠标是否悬停在刘海上。只在响铃时有意义 ——
    /// 常态下刘海对鼠标毫无反应，这是盯盘工具该有的克制。
    @State private var isHoveringToStop = false

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
                // 响铃且悬停时，黑色形体透出一层暖光 —— 明确回答「这里能点吗」。
                // 只是提亮，不改变尺寸：刘海在视野边缘变大会让人分心。
                .overlay {
                    if isHoveringToStop {
                        MewNotch.CountdownColors.urgent.opacity(0.16)
                    }
                }
                .mask {
                    NotchShape(
                        topRadius: notchViewModel.cornerRadius.top,
                        bottomRadius: notchViewModel.cornerRadius.bottom
                    )
                }
                // ── 响铃时，整个刘海就是「停止」按钮 ──
                //
                // 为什么是刘海而不是菜单栏菜单：声音响起时用户的视线本就在
                // 刘海（数字在那里变红），而刘海位于**屏幕顶边** —— 鼠标向上
                // 甩到底就能命中，Fitts's Law 意义上是个无限大的目标。
                // 相比「点图标 → 开菜单 → 点条目」的三步，这是一步。
                //
                // 顺带把一个既有缺陷变成了特性：刘海窗口本来就吞掉这片区域的
                // 点击（level 高于菜单栏），现在这些被吞的点击有了用处。
                .onTapGesture {
                    if alertPlayer.isAlerting {
                        CandleAlertPlayer.shared.dismiss()
                    }
                }
                // 只在响铃时给 hover 反馈。常态下鼠标无意划过刘海不该引起
                // 任何视觉变化 —— 但正在找「怎么关掉」的用户需要这个反馈。
                .onHover { hovering in
                    guard alertPlayer.isAlerting else {
                        if isHoveringToStop { isHoveringToStop = false }
                        return
                    }
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHoveringToStop = hovering
                    }
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help(alertPlayer.isAlerting ? "Click to stop the alert" : "")

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
