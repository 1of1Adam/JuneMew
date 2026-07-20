//
//  NotchSlotView.swift
//  MewNotch
//

import SwiftUI

/// 刘海左右两侧的通用内容槽位。
///
/// 由原 `MinimalHUDView` 提升而来。与原版的唯一区别是宽度可由内容决定
/// （原版固定为正方形图标槽），以及只加水平内边距 ——
/// 原版的 `.padding(all)` 在固定 `frame(height:)` 面前只是个最小尺寸提示，
/// 对正方形图标无所谓，但对文本会和固定高度打架。
/// 槽位在刘海的哪一侧。
///
/// 提到泛型之外：写成 `NotchSlotView<Content>.Variant` 会强迫调用方在
/// 只想指定方位时也得先钉死一个 Content 类型。
enum NotchSlotVariant {
    case left
    case right
}

struct NotchSlotView<Content: View>: View {

    @ObservedObject var notchViewModel: NotchViewModel

    var variant: NotchSlotVariant

    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, notchViewModel.minimalHUDPadding)
            .frame(height: notchViewModel.notchSize.height)
            .transition(
                .move(
                    edge: variant == .left ? .trailing : .leading
                )
                .combined(
                    with: .opacity
                )
            )
            // ↓ 逐字保留自 MinimalHUDView。左右相消，净宽为 0，
            //   作用是把内容朝刘海方向平移 8pt —— 内容紧贴物理刘海边缘，
            //   黑色形体在内容外侧留出呼吸位。这才是 extraNotchPadSize = (16, 0)
            //   的真正用途，不是「左右各留 8」。不复用这段数学，倒计时会浮在
            //   刘海和菜单栏中间。
            .padding(
                .init(
                    top: 0,
                    leading: notchViewModel.extraNotchPadSize.width / 2 * (variant == .left ? 1 : -1),
                    bottom: 0,
                    trailing: notchViewModel.extraNotchPadSize.width / 2 * (variant == .left ? -1 : 1)
                )
            )
    }
}
