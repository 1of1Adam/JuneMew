//
//  NotchViewModel.swift
//  MewNotch
//
//  Created by Monu Kumar on 26/03/25.
//

import SwiftUI

class NotchViewModel: ObservableObject {

    var screen: NSScreen

    @Published var notchSize: CGSize = .zero

    /// 折叠态是唯一形态，圆角不再随展开切换。
    let cornerRadius: (
        top: CGFloat,
        bottom: CGFloat
    ) = (
        top: 8,
        bottom: 13
    )

    /// 槽位内容的水平内边距。
    var minimalHUDPadding: CGFloat = 0

    /// 折叠态刘海左右两侧的视觉留白，会被计入 `notchSize.width`。
    /// `NotchSlotView` 用它的一半做负 padding 平移，让内容紧贴物理刘海边缘、
    /// 黑色形体在内容外侧留呼吸位。**清零会让倒计时贴死刘海边缘。**
    let extraNotchPadSize: CGSize = .init(
        width: 16,
        height: 0
    )

    /// 菜单栏高度。`Match_Notch` 模式下黑块比菜单栏高，倒计时垂直居中会比
    /// 系统时钟低一截 —— 文字挨着文字时很明显，需要据此把基线顶回菜单栏光学中线。
    var menuBarHeight: CGFloat {
        screen.frame.maxY - screen.visibleFrame.maxY
    }

    init(
        screen: NSScreen
    ) {
        self.screen = screen

        self.refreshNotchSize()
    }

    func refreshNotchSize() {
        let shouldForce = NotchDefaults.shared.notchDisplayVisibility != .NotchedDisplayOnly

        var size = NotchUtils.shared.notchSize(
            screen: self.screen,
            force: shouldForce
        )

        size.width += extraNotchPadSize.width
        size.height += extraNotchPadSize.height

        // 与 CountdownEngine.visibilityAnimation 同参 —— 刘海尺寸变化
        // 无论从哪条路径触发，都该是同一种「顺滑收放」。
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            self.notchSize = size
            self.minimalHUDPadding = size.height * 0.2
        }
    }
}
