import SwiftUI

// MARK: - AnimatedPresence

/// A wrapper that smoothly interpolates the height of conditional content
/// rather than snapping it to the final size.
///
/// ## Problem it solves
/// SwiftUI's standard `if condition { content() }` pattern causes the parent
/// container to immediately re-measure and snap to the new height. Inside
/// `List` rows this shows as a jarring row-height jump; inside `ScrollView`
/// it manifests as a layout shift.
///
/// ## How it works
/// 1. The content is **always rendered** (but clipped to zero when hidden),
///    so the natural height is always measurable.
/// 2. A `GeometryReader` background silently tracks the content height.
/// 3. A `.frame(height:)` modifier uses the `visible` flag to switch between
///    `0` and the measured height — because this value is changed inside
///    `withAnimation`, SwiftUI interpolates it smoothly.
/// 4. `.clipped()` hides the overflowing content during the animation.
///
/// ## Usage
/// ```swift
/// // Replace:
/// if let msg = conversation.messages.last {
///     Text(msg.content).lineLimit(2)
/// }
///
/// // With:
/// AnimatedPresence(visible: conversation.messages.last != nil) {
///     if let msg = conversation.messages.last {
///         Text(msg.content).lineLimit(2)
///     }
/// }
/// ```
///
/// - Note: Uses `.easeInOut(duration: 0.22)` by default — snappy enough to
///   feel responsive, slow enough for the user to track the motion.
struct AnimatedPresence<Content: View>: View {
    /// Whether the content should be visible (full height) or hidden (zero height).
    var visible: Bool
    /// The animation used to interpolate the height. Defaults to a quick ease-in-out.
    var animation: Animation = .easeInOut(duration: 0.22)
    @ViewBuilder var content: () -> Content

    /// The measured natural height of the content.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        content()
            // Silently measure the content's natural height.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, h in contentHeight = h }
                }
            )
            // Interpolate height between 0 and natural size.
            .frame(height: visible ? contentHeight : 0, alignment: .top)
            // Clip so content doesn't overflow its frame while collapsing.
            .clipped()
            // Fade in/out alongside the height change.
            .opacity(visible ? 1 : 0)
            // Animate both frame and opacity together.
            .animation(animation, value: visible)
    }
}
