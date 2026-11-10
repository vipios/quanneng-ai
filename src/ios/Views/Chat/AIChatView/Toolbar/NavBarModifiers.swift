//
//  NavBarModifiers.swift
//  Minis - chat page (AIChatView)
//
//  Navigation bar modifiers: NavTitleFrameModifier (also used by
//  HelperTranscriptPage) and NavBarStyleModifier (bar appearance and the top
//  safe-area inset the page reads).
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - [R43] 保住左滑返回

/// 隐藏系统返回键之后，把「左滑返回」这个手势重新接上。
///
/// ## 为什么需要它
///
/// SwiftUI 的 `navigationBarBackButtonHidden(true)` 不只是把那个 ‹ 藏起来 ——
/// 它同时会让 `UINavigationController.interactivePopGestureRecognizer`
/// **失效**。原因是 UIKit 把手势的 delegate 挂在系统返回按钮上，
/// 按钮一消失，delegate 就问不到「现在能不能 pop」，默认回 false，
/// 于是整条左滑返回都没了。
///
/// 这是「换个图标」必须付的代价，但不能真付：用户已经习惯左滑返回，
/// 换掉图标却把左滑弄没，比不换更糟。
///
/// ## 怎么做
///
/// 把那个手势的 delegate 抢过来，自己按 `viewControllers.count > 1` 回答
/// 「能不能 pop」。这条判据是关键 —— 在根视图上返回 true 会让手势
/// 去 pop 一个空栈，UIKit 会直接把界面卡死（这是这个 hack 最常见的翻车点）。
///
/// ## 边界
///
/// 只在**栈深大于 1** 时启用，根视图不响应；`viewControllers.count` 每次
/// 都现取，不缓存 —— SwiftUI 的 NavigationStack 会在我们看不见的时候
/// 改栈，缓存值一定会过期。
struct SwipeBackEnabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { SwipeBackView() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class SwipeBackView: UIView, UIGestureRecognizerDelegate {

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // 窗口没了（页面被销毁）就交还控制权，别让一个已脱离视图树的
            // 对象继续当 delegate —— 那种 dangling delegate 是偶发
            // 「左滑直接卡住」的来源。
            guard window != nil else {
                navigationController?.interactivePopGestureRecognizer?.delegate = nil
                return
            }
            // 延后一拍：`didMoveToWindow` 时 SwiftUI 可能还没把返回按钮
            // 真正移除，UIKit 会在这之后再把 delegate 设废一次。
            // 下一轮 runloop 接管才是最终态。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                guard let nav = self.navigationController else { return }
                nav.interactivePopGestureRecognizer?.delegate = self
                nav.interactivePopGestureRecognizer?.isEnabled = true
            }
        }

        // ⚠️ 这里的 `override` 是**必须**的，不是为了好看。
        //
        // `UIGestureRecognizerDelegate` 里这个方法有默认实现（协议扩展），
        // 但 UIView 本身也从 `NSObject` 那侧暴露了同名方法。我们的
        // `SwipeBackView` 继承自 UIView，于是编译器认为这是「重写父类成员」，
        // 漏掉 override 直接报：
        //   error: overriding declaration requires an 'override' keyword
        // 这不是运行时问题，是编译期硬错 —— 整个 target 编不过。
        override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            // 根视图不允许 pop —— 否则手势会把空栈当目标，界面直接僵住。
            guard let nav = navigationController else { return false }
            guard nav.viewControllers.count > 1 else { return false }

            // 有输入框正在编辑时不起手。
            //
            // 聊天页的输入框贴着底部，键盘弹起来之后手指在左边缘那一条
            // 上下滑动很常见（尤其单手），误触一次就退回会话列表 ——
            // 而这个页面没有「回来继续写」的草稿恢复，打了一半的字就悬了。
            // 系统自带返回键那套没有这个保护（它没被键盘顶到同一个位置），
            // 是我们自己接管后必须补上的。
            if let v = g.view, let window = v.window,
               window.minis_hasTextInputFirstResponder {
                return false
            }
            return true
        }

        /// 有横向滚动区域的页面（比如带横向表格的网页）要从自己身上起手，
        /// 别被这条边缘手势抢走。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - [R43] 判断当前有没有输入框在编辑

