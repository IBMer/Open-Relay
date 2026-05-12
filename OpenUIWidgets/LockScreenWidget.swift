//
//  LockScreenWidget.swift
//  OpenUIWidgets
//
//  Lock-screen and StandBy accessories for Open Relay.
//  All three accessory families are provided so the user can choose
//  whichever fits their lock-screen layout.
//
//  Every accessory deep-links to openui://new-chat.
//  • accessoryCircular  — circular icon badge
//  • accessoryRectangular — icon + two lines of text
//  • accessoryInline   — small inline text label
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline Provider

/// Static provider — lock-screen accessories have no time-varying content.
struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (LockScreenEntry) -> Void
    ) {
        completion(LockScreenEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<LockScreenEntry>) -> Void
    ) {
        let entry = LockScreenEntry(date: Date())
        let nextUpdate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Timeline Entry

struct LockScreenEntry: TimelineEntry {
    let date: Date
}

// MARK: - Widget Configuration

struct LockScreenWidget: Widget {
    static let kind: String = "com.openui.openui.LockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LockScreenProvider()) { entry in
            LockScreenEntryView(entry: entry)
        }
        .configurationDisplayName("Open Relay")
        .description("Tap to start a new AI chat from your lock screen.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - Entry View Dispatcher

struct LockScreenEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LockScreenEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularView()
        case .accessoryRectangular:
            AccessoryRectangularView()
        case .accessoryInline:
            AccessoryInlineView()
        default:
            AccessoryCircularView()
        }
    }
}

// MARK: - accessoryCircular

/// Circular badge: tinted background with the chat SF Symbol.
/// Tapping launches openui://new-chat.
private struct AccessoryCircularView: View {
    var body: some View {
        Button(intent: NewChatWidgetIntent()) {
            ZStack {
                // System fills the circle with the lock-screen accent colour
                // in accented/vibrant modes — we let containerBackground handle it.
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 18, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - accessoryRectangular

/// Horizontal pill: icon on the left, app name + subtitle on the right.
private struct AccessoryRectangularView: View {
    var body: some View {
        Button(intent: NewChatWidgetIntent()) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .widgetAccentable()

                VStack(alignment: .leading, spacing: 1) {
                    Text("Open Relay")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                    Text("New Chat")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - accessoryInline

/// Single-line text accessory shown in the lock screen clock area.
private struct AccessoryInlineView: View {
    var body: some View {
        Button(intent: NewChatWidgetIntent()) {
            Label("Open Relay", systemImage: "bubble.left.and.text.bubble.right.fill")
                .widgetAccentable()
        }
        .buttonStyle(.plain)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    LockScreenWidget()
} timeline: {
    LockScreenEntry(date: .now)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    LockScreenWidget()
} timeline: {
    LockScreenEntry(date: .now)
}

#Preview("Inline", as: .accessoryInline) {
    LockScreenWidget()
} timeline: {
    LockScreenEntry(date: .now)
}
