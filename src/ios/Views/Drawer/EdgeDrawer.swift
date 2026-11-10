//
//  EdgeDrawer.swift
//  全能AI - 左边缘抽屉容器
//
//  改造点（R25 / R28）：原版 iPhone 是 NavigationStack 的「列表页 → push 对话」，
//  列表和对话是两个全屏页面，来回要 push/pop。改造后：
//
//      对话是主界面，列表变成从左边拉出来的抽屉。
//
//  为什么不是照抄某个现成实现：抽屉最容易踩的坑是手势冲突。这个文件把
//  三类手势的优先级写死了，谁抢谁有明确顺序：
//
//      1. 抽屉开着时 —— 只有「拖回」和「点遮罩关闭」有效，内容区不吃手势
//      2. 抽屉关着时 —— 只有从屏幕左边缘 24pt 内起手才算拉抽屉
//      3. 任何情况下 —— 水平位移必须明显大于垂直位移，否则让给滚动
//
//  第 3 条是关键。少了它，在列表里上下滚动会被误判成拉抽屉，或者反过来
//  想拉抽屉时列表跟着滚。
//
//  另一个刻意设计：手势只跟手，不跟动画。拖到一半松手才决定吸附方向
//  （超过 40% 就往完展开 / 收回，否则看速度方向）。这样不会有「拖一下
//  就整块跳过去」的割裂感。
//

import SwiftUI

// MARK: - 抽屉状态

/// 抽屉的开合状态。单独抽成 ObservableObject 而不是往 ContentView 里塞
/// 一个 @State，原因是：
///   - 手势回调是给底层 UIView 的（UIPanGestureRecognizer），闭包里不能直接
///     写 SwiftUI 的 @State binding；
///   - 后面长按菜单、搜索框这些子视图都要读同一个状态，用 EnvironmentObject
///     比一层层传 binding 干净。
@MainActor
final class DrawerState: ObservableObject {

    /// 0 = 完全收起，1 = 完全展开。手势过程中是连续值。
    @Published var progress: CGFloat = 0

    /// 是否正在被手指拖动。用来在手势期间关掉动画，避免和手势打架。
    @Published var dragging = false

    /// 抽屉宽度占屏幕宽度的比例上限。
    /// 318pt 是 R28 定下来的：320pt 的屏幕上要留一点右边让用户看到还有内容，
    /// 402pt 的 Pro Max 上 318 刚好能放下「标题 + 摘要 + 时间」三行不折。
    static let widthFraction: CGFloat = 0.78
    static let widthMax: CGFloat = 318

    /// 从屏幕左边缘起手多少点之内才算「拉抽屉」。
    /// 少了这个阈值，普通左滑返回会变成拉开抽屉。
    static let edgeSlop: CGFloat = 24

    /// 吸附判定：拖过这个比例就往「展开」吸，否则往「收起」吸。
    static let settleThreshold: CGFloat = 0.4

    var isOpen: Bool { progress > 0.5 }

    func open(animated: Bool = true) {
        if animated {
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                progress = 1
            }
        } else {
            progress = 1
        }
    }

    func close(animated: Bool = true) {
        if animated {
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                progress = 0
            }
        } else {
            progress = 0
        }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    /// 手势结束时的吸附。`predictedEndProgress` 是系统按当前速度外推的
    /// 落点 —— 用它而不是用当前位移，快速轻扫也能正确展开。
    func settle(to target: CGFloat) {
        dragging = false
        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.88)) {
            progress = target >= Self.settleThreshold ? 1 : 0
        }
    }
}

// MARK: - 容器

/// 把「内容」和「抽屉」叠在一起，并接管左边缘手势。
///
/// 用法：
/// ```swift
/// DrawerContainer(drawer: { SessionDrawer(...) }) {
///     chatContent
/// }
/// ```
struct DrawerContainer<Drawer: View, Content: View>: View {

    @StateObject private var state = DrawerState()

    /// 模板模式（R37 起默认）：抽屉层不是 SwiftUI 视图，而是
    /// `TemplateUIWebView` 全屏铺着，抽屉本体由设计稿自己的 CSS 画。
    /// 这样抽屉的每个像素、每段动画都来自设计稿，不存在复刻偏差。
    @StateObject private var template = TemplateUIHost()
    private let useTemplate: Bool

    /// 设计稿里抽屉的宽度（`--drawer-w: 318px`）。
    /// 用固定值而不是比例：418KB 的模板里那些行高、内边距都是按 318
    /// 排的，跟着屏幕宽度变会让文字折行位置和设计稿不一致。
    /// 320pt 的老机型上会自动收窄，见 init。
    private let drawerWidth: CGFloat

