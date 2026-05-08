import SwiftUI
import MarkdownView

// MARK: - Combined Updates Sheet

/// Sheet shown when one or both of (app update, server update) are available.
/// If both are available, renders them as two sections in a single scrollable sheet.
/// If only one is available, renders just that section.
struct CombinedUpdateSheet: View {
    let appUpdate: AppUpdateInfo?
    let serverUpdate: ServerUpdateInfo?
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityScale) private var accessibilityScale

    private static let appStoreURL = URL(string: "https://apps.apple.com/app/id6759630325")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if let app = appUpdate, let server = serverUpdate {
                        // Both updates available — show both sections
                        appUpdateSection(app)
                            .padding(.top, 24)

                        Divider()
                            .padding(.horizontal, 20)
                            .padding(.vertical, 4)

                        serverUpdateSection(server)
                            .padding(.bottom, 8)

                        buttonSection(appUpdate: app, serverUpdate: server)
                            .padding(.top, 16)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)

                    } else if let app = appUpdate {
                        // App update only
                        appUpdateSection(app)
                            .padding(.top, 28)
                            .padding(.bottom, 24)

                        Divider()
                            .padding(.horizontal, 20)

                        if !app.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            releaseNotesSection(app.releaseNotes, title: "What's New")
                                .padding(.top, 20)
                                .padding(.horizontal, 20)
                        }

                        buttonSection(appUpdate: app, serverUpdate: nil)
                            .padding(.top, 24)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)

                    } else if let server = serverUpdate {
                        // Server update only
                        serverUpdateSection(server)
                            .padding(.top, 28)
                            .padding(.bottom, 8)

                        if let cl = server.changelog {
                            let md = cl.markdownText
                            if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Divider()
                                    .padding(.horizontal, 20)
                                releaseNotesSection(md, title: "Changelog")
                                    .padding(.top, 20)
                                    .padding(.horizontal, 20)
                            }
                        }

                        buttonSection(appUpdate: nil, serverUpdate: server)
                            .padding(.top, 24)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)
                    }
                }
            }
            .background(theme.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onDismiss()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.textTertiary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - App Update Section

    @ViewBuilder
    private func appUpdateSection(_ update: AppUpdateInfo) -> some View {
        VStack(spacing: 12) {
            // App icon
            Image("AppIconImage")
                .resizable()
                .scaledToFill()
                .frame(width: appUpdate != nil && serverUpdate != nil ? 56 : 72,
                       height: appUpdate != nil && serverUpdate != nil ? 56 : 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(spacing: 6) {
                badgeView(text: "App Update Available", color: .accentColor)

                Text("Open Relay \(update.version)")
                    .font(.system(size: appUpdate != nil && serverUpdate != nil ? 18 : 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text("A new version of Open Relay is ready.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // When both present, inline release notes (collapsed)
                if appUpdate != nil && serverUpdate != nil,
                   !update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    releaseNotesSection(update.releaseNotes, title: "App Release Notes")
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Server Update Section

    @ViewBuilder
    private func serverUpdateSection(_ update: ServerUpdateInfo) -> some View {
        VStack(spacing: 12) {
            // Server icon
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: appUpdate != nil && serverUpdate != nil ? 56 : 72,
                           height: appUpdate != nil && serverUpdate != nil ? 56 : 72)
                Image(systemName: "server.rack")
                    .font(.system(size: appUpdate != nil && serverUpdate != nil ? 24 : 30, weight: .medium))
                    .foregroundStyle(Color.blue)
            }

            VStack(spacing: 6) {
                badgeView(text: "Server Update Available", color: .blue)

                Text("Open WebUI \(update.version)")
                    .font(.system(size: appUpdate != nil && serverUpdate != nil ? 18 : 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text(update.serverName)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)

                Text("Your Open WebUI server has a new version available.\nContact your administrator to update.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // When both present, inline changelog (collapsed)
                if appUpdate != nil && serverUpdate != nil,
                   let cl = update.changelog {
                    let md = cl.markdownText
                    if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        releaseNotesSection(md, title: "Server Changelog")
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, appUpdate != nil ? 16 : 0)
    }

    // MARK: - Shared Subviews

    private func badgeView(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))
    }

    @ViewBuilder
    private func releaseNotesSection(_ markdown: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            MarkdownView(markdown, theme: markdownTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var markdownTheme: MarkdownTheme {
        let scale = accessibilityScale.scale(for: .content)
        var t = MarkdownTheme.default
        let baseFontSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        t.align(to: baseFontSize * scale)
        return t
    }

    // MARK: - Buttons

    @ViewBuilder
    private func buttonSection(appUpdate: AppUpdateInfo?, serverUpdate: ServerUpdateInfo?) -> some View {
        VStack(spacing: 10) {
            if appUpdate != nil {
                // Primary: Update App on App Store
                Button {
                    UIApplication.shared.open(Self.appStoreURL)
                    onDismiss()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Update App on App Store")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            // Later / Dismiss button
            Button {
                onDismiss()
                dismiss()
            } label: {
                Text(appUpdate != nil ? "Later" : "Got It")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
    }
}
