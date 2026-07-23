//
//  NotchView.swift
//  MewNotch
//
//  Created by Monu Kumar on 25/02/25.
//

import SwiftUI
import OSLog

struct NotchView: View {

    @ObservedObject var notchDefaults = NotchDefaults.shared
    @ObservedObject var countdownDefaults = CountdownDefaults.shared
    @ObservedObject var alertPlayer = CandleAlertPlayer.shared

    @StateObject var notchViewModel: NotchViewModel

    /// 响铃时鼠标是否悬停在刘海上。只在响铃时有意义 ——
    /// 此时的悬停反馈是暖光提亮，回答「点这里能停」。
    @State private var isHoveringToStop = false

    /// 鼠标此刻是否在刘海形体上。**即时置位，无延迟** ——
    /// 驱动轻微放大的悬停反馈：「刘海活着，点一下有东西」。
    @State private var isHoveringNotch = false

    /// 仪表盘是否展开。**点击展开**、再点或移开鼠标收起；
    /// 响铃开始时强制收起。悬停只放大提示，绝不自动展开 ——
    /// 鼠标去够菜单栏是高频动作，路过不该弹出任何东西。
    @State private var isExpanded = false

    /// 手型光标是否已入栈。push/pop 必须严格配对 ——
    /// 之前「点击停铃后手型残留」就是回调路径里漏了一次 pop。
    @State private var cursorPushed = false

    /// 悬停/点击行为的诊断通道。hover 是纯事件驱动、又依赖系统投递，
    /// 出问题时没有日志就只能瞎猜 —— debug 级别，默认零成本。
    private static let logger = Logger(subsystem: "com.monuk7735.mew.notch", category: "hover")

    // MARK: - 动效参数

    /// 展开：带一点弹性的生长。展开是用户主动点击的时刻，
    /// 允许一点生命力；damping 0.82 在「有回弹」和「不晃」之间。
    private static let expandAnimation: Animation = .spring(response: 0.38, dampingFraction: 0.82)