    /// 整屏宽度。抽屉态右侧要留一条「点空白关闭」的热区，宽度靠它算。
    private let totalWidth: CGFloat

    private let drawer: (DrawerState) -> Drawer
    private let content: () -> Content

    /// 模板句柄准备好时回吐给外层。
    ///
    /// 为什么需要：数据（会话列表、产物）住在外层的 ContentView 里，
    /// 而 host 是这里的 @StateObject。加 environmentObject 只能往下传，
    /// 闭包拿不到；改用「回调交出去、外层存一份」最省事，也不会
    /// 因为多一层 binding 让整棵树每帧重算。
    private let onTemplateReady: ((TemplateUIHost) -> Void)?

    init(width: CGFloat, useTemplate: Bool = false,
         onTemplateReady: ((TemplateUIHost) -> Void)? = nil,
         @ViewBuilder drawer: @escaping (DrawerState) -> Drawer,
         @ViewBuilder content: @escaping () -> Content) {
        self.totalWidth = width
        self.useTemplate = useTemplate
        self.onTemplateReady = onTemplateReady

        // 模板固定 318。只有屏幕本身放不下（< 390）时才按比例收，
        // 这时抽屉会略窄于设计稿 —— 比让它溢出屏幕好。
        let fixed: CGFloat = DrawerState.widthMax
        self.drawerWidth = width >= fixed + 72 ? fixed : min(width * 0.82, fixed)

        self.drawer = drawer
        self.content = content
    }

    /// 模板模式下内容区不位移。
    ///
    /// 设计稿里抽屉是「从左边滑出来盖在内容上」，不是「内容被推开」，
    /// 而且它自带的遮罩已经在 App 模式里关掉了（改用原生那层）。
    /// 这里再 offset 一次，抽屉右下角的齿轮就会跟着飘 —— 设计稿的
    /// 定位是 `right:16px` 相对抽屉，跟屏幕无关。
    private var contentShift: CGFloat { useTemplate ? 0 : drawerWidth * state.progress }