private extension UIView {
    /// 当前窗口里有没有「正在编辑的输入控件」。
    ///
    /// UIKit 没有公开 API 直接问「谁是 first responder」，只能自己走一遍
    /// 视图树看 `isFirstResponder`。这是个 O(n) 的遍历，但只在手势
    /// `shouldBegin` 那一刻跑一次（手指刚按下），不在渲染链上，
    /// 对聊天页那点视图数量完全够用。
    var minis_hasTextInputFirstResponder: Bool {
        if isFirstResponder {
            // 只认文字输入类。理由：按钮、手势识别器也可能是 first responder，
            // 那些不该拦住左滑返回 —— 否则会出现「什么都没有却在编辑」
            // 导致左滑失灵，比误触更难查。
            return self is UITextField || self is UITextView
        }
        for sub in subviews where sub.minis_hasTextInputFirstResponder {
            return true
        }
        return false
    }
}

// MARK: - Nav Bar Modifiers

// [T-agent-transcript-navbar] Shared with HelperTranscriptPage; logic unchanged.
struct NavTitleFrameModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // [NavTitleTopClip 2026-07-23] The principal titleView aligns to the
            // liquid-glass navbar's ~44pt band. Give it 46pt centered so tall
            // title glyphs (semibold 16pt + CJK/caps ascenders) render in full.
            //
            // [NavTitleTransitionClip 2026-07-23] Do NOT `.clipped()`. During a
            // push/pop transition the system interpolates the principal item's
            // frame/scale/alpha; a hard clip rectangle cuts the mid-transition
            // frames along the 46pt box far more aggressively than the steady
            // state (users saw the title sliced to half a line during the
            // animation). The 46pt frame only *sizes* the item for band
            // alignment — the 3-row stack's natural height already fits within
            // it at steady state (spacing -2, ~44pt), so there is nothing to clip
            // away, and letting transition frames render uncropped restores the
            // standard system title transition.
            content
                .frame(height: 46, alignment: .center)
        } else {
            content
        }
    }
}

// [T-agent-transcript-navbar] Shared with HelperTranscriptPage; logic unchanged.
struct NavBarStyleModifier: ViewModifier {
    @Binding var topSafeAreaInset: CGFloat

    /// [T-agent-transcript-navbar-lost] When false, the iOS 16-18 branch skips
    /// the safe-area measuring overlay entirely.
    ///
    /// That overlay writes `topSafeAreaInset` from an `onGeometryChange`
    /// action. A tool sheet presented from OUTSIDE the page's NavigationStack
    /// (SheetOverlayView, a child VC of the message list) changes the top inset
    /// as it presents and dismisses, so the action fires DURING the dismissal's
    /// view-graph update. On the agent transcript page that update ends with
    /// SwiftUI calling `setNavigationBarHidden(true, animated: false)` -- an
    /// all-SwiftUI call stack, no app frames, once per dismissal,
    /// deterministically -- and the bar never comes back.
    ///
    /// `topSafeAreaInset` has no readers on either page: the one site that
    /// would use it deliberately prefers a constant (see slashPickerTopReserve),
    /// so on the transcript page the overlay is pure cost. The main chat keeps
    /// it (default true) rather than change behaviour that is not implicated.
    var measuresSafeArea: Bool = true

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // iOS 26: extend content behind nav bar so liquid-glass has
            // something to show through; the collection view's
            // contentInsetAdjustmentBehavior = .automatic keeps messages
            // starting below the bar.
            content
                .ignoresSafeArea(.container, edges: .top)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                // [T-macos27-liquid-glass-navbar] See MacOS27GlassWorkaround in
                // ContentView. `toolbarBackgroundVisibility(.visible)` only
                // declares "there should be a backdrop"; the material is still
                // produced by glass sampling — which does not render in a
                // foreground window on macOS 27, leaving the bar fully
                // transparent. Pin an opaque colour here instead (the same one
                // the iOS 16–18 branch below uses). The message list is a
                // UIKit-hosted UICollectionView, so the modifier's
                // scrollEdgeEffectHidden is a no-op for it; what does the work
                // here is toolbarBackground. No change needed in
                // MessageListViewController.
                .modifier(MacOS27OpaqueNavigationBar(background: ChatColors.background))
        } else {
            // iOS 16–18: opaque navbar background
            content
                .toolbarBackground(ChatColors.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .overlay(alignment: .top) {
                    if measuresSafeArea {
                        // [T-ios-geometry-observer-crash] onGeometryChange
                        // replaces the GeometryReader scaffold (async-renderer
                        // SIGTRAP — see the floating-bar site). The proxy
                        // measures the same Color.clear the reader wrapped;
                        // ignoresSafeArea/frame stay outside it exactly as
                        // before, and the action's initial fire covers the old
                        // onAppear seed.
                        Color.clear
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.safeAreaInsets.top
                            } action: { topSafeAreaInset = $0 }
                            .ignoresSafeArea()
                            .frame(height: 0)
                    }
                }
        }
    }
}
