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

    /// 红色快讯弹幅。变化频率是「每条红色新闻一次」的量级，
    /// 直接订阅不构成重绘负担（对比：engine 每秒 tick 就不能订）。
    @ObservedObject var flashCenter = NewsFlashCenter.shared

    @StateObject var notchViewModel: NotchViewModel

    /// 响铃时鼠标是否悬停在刘海上。只在响铃时有意义 ——
    /// 此时的悬停反馈是暖光提亮，回答「点这里能停」。
    @State private var isHoveringToStop = false

    /// 鼠标此刻是否在刘海形体上。**即时置位，无延迟** ——
    /// 驱动轻微放大的悬停反馈：「刘海活着，点一下有东西」。
    @State private var isHoveringNotch = false

    /// 仪表盘是否展开。**点击展开、再点收起** —— 对称的开关语义；
    /// 响铃开始时强制收起。悬停只放大提示，绝不自动展开，
    /// 鼠标移开也不自动收起：看盘时要边看图边瞟日历，面板不能
    /// 因为鼠标回图表就消失。
    @State private var isExpanded = false

    /// 手型光标是否已入栈。push/pop 必须严格配对 ——
    /// 之前「点击停铃后手型残留」就是回调路径里漏了一次 pop。
    @State private var cursorPushed = false

    /// 鼠标是否正按在折叠态刘海上。驱动「按下蓄力」的微缩：
    /// duang 的前半句是「被压下去」，释放的弹开才有物理来历。
    /// 只在折叠态有意义 —— 展开态的面板是内容区，按压反馈
    /// 属于面板内各自的按钮。
    @State private var isPressingNotch = false

    /// 展开期间挂载的全局鼠标监听。全局 monitor 只报告发往**其他应用**
    /// 的点击 —— 正是「面板外」的精确定义（面板内的点击走本窗口的
    /// onTapGesture，不经过它）。挂/摘统一放在 isExpanded 的 onChange，
    /// 任何展开/收起路径都不会漏。
    @State private var outsideClickMonitor: Any?

    /// 悬停/点击行为的诊断通道。hover 是纯事件驱动、又依赖系统投递，
    /// 出问题时没有日志就只能瞎猜 —— debug 级别，默认零成本。
    private static let logger = Logger(subsystem: "io.github.1of1adam.JuneMew", category: "hover")

    /// 系统「减弱动态效果」。刘海是常驻 UI，运动敏感用户没有别的退路 ——
    /// 开启时所有形变/位移动画退化为纯透明度渐变。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - 动效参数

    /// 展开：一次真正的弹簧。展开是用户主动点击的时刻，值得「duang」
    /// 一下的生命力。
    ///
    /// 参数是按弹簧物理选的，不是试出来的手感玄学：
    /// 欠阻尼弹簧的过冲幅度 ≈ exp(-πζ/√(1-ζ²))，对 ~320pt 的展开行程 ——
    ///
    ///   ζ 0.82 → 过冲 1%（≈4pt）   旧值，读不出弹，只是「停得软」
    ///   ζ 0.70 → 过冲 5%（≈15pt）  优雅但含蓄
    ///   ζ 0.65 → 过冲 7%（≈22pt）  一次清晰的 duang + 一次不可见的回摆 ← 采用
    ///   ζ 0.55 → 过冲 12%（≈38pt） 晃两下以上，信息面板开始显得不稳重
    ///
    /// response 同步放宽到 0.45 —— 弹簧需要时间展示弹性，0.38 太快，
    /// 过冲被压缩在几帧里根本看不清。内容转场（panelReveal）与圆角、
    /// 阴影都在同一事务里，会跟着形体一起过冲再落回，浑然一体。
    private var expandAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.45, dampingFraction: 0.65)
    }

    /// 收起：干脆利落，不弹。收起是「我不要了」，还回弹一下等于纠缠。
    private var collapseAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.28, dampingFraction: 0.95)
    }

    /// 悬停放大：即时反馈要快，比展开动画明显更短。只用于**进入**悬停。
    private var hoverAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.26, dampingFraction: 0.78)
    }

    /// 悬停退出：柔和落回，不弹。移开鼠标是「注意力已经走了」，
    /// 刘海在余光里还弹一下是多余的动 —— 进快出慢是 Apple 系
    /// hover 反馈的通则。
    private var hoverExitAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .easeOut(duration: 0.32)
    }

    /// 按下蓄力：压缩要即时（按下的力是瞬时的），弹开交给 expandAnimation。
    private var pressAnimation: Animation {
        .easeOut(duration: 0.12)
    }

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
                    //
                    // 展开时中间的刘海占位换成弹性空间（保底仍盖住物理刘海），
                    // 图标和数字被推到岛的左右边缘 —— 顶排跟着岛一起向两边
                    // 展开，而不是继续挤在刘海两侧。身份切换的占位是纯透明
                    // 黑块，spring 事务里只看得到左右内容平滑滑开。
                    HStack(
                        spacing: 0
                    ) {
                        CountdownView(
                            notchViewModel: notchViewModel,
                            variant: .left,
                            role: countdownDefaults.position == .left ? .digits : .icon
                        )

                        if isExpanded || flashShowing {
                            Spacer(minLength: 0)
                                .frame(
                                    minWidth: notchViewModel.notchSize.width,
                                    minHeight: notchViewModel.notchSize.height
                                )
                        } else {
                            OnlyNotchView(
                                notchSize: notchViewModel.notchSize
                            )
                        }

                        CountdownView(
                            notchViewModel: notchViewModel,
                            variant: .right,
                            role: countdownDefaults.position == .right ? .digits : .icon
                        )
                    }
                    .padding(.horizontal, (isExpanded || flashShowing) ? 12 : 0)
                    // 展开时顶排必须钉住面板总宽（内容 + 左右 padding）——
                    // 中间是弹性 Spacer，而这棵子树挂在被提议全屏宽度的
                    // 容器里，不钉宽 Spacer 会把整个形体撑成全屏横幅。
                    // 弹幅态同理钉住弹幅宽：倒计时被推到岛两角，
                    // 整个形体读成一座一体变形的小岛。
                    .frame(width: topRowWidth)

                    // 点击展开的仪表盘。放在同一个 VStack 里，让黑色形体
                    // 「向下生长」而不是弹出第二个窗口 —— MewPanel 本来就
                    // 覆盖整块屏幕，这里只是画得更多。
                    if isExpanded {
                        NotchDashboardView(
                            notchViewModel: notchViewModel,
                            isExpanded: $isExpanded
                        )
                        // 内容随形体一起落位 —— 面板和黑色形体要读成
                        // 「一体成形」，而不是黑块先到、字再贴上去。
                        .transition(.panelReveal(reduceMotion: reduceMotion))
                    } else if let flash = flashCenter.current {
                        // 红色快讯弹幅：与面板互斥（展开优先），同一套
                        // panelReveal 揭示 —— 通知也是从刘海里长出来的。
                        NewsFlashBannerView(flash: flash)
                            .transition(.panelReveal(reduceMotion: reduceMotion))
                    }
                }
                // ── 渲染层结构（性能关键，动之前先读懂）──
                //
                // 旧结构是 glassEffect + background(黑矩形) + mask(NotchShape)
                // + 整树 .shadow，正是展开卡顿的主因：.shadow 的模糊源是
                // 「整棵内容树」的光栅化，动画期间树每帧都在变，等于每帧对
                // 整个仪表盘做一次全量高斯模糊；mask 再叠一层全树离屏合成。
                //
                // 新结构把所有贵的效果钉在背景形状层：阴影/玻璃/暖光的
                // 渲染源都只是一块纯色 NotchShape，与内容树彻底解耦 ——
                // 内容再复杂、动画再久，每帧要重新模糊的都只是一个单色轮廓。
                //
                // clipShape 是「长出来」质感的来源，删不得：转场中的视图
                // **不参与布局** —— 展开时面板内容一步就位在最终位置，黑色
                // 形体还在后面长，没有裁剪的话内容会浮在形体边界外整片淡入；
                // 收起时同理会露在收缩中的形体下方。裁掉之后，内容才是被
                // 形体边缘像卷帘一样渐次揭示/吞没的 —— 这正是灵动岛。
                // 用 clipShape 而不是旧版的 mask：几何裁剪，无模糊、
                // 无 alpha 中间纹理，性能与 mask 不是一个量级。
                .clipShape(
                    NotchShape(
                        topRadius: currentTopRadius,
                        bottomRadius: currentBottomRadius
                    )
                )
                .background {
                    notchBackground
                        // 展开时面板悬在别人的窗口内容上方，需要一层影来分离；
                        // 折叠时必须无影 —— 刘海黑块要和菜单栏融为一体，
                        // 有影就露馅。悬停放大的瞬间给一层浅影，
                        // 让「浮起来一点」在余光里成立。
                        .shadow(
                            color: .black.opacity(shadowOpacity),
                            radius: isExpanded ? 14 : (flashShowing ? 11 : 6),
                            y: isExpanded ? 5 : (flashShowing ? 4 : 2)
                        )
                }
                // 响铃且悬停时，黑色形体透出一层暖光 —— 明确回答「这里能点吗」。
                .overlay {
                    if isHoveringToStop {
                        NotchShape(
                            topRadius: currentTopRadius,
                            bottomRadius: currentBottomRadius
                        )
                        .fill(MewNotch.CountdownColors.urgent.opacity(0.16))
                    }
                }
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
                        withAnimation(collapseAnimation) {
                            isExpanded = false
                        }
                    } else if canExpandNow() {
                        Self.logger.debug("expanding (tap)")
                        withAnimation(expandAnimation) {
                            isExpanded = true
                        }
                    }
                }
                // 按下蓄力的观察通道。simultaneousGesture 与 onTapGesture、
                // 面板内子按钮并行识别，谁的语义都不抢 —— 这里只读
                // 「按没按着」。minimumDistance 0 让 mouseDown 即刻触发。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressingNotch, !isExpanded else { return }
                            withAnimation(pressAnimation) {
                                isPressingNotch = true
                            }
                        }
                        .onEnded { _ in
                            // 释放：若接着展开，scale 由 expandAnimation
                            // 事务接管，从压缩态起跳 —— 蓄力得到释放。
                            withAnimation(hoverAnimation) {
                                isPressingNotch = false
                            }
                        }
                )
                .onHover { hovering in
                    Self.logger.debug(
                        "hover=\(hovering) alerting=\(alertPlayer.isAlerting) expanded=\(isExpanded)"
                    )

                    // 进快带弹（有东西迎接你），出柔无弹（安静退场）。
                    withAnimation(hovering ? hoverAnimation : hoverExitAnimation) {
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

                    // 刻意不做「鼠标移开即收起」：看盘时要边看图边瞟日历，
                    // 面板不能因为鼠标回图表就消失。收起的途径 —— 再点一次
                    // 刘海（toggle）、响铃开始、设置里关掉仪表盘。
                }
                .help(alertPlayer.isAlerting ? "点击停止响铃" : "")

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
        // 点击面板外的任何地方收起 —— 和系统菜单、弹出框同一条肌肉记忆。
        .onChange(of: isExpanded) { _, expanded in
            // 快讯弹幅让位/复位。展开屏上弹幅分支已被面板替换（同一
            // spring 事务），center 里的 collapse 事务服务其余屏幕。
            flashCenter.setPanelExpanded(expanded)

            if expanded {
                guard outsideClickMonitor == nil else { return }
                outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown]
                ) { _ in
                    Task { @MainActor in
                        guard isExpanded else { return }
                        Self.logger.debug("collapsing (clicked outside)")
                        withAnimation(collapseAnimation) {
                            isExpanded = false
                        }
                    }
                }
            } else if let monitor = outsideClickMonitor {
                NSEvent.removeMonitor(monitor)
                outsideClickMonitor = nil
            }
        }
        // 响铃开始的瞬间强制收起：刘海必须立刻回到「一整块停止按钮」的
        // 单一语义，不能一半是仪表盘、一半是警报。
        .onChange(of: alertPlayer.isAlerting) { _, alerting in
            if alerting {
                withAnimation(collapseAnimation) {
                    isExpanded = false
                }
            }
        }
        // 在设置里关掉仪表盘时，已展开的面板要立即退场，
        // 而不是等下一次鼠标移出。
        .onChange(of: countdownDefaults.dashboardEnabled) { _, enabled in
            if !enabled {
                withAnimation(collapseAnimation) {
                    isExpanded = false
                }
            }
        }
    }

    // MARK: - 背景形状层

    /// 黑色形体（或液态玻璃）。独立成层是性能设计：阴影、暖光、玻璃的
    /// 渲染源都是这个纯形状，内容树不参与任何离屏渲染 —— 这一点是
    /// 展开/收起动画流畅的前提，别把效果搬回内容树上。
    @ViewBuilder
    private var notchBackground: some View {
        let shape = NotchShape(
            topRadius: currentTopRadius,
            bottomRadius: currentBottomRadius
        )
        if notchDefaults.applyGlassEffect {
            Color.clear
                .glassEffect(when: true, in: shape)
        } else {
            shape.fill(Color.black)
        }
    }

    // MARK: - 形体几何

    /// 红色快讯弹幅此刻是否可见。展开态优先 —— 面板里本来就有快讯区，
    /// body 的分支顺序与这里的定义共同保证两个身份绝不同屏。
    private var flashShowing: Bool {
        flashCenter.current != nil && !isExpanded
    }

    /// 顶排钉宽：展开 > 弹幅 > 折叠（自适应）。
    private var topRowWidth: CGFloat? {
        if isExpanded { return NotchDashboardView.contentWidth + 32 }
        if flashShowing { return NewsFlashBannerView.islandWidth }
        return nil
    }

    /// 展开时上下圆角一起放大：13pt 的折叠圆角贴在 160pt 高的面板上
    /// 看起来近乎直角，是「横幅」而不是「岛」。24pt 是灵动岛的量级。
    /// 圆角随 isExpanded 在同一个 spring 事务里插值（NotchShape 的
    /// animatableData 是上下圆角的 AnimatablePair）。
    /// 弹幅态取中间档：比折叠大一号（是岛不是横幅），又比面板小一号
    /// （通知的分量不该压过面板）。
    private var currentTopRadius: CGFloat {
        if isExpanded { return 14 }
        if flashShowing { return 10 }
        return notchViewModel.cornerRadius.top
    }

    private var currentBottomRadius: CGFloat {
        if isExpanded { return 24 }
        if flashShowing { return 18 }
        return notchViewModel.cornerRadius.bottom
    }

    /// 悬停时形体放大 4.5%；按下压回 0.98 —— 比静止还小一点，
    /// 释放时弹开的行程才清晰。展开后两者都不再生效 ——
    /// 岛已经在最前台了，叠加缩放会让面板文字轻微发虚。
    /// 弹幅态同理禁用：缩放会让标题文字发虚，且弹幅有自己的悬停反馈。
    private var hoverScale: CGFloat {
        guard !isExpanded, !flashShowing else { return 1.0 }
        if isPressingNotch { return 0.98 }
        return isHoveringNotch ? 1.045 : 1.0
    }

    private var shadowOpacity: CGFloat {
        if isExpanded { return 0.55 }
        if flashShowing { return 0.5 }
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

/// 「随形体落位」：透明度 + 从顶部轻微缩放，绑在同一个进度上随形体的
/// spring 一起走 —— 内容不是贴在黑块上的贴纸，而是和黑块一起从刘海里
/// 长出来的。
///
/// 这里刻意没有 blur：动画中的 blur 无法缓存，每帧都要对整个面板做一次
/// 全量高斯模糊，是旧版展开掉帧的主要来源之一。opacity / scale / offset
/// 都是纯合成属性，GPU 直接吃 —— 灵动岛真机的内容进出场同样只用这些。
private struct PanelRevealModifier: ViewModifier {

    /// 0 = 隐藏形态，1 = 就位。
    let progress: CGFloat

    /// 隐藏形态缩到 1 - depth。
    let depth: CGFloat

    /// 隐藏形态向刘海方向抬起的距离（收起的「吸入感」来源）。
    /// 抬出去的部分被外层 clipShape 吞掉，不会露在形体外。
    let lift: CGFloat

    /// 减弱动态效果时只保留透明度渐变。
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(
                reduceMotion ? 1 : 1 - depth * (1 - progress),
                anchor: .top
            )
            .offset(y: reduceMotion ? 0 : -lift * (1 - progress))
    }
}

extension AnyTransition {
    /// 进出不对称：展开时内容在原位从 0.96 长到位（形体边缘负责揭示，
    /// 内容自己不必大动）；收起时缩得更深并向上抬 7pt —— 读成
    /// 「被刘海吸回去」，而不是原地淡掉。
    static func panelReveal(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: PanelRevealModifier(
                    progress: 0, depth: 0.04, lift: 0, reduceMotion: reduceMotion
                ),
                identity: PanelRevealModifier(
                    progress: 1, depth: 0.04, lift: 0, reduceMotion: reduceMotion
                )
            ),
            removal: .modifier(
                active: PanelRevealModifier(
                    progress: 0, depth: 0.07, lift: 7, reduceMotion: reduceMotion
                ),
                identity: PanelRevealModifier(
                    progress: 1, depth: 0.07, lift: 7, reduceMotion: reduceMotion
                )
            )
        )
    }
}
