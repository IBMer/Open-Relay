//
//  AppIntent.swift
//  OpenUIWidgets
//
//  Defines all deep-link URLs and AppIntent actions used by the
//  Open Relay home-screen and lock-screen widgets.
//
//  Every intent opens the app via a `openui://` URL, which is
//  handled by the `.onOpenURL` switch in `Open_UIApp.swift`.
//

import AppIntents
import Foundation

// MARK: - Deep-Link URL Constants

/// Centralised registry of every `openui://` deep-link used by the widget
/// extension. Keeping them here ensures the widget and the main app stay
/// in sync — the strings mirror the `case` labels in `Open_UIApp.swift`.
enum OpenUIURL {
    static let newChat    = URL(string: "openui://new-chat")!
    static let voiceCall  = URL(string: "openui://voice-call")!
    static let cameraChat = URL(string: "openui://camera-chat")!
    static let photosChat = URL(string: "openui://photos-chat")!
    static let fileChat   = URL(string: "openui://file-chat")!
    static let newChannel = URL(string: "openui://new-channel")!
}

// MARK: - New Chat

/// Launches Open Relay and starts a fresh text chat.
struct NewChatWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Start a new AI chat in Open Relay.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(OpenUIURL.newChat))
    }
}

// MARK: - Voice Call

/// Launches Open Relay and opens the voice call interface.
struct VoiceCallWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Voice Call"
    static var description = IntentDescription("Start a voice call in Open Relay.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(OpenUIURL.voiceCall))
    }
}

// MARK: - Camera Chat

/// Launches Open Relay and opens a new chat with the camera picker active.
struct CameraChatWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Camera Chat"
    static var description = IntentDescription("Open a new chat with camera in Open Relay.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(OpenUIURL.cameraChat))
    }
}

// MARK: - Photos Chat

/// Launches Open Relay and opens a new chat with the photo picker active.
struct PhotosChatWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Photos Chat"
    static var description = IntentDescription("Open a new chat with photo picker in Open Relay.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(OpenUIURL.photosChat))
    }
}

// MARK: - File Chat

/// Launches Open Relay and opens a new chat with the file picker active.
struct FileChatWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "File Chat"
    static var description = IntentDescription("Open a new chat with file picker in Open Relay.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(OpenUIURL.fileChat))
    }
}

// MARK: - New Channel

/// Launches Open Relay and opens the create-channel sheet.
struct NewChannelWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "New Channel"
    static var description = IntentDescription("Create a new channel in Open Relay.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(OpenUIURL.newChannel))
    }
}
