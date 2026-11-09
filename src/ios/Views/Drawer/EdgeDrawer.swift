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

    /// 抽屉宽度。由外部传入的几何宽度算出，避免在容器内部再套一层
    /// GeometryReader（那会让内容视图丢掉父级给的尺寸约束）。
    private let drawerWidth: CGFloat

    private let drawer: (DrawerState) -> Drawer
    private let content: () -> Content

    init(width: CGFloat,
         @ViewBuilder drawer: @escaping (DrawerState) -> Drawer,
         @ViewBuilder content: @escaping () -> Content) {
        self.drawerWidth = min(width * DrawerState.widthFraction, DrawerState.widthMax)
        self.drawer = drawer
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // ── 内容层 ──
            // 抽屉拉开时整块右移并轻微缩小，这是 iOS 上「层级被推开」
            // 的惯用表达。缩到 0.94 就够，再小会让人以为界面出错了。
            content()
                .scaleEffect(1 - 0.06 * state.progress, anchor: .trailing)
                .offset(x: drawerWidth * state.progress)
                .overlay(alignment: .leading) {
                    // 遮罩只在 drawers 拉开时挡内容区。它同时承担
                    // 「点空白关闭」，这是抽屉的必备出口 —— 只靠边缘
                    // 手势关闭，一只手拿手机时很难操作。
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
            drawer(state)
                .frame(width: drawerWidth)
                .offset(x: -drawerWidth * (1 - state.progress))
                // 抽屉完全收起时不要参与命中测试，否则它的右边缘会
                // 挡住内容区左侧 1pt，点击会莫名没反应。
                .allowsHitTesting(state.progress > 0.02)

            // ── 手势层 ──
            // 单独铺一层透明的 UIHostingController 承载 UIPanGestureRecognizer。
            // 不用 SwiftUI 的 DragGesture 是因为它拿不到「起手点在不在屏幕
            // 左边缘」—— DragGesture 只给相对位移，而我们需要绝对坐标来判断
            // 是否从边缘起手。混用 UIKit 手势识别器是这里最省事的做法。
            EdgePanOverlay(state: state, drawerWidth: drawerWidth)
                .allowsHitTesting(true)
        }
        .environmentObject(state)
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