    /// 收起：干脆利落，不弹。收起是「我不要了」，还回弹一下等于纠缠。
    private static let collapseAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.95)

    /// 悬停放大：即时反馈要快，比展开动画明显更短。
    private static let hoverAnimation: Animation = .spring(response: 0.26, dampingFraction: 0.78)

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

                VStack(spacing: 0) {
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

                    // 点击展开的仪表盘。放在同一个 VStack 里，让黑色形体
                    // 「向下生长」而不是弹出第二个窗口 —— MewPanel 本来就
                    // 覆盖整块屏幕，这里只是画得更多。
                    if isExpanded {
                        NotchDashboardView(
                            notchViewModel: notchViewModel,
                            isExpanded: $isExpanded
                        )
                        // 内容从模糊中聚焦、随形体一起落位 —— 面板和黑色
                        // 形体要读成「一体成形」，而不是黑块先到、字再贴上去。
                        .transition(.panelReveal)
                    }
                }
                .glassEffect(when: notchDefaults.applyGlassEffect, in: NotchShape(
                    topRadius: currentTopRadius,
                    bottomRadius: currentBottomRadius
                ))
                .background {
                    if !notchDefaults.applyGlassEffect {
                        Color.black
                    }
                }
                // 响铃且悬停时，黑色形体透出一层暖光 —— 明确回答「这里能点吗」。
                .overlay {
                    if isHoveringToStop {
                        MewNotch.CountdownColors.urgent.opacity(0.16)
                    }
                }
                .mask {
                    NotchShape(
                        topRadius: currentTopRadius,
                        bottomRadius: currentBottomRadius
                    )
                }
                // 展开时面板悬在别人的窗口内容上方，需要一层影来分离；
                // 折叠时必须无影 —— 刘海黑块要和菜单栏融为一体，有影就露馅。
                // 悬停放大的瞬间给一层浅影，让「浮起来一点」在余光里成立。
                .shadow(
                    color: .black.opacity(shadowOpacity),
                    radius: isExpanded ? 14 : 6,
                    y: isExpanded ? 5 : 2
                )
                // 悬停反馈：整个形体（含影）从顶边轻微放大。anchor 必须是
                // .top —— 刘海贴着屏幕顶边，从中心缩放会在顶上露出一条缝。
                .scaleEffect(hoverScale, anchor: .top)
                // ── 点击语义按状态分派 ──
                //
                // 响铃时：整个刘海就是「停止」按钮。声音响起时用户的视线本就
                // 在刘海（数字在那里变红），而刘海位于**屏幕顶边** —— 鼠标向上
                // 甩到底就能命中，Fitts's Law 意义上是个无限大的目标。
                //
                // 平时：点击展开/收起仪表盘。面板内的按钮不受影响 ——
                // SwiftUI 里子视图手势优先于父级。
                .onTapGesture {
                    if alertPlayer.isAlerting {
                        CandleAlertPlayer.shared.dismiss()
                        // 点击后鼠标还停在刘海里，onHover 不会再回调 ——
                        // 响铃专属的提亮要在这里主动撤掉。手型不撤：此刻
                        // 刘海仍是可点击的（下一次点击展开仪表盘）。
                        isHoveringToStop = false
                        return
                    }

                    if isExpanded {
                        Self.logger.debug("collapsing (tap)")
                        withAnimation(Self.collapseAnimation) {
                            isExpanded = false
                        }
                    } else if canExpandNow() {
                        Self.logger.debug("expanding (tap)")
                        withAnimation(Self.expandAnimation) {
                            isExpanded = true
                        }
                    }
                }
                .onHover { hovering in
                    Self.logger.debug(
                        "hover=\(hovering) alerting=\(alertPlayer.isAlerting) expanded=\(isExpanded)"
                    )

                    withAnimation(Self.hoverAnimation) {
                        isHoveringNotch = hovering
                    }

                    // 响铃优先：此刻刘海只有一个身份 —— 停止按钮。
                    guard !alertPlayer.isAlerting else {
                        withAnimation(.easeOut(duration: 0.12)) {
                            isHoveringToStop = hovering
                        }
                        setPointer(hovering)
                        return
                    }
                    if isHoveringToStop { isHoveringToStop = false }

                    // 可点击（能展开或能收起）时给手型，明示「这里点得动」。
                    setPointer(hovering && (isExpanded || canExpandNow()))

                    // 鼠标离开整个形体（含面板）即收起 —— 面板是瞬态的
                    // 信息面板，不是要人记着关的窗口。
                    if !hovering, isExpanded {
                        Self.logger.debug("collapsing (pointer left)")
                        withAnimation(Self.collapseAnimation) {
                            isExpanded = false
                        }
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
        // 响铃开始的瞬间强制收起：刘海必须立刻回到「一整块停止按钮」的
        // 单一语义，不能一半是仪表盘、一半是警报。
        .onChange(of: alertPlayer.isAlerting) { _, alerting in
            if alerting {
                withAnimation(Self.collapseAnimation) {
                    isExpanded = false
                }
            }
        }
        // 在设置里关掉仪表盘时，已展开的面板要立即退场，
        // 而不是等下一次鼠标移出。
        .onChange(of: countdownDefaults.dashboardEnabled) { _, enabled in
            if !enabled {
                withAnimation(Self.collapseAnimation) {
                    isExpanded = false
                }
            }
        }
    }

    // MARK: - 形体几何

    /// 展开时上下圆角一起放大：13pt 的折叠圆角贴在 160pt 高的面板上
    /// 看起来近乎直角，是「横幅」而不是「岛」。24pt 是灵动岛的量级。
    /// 圆角随 isExpanded 在同一个 spring 事务里插值（NotchShape 的
    /// animatableData 是上下圆角的 AnimatablePair）。
    private var currentTopRadius: CGFloat {
        isExpanded ? 14 : notchViewModel.cornerRadius.top
    }

    private var currentBottomRadius: CGFloat {
        isExpanded ? 24 : notchViewModel.cornerRadius.bottom
    }

    /// 悬停时形体放大 4.5%。展开后不再放大 —— 岛已经在最前台了，
    /// 叠加缩放会让面板文字轻微发虚。
    private var hoverScale: CGFloat {
        guard !isExpanded else { return 1.0 }
        return isHoveringNotch ? 1.045 : 1.0
    }

    private var shadowOpacity: CGFloat {
        if isExpanded { return 0.55 }
        if isHoveringNotch { return 0.35 }
        return 0
    }

    // MARK: - 光标

    /// 手型光标的唯一出入口。所有路径都经这里，push/pop 才配得平 ——
    /// 分散在各回调里手写，迟早漏一次 pop 留下永久手型。
    private func setPointer(_ active: Bool) {
        guard active != cursorPushed else { return }
        cursorPushed = active
        if active {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// 此刻点击是否应该展开。
    ///
    /// 刻意写成函数、只在事件回调里调用 —— NotchView 不能 @ObservedObject
    /// 订阅 engine，否则 presentation 每秒变化会把整个刘海视图树拖着每秒重绘。
    private func canExpandNow() -> Bool {
        guard countdownDefaults.dashboardEnabled else {
            Self.logger.debug("expand blocked: dashboard disabled in settings")
            return false
        }
        guard notchViewModel.notchSize.height > 1 else {
            Self.logger.debug("expand blocked: notch size degenerate")
            return false
        }
        // 功能关闭时刘海只是一块安静的黑色遮罩，点击不该有任何反应。
        if case .dormant(.featureDisabled) = CountdownEngine.shared.presentation {
            Self.logger.debug("expand blocked: countdown disabled")
            return false
        }
        return true
    }
}

// MARK: - 面板内容的展开转场

/// 「从模糊中聚焦」：blur + 透明度 + 从顶部轻微缩放，三者绑在同一个
/// 进度上随形体的 spring 一起走。这是灵动岛的质感来源 —— 内容不是
/// 贴在黑块上的贴纸，而是和黑块一起从刘海里长出来的。
private struct PanelRevealModifier: ViewModifier {

    /// 0 = 隐藏形态，1 = 就位。
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 6)
            .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
    }
}

extension AnyTransition {
    static let panelReveal = AnyTransition.modifier(
        active: PanelRevealModifier(progress: 0),
        identity: PanelRevealModifier(progress: 1)
    )
}