    var body: some View {
        ZStack(alignment: .leading) {
            // ── 内容层 ──
            content()
                .scaleEffect(1 - 0.06 * state.progress * (useTemplate ? 0 : 1),
                             anchor: .trailing)
                .offset(x: contentShift)
                .overlay(alignment: .leading) {
                    // 遮罩：抽屉拉开时挡内容区，同时承担「点空白关闭」。
                    // 模板模式下这层必须留着 —— 模板自己的 `.scrim` 已经
                    // 在 App 模式里隐藏了，它是唯一的一层。
                    if state.progress > 0.02 {
                        Color.black
                            .opacity(0.32 * Double(state.progress))
                            .contentShape(Rectangle())
                            .onTapGesture { state.close() }
                            .allowsHitTesting(true)
                    }
                }
                .disabled(state.isOpen)

            // ── 抽屉层 ──
            if useTemplate {
                TemplateUIWebView(host: template)
                    .allowsHitTesting(template.wantsInteraction || state.progress > 0.02)
                    // 跟手（R38）。
                    //
                    // 以前这里只把 progress 折成「开 / 关」两态再交给模板的
                    // CSS transition，于是手指刚动 10pt，抽屉就整块弹到终点，
                    // 中间没有位移 —— 用户的反馈就是「直接就出来，不好看」。
                    //
                    // 现在拖动期间逐帧把 progress 直接推给模板的 dragTo()，
                    // 抽屉停在手指当前位置；只有松手（dragging 变回 false）
                    // 才调用 openDrawer / closeDrawer，交给设计稿自己的
                    // cubic-bezier(.32,.72,0,1) 收尾。
                    //
                    // 每帧一次 evaluateJavaScript 的代价：这里只在手势期间
                    // 调用，一帧最多一次，且模板里只改一个 transform + 一个
                    // opacity，实测不会掉帧（真机待验）。
                    .onChange(of: state.progress) { p in
                        if state.dragging {
                            template.dragTo(p)
                        } else {
                            // 松手后（含代码里主动 open/close）走模板自己的动画。
                            if p > 0.5 {
                                template.openDrawer()
                            } else {
                                template.closeDrawer()
                            }
                        }
                    }
                    // 拖动结束的那一帧要把最终吸附结果告诉模板，
                    // 因为 onChange(of: progress) 在松手后可能不再触发
                    // （progress 已到 0 或 1，值没变）。
                    .onChange(of: state.dragging) { dragging in
                        if !dragging {
                            template.dragEnd(open: state.progress > 0.5)
                        }
                    }
                    // 反向同步：模板自己也会关抽屉。
                    //
                    // 典型场景就是点齿轮 —— 模板的 handler 是
                    // `closeDrawer(); enterSettings();`，它把 DOM 收起来了，
                    // 但原生这边的 `progress` 还停在 1，于是那层跟着进度走的
                    // 黑色遮罩会一直盖在设置页上面，整屏发暗。
                    //
                    // 只在「模板说关了、原生还开着」时补一刀，反过来不处理：
                    // 原生开着而模板没开，说明手势正在拉，这时候去关会把
                    // 跟手动画打断。
                    .onChange(of: template.drawerOpen) { open in
                        if !open, state.progress > 0.02, !template.pageOpen {
                            state.close()
                        }
                    }
                    // 抽屉态右侧那条热区：模板的 WebView 是全屏的，
                    // 不补这一层，点抽屉右边空白什么都不会发生 ——
                    // 而这是用户关抽屉最常用的手势。
                    .overlay(alignment: .trailing) {
                        if state.progress > 0.02, !template.pageOpen {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: max(0, totalWidth - drawerWidth))
                                .onTapGesture { state.close() }
                        }
                    }
            } else {
                drawer(state)
                    .frame(width: drawerWidth)
                    .offset(x: -drawerWidth * (1 - state.progress))
                    // 抽屉完全收起时不要参与命中测试，否则它的右边缘会
                    // 挡住内容区左侧 1pt，点击会莫名没反应。
                    .allowsHitTesting(state.progress > 0.02)
            }

            // ── 手势层 ──
            // 单独铺一层透明的 UIView 承载 UIPanGestureRecognizer。
            // 不用 SwiftUI 的 DragGesture 是因为它拿不到「起手点在不在屏幕
            // 左边缘」—— DragGesture 只给相对位移，而我们需要绝对坐标来判断
            // 是否从边缘起手。混用 UIKit 手势识别器是这里最省事的做法。
            //
            // [R32-整页点不动] 这一层必须**只占左边缘那一条**，不能铺满全屏。
            //
            // 之前是全屏 frame + allowsHitTesting(true)，靠
            // `PassthroughView.point(inside:)` 在远离左边缘处返回 false 来
            // 放行触摸。这在纯 UIKit 里成立（hitTest 会跳过返回 nil 的
            // subview 继续找兄弟），但这里不成立：ZStack 里的其它内容由
            // SwiftUI 画在 layer 上，不是能接住 hitTest 的兄弟 UIView。
            // 于是 nil 没有东西可回退，这一次触摸被直接丢弃。
            //
            // 症状：边缘右滑拉抽屉一切正常，但整页所有按钮都点不动。
            // 因为手势层自己是活的，所以看起来像「只有点击坏了」。
            //
            // R37 那次整批回退到 85e9dfd 时把这条 frame 一起退掉了，
            // build 38 于是又变成「进得去聊天界面，但哪里都点不了」。
            // 这里是第二次补回，不要再删。
            EdgePanOverlay(state: state, drawerWidth: drawerWidth)
                .frame(width: DrawerState.edgeSlop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .environmentObject(state)
        // 模板句柄给外层用（灌数据、接点击回调）。
        .environmentObject(template)
        .task {
            guard useTemplate else { return }
            onTemplateReady?(template)
        }
    }
}

// MARK: - 手势层

/// 透明的 UIKit 视图，只做一件事：识别左边缘右滑 / 抽屉内左滑。
private struct EdgePanOverlay: UIViewRepresentable {

    @ObservedObject var state: DrawerState
    let drawerWidth: CGFloat

    func makeUIView(context: Context) -> UIView {
        let v = PassthroughView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        // 初次创建时抽屉是收起的，边缘窄带宽度立刻生效。
        v.edgeSlop = DrawerState.edgeSlop
        v.activeWidth = 0

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        pan.delegate = context.coordinator
        // 不和内容区的滚动手势抢：真正要接管时由 delegate 决定。
        pan.cancelsTouchesInView = false
        v.addGestureRecognizer(pan)

        context.coordinator.pan = pan
        context.coordinator.host = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.width = drawerWidth
        context.coordinator.state = state

        // 这里**不要**去给 PassthroughView.activeWidth 赋值。
        //
        // 看着很自然的写法是：抽屉开着就 activeWidth = drawerWidth，
        // 让 point(inside:) 返回 true，用户就能从屏幕任意位置往左拖回去。
        // 结论是不能这么干：EdgePanOverlay 在 ZStack 最上层，
        // point(inside:) 一旦全返回 true，这层就把所有触摸吃掉了 ——
        // 遮罩的 onTapGesture 收不到、抽屉里的会话行/齿轮/按钮全点不动，
        // 抽屉彻底废掉。hitTest 返回自己之后触摸不会转给兄弟视图，
        // 这不是 cancelsTouchesInView = false 能解决的（那个只影响
        // 「手势识别成功后是否取消 touchesBegan」）。
        //
        // 现在的行为（activeWidth 恒 0）是：抽屉关着时左边缘 24pt 能拉开，
        // 拉开后点遮罩或点标题栏都能关，只是不能从中间往左拖回去。
        // 属于「缺一个手势入口」，不是「点不动」，可接受。
        //
        // 要补全那个手势，正确做法是把 UIPanGestureRecognizer 挂到
        // window 上（让这层 hitTest 永远返回 nil 保持完全穿透），
        // 靠 delegate 的 shouldBegin 决定是否接管。那是手势架构改动，
        // 必须在真机上验过遮罩点击、抽屉内滚动、表格滑动都不受影响才能上，
        // 不要在没有真机验证的情况下改这里。
        uiView.backgroundColor = .clear
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, width: drawerWidth)
    }

