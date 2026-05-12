import SwiftUI
import WidgetKit

// MARK: - Timeline Provider
struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry {
        QuickActionsEntry(date: Date())
    }
    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
        completion(QuickActionsEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [QuickActionsEntry(date: Date())], policy: .after(next)))
    }
}

struct QuickActionsEntry: TimelineEntry {
    let date: Date
}

// MARK: - Widget Configuration
struct QuickActionsWidget: Widget {
    static let kind: String = "com.openui.openui.QuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuickActionsProvider()) { entry in
            QuickActionsEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Open Relay")
        .description("Quick access to AI chat, voice, and media.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Root View
struct QuickActionsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickActionsEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumQuickActionsView()
        default:
            SmallQuickActionsView()
        }
    }
}

// MARK: - Small Widget
struct SmallQuickActionsView: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // New Chat — full-color app icon card, no widgetAccentable
                NewChatCard()
                // Voice
                QuickCard(url: OpenUIURL.voiceCall, label: "Voice") {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }
            }
            HStack(spacing: 8) {
                // Camera
                QuickCard(url: OpenUIURL.cameraChat, label: "Camera") {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }
                // Photos
                QuickCard(url: OpenUIURL.photosChat, label: "Photos") {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }
            }
        }
    }
}

// MARK: - New Chat Card (full-color, no tinting)
/// Standalone card for New Chat. Deliberately avoids `.widgetAccentable()` so
/// the app icon is never desaturated or tinted by any widget rendering mode.
private struct NewChatCard: View {
    var body: some View {
        Link(destination: OpenUIURL.newChat) {
            VStack(spacing: 5) {
                Image("AppIconImage")
                    .renderingMode(.original)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text("New Chat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("New Chat")
    }
}

// MARK: - Medium Widget
struct MediumQuickActionsView: View {
    var body: some View {
        VStack(spacing: 8) {
            // Full-width neutral Ask bar with mic button on the right
            ZStack {
                Link(destination: OpenUIURL.newChat) {
                    HStack(spacing: 10) {
                        Image("AppIconImage")
                            .renderingMode(.original)
                            .resizable()
                            .widgetAccentedRenderingMode(.fullColor)
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Text("Ask Open Relay…")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("New Chat")

                // Mic button — separate Link so it deep-links to voice
                HStack {
                    Spacer()
                    Link(destination: OpenUIURL.voiceCall) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .widgetAccentable()
                            .padding(.trailing, 14)
                    }
                    .accessibilityLabel("Voice")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemFill))
            )
            Spacer()

            // 4 neutral tiles
            HStack(spacing: 8) {
                QuickCard(url: OpenUIURL.cameraChat, label: "Camera") {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }
                QuickCard(url: OpenUIURL.photosChat, label: "Photos") {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }
                QuickCard(url: OpenUIURL.fileChat, label: "Files") {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }
                QuickCard(url: OpenUIURL.newChannel, label: "Channel") {
                    Image(systemName: "number")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }
            }
        }
        .padding(10)
    }
}

// MARK: - Reusable Quick Card
/// A neutral (or accent) rounded card that expands to fill its HStack cell equally.
/// Tinted mode: `.widgetAccentable()` on the accent bg makes it pick up the system tint.
/// Neutral icons use `.widgetAccentable()` so they also pick up tint colour in tinted mode.
private struct QuickCard<Icon: View>: View {
    let url: URL
    let label: String
    var isAccent: Bool = false
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Link(destination: url) {
            VStack(spacing: 5) {
                // Icon card
                ZStack {
                    icon()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isAccent ? Color.accentColor : Color(.secondarySystemFill))
                        .widgetAccentable(isAccent)
                )

                // Label below the card
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}