    /// 只有触摸落在「实际可交互区域」时才让 UIKit 认这个手势。
    ///
    /// `PassthroughView.hitTest` 返回 nil 让触摸穿透到下面的内容 ——
    /// 但手势识别器是加在这层上的，一旦穿透就不再收到触摸。
    /// 所以这里换了个思路：视图本身可命中，但只在自己「该管」的区域
    /// 返回自己，其余返回 nil。判断逻辑放在 `point(inside:)` 里。
    final class PassthroughView: UIView {
        var activeWidth: CGFloat = 0          // >0 表示抽屉开着，整片可接管
        var edgeSlop: CGFloat = DrawerState.edgeSlop

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            if activeWidth > 0 {
                // 抽屉开着：整片都可接管（用于拖回）
                return true
            }
            // 抽屉关着：只有左边缘一条窄带
            return point.x <= edgeSlop
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var state: DrawerState
        var width: CGFloat
        var pan: UIPanGestureRecognizer?
        weak var host: PassthroughView?

        private var startProgress: CGFloat = 0

        init(state: DrawerState, width: CGFloat) {
            self.state = state
            self.width = width
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let translation = g.translation(in: view).x
            let velocity = g.velocity(in: view).x

            switch g.state {
            case .began:
                startProgress = state.progress
                state.dragging = true

            case .changed:
                // 只有在抽屉「该跟手」的时候才更新进度。
                // 把 translation 归一化成 0…1 的进度增量。
                let delta = translation / max(width, 1)
                var p = startProgress + delta
                p = min(max(p, 0), 1)
                // 手势期间不能带动画，否则会有一帧延迟，看起来像拖不动。
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { state.progress = p }

            case .ended, .cancelled, .failed:
                // 吸附方向：先看速度（快速轻扫），再看位移比例。
                let projected = startProgress + (translation + velocity * 0.18) / max(width, 1)
                state.settle(to: min(max(projected, 0), 1))

            default:
                break
            }
        }

        // MARK: UIGestureRecognizerDelegate

        /// 让这个手势和内容区的手势并存，最终由 `shouldBegin` 决定谁生效。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // 只和自己的 pan 并存没意义；和滚动视图的手势要互斥，
            // 所以这里返回 false，靠 shouldBegin 提前决定。
            return false
        }

        /// 决定这次拖动到底算不算「拉抽屉」。这是整个手势体验的核心。
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return false }

            let v = pan.velocity(in: view)
            let location = pan.location(in: view)
            let isOpen = state.progress > 0.02

            // 1) 方向过滤：水平位移必须明显大于垂直。
            //    1.5 倍是试出来的：1.2 太松，列表里斜着划一下就误触；
            //    2.0 太紧，正常斜着拉会被吃掉。
            guard abs(v.x) > abs(v.y) * 1.5 else { return false }

            if isOpen {
                // 2a) 抽屉开着：只认「往左拖」（收回去）
                return v.x < 0
            } else {
                // 2b) 抽屉关着：必须往右拖，且起手点在左边窄带内
                guard v.x > 0 else { return false }
                return location.x <= DrawerState.edgeSlop
            }
        }
    }
}

// MARK: - 便捷入口

extension View {
    /// 给任意视图套上左边缘抽屉。
    ///
    /// - Parameters:
    ///   - isPresented: 外部控制开合（比如导航栏左上角那个按钮）
    ///   - drawer: 抽屉内容
    func edgeDrawer<D: View>(
        width: CGFloat,
        @ViewBuilder drawer: @escaping (DrawerState) -> D
    ) -> some View {
        DrawerContainer(width: width, drawer: drawer) { self }
    }
}
