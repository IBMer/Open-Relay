import Foundation
import os.log

/// Manages the state for the terminal file browser panel.
///
/// Handles directory navigation, file operations (create, delete, upload, download),
/// and a **persistent bash shell session** on the terminal server.
///
/// The terminal works like a real terminal window: one bash process is started when
/// the terminal opens, and all subsequent input is sent as stdin to that process via
/// `POST /execute/{processId}/input`. This matches the Open WebUI web interface
/// behaviour where each terminal window is a single persistent session.
@MainActor @Observable
final class TerminalBrowserViewModel {
    // MARK: - File Browser State

    /// Current directory path being viewed.
    var currentPath: String = "/home/user"
    /// Files and folders in the current directory.
    var items: [TerminalFileItem] = []
    /// Whether we're loading directory contents.
    var isLoading: Bool = false
    /// Error message to display.
    var errorMessage: String?
    /// Navigation history for back navigation.
    var pathHistory: [String] = []

    // MARK: - Shell Session State

    /// Current command input text.
    var commandInput: String = ""
    /// Full terminal output accumulated since the session started.
    var shellOutput: String = ""
    /// Whether the shell session is in the process of being started.
    var isShellStarting: Bool = false
    /// Whether the shell process is currently running (ready for input).
    var isShellReady: Bool = false
    /// Whether the terminal section is expanded.
    var isTerminalExpanded: Bool = false
    /// Token used to force the scroll view to snap to the latest output.
    var outputScrollToken: Int = 0

    // MARK: - Action State

    /// Whether the new folder alert is showing.
    var showNewFolderAlert: Bool = false
    /// New folder name input.
    var newFolderName: String = ""
    /// File being renamed (nil = not renaming).
    var renamingFile: TerminalFileItem?
    /// New name for the file being renamed.
    var renameText: String = ""

    // MARK: - Private

    private var apiClient: APIClient?
    private var serverId: String = ""
    private let logger = Logger(subsystem: "com.openui", category: "TerminalBrowser")

    /// The process ID of the currently running bash shell.
    private var shellProcessId: String?
    /// Background task that continuously polls the shell for new output.
    private var shellPollingTask: Task<Void, Never>?
    /// The next offset to use when polling for shell output.
    private var shellOutputOffset: Int = 0

    // MARK: - Computed

    /// Path segments for breadcrumb navigation.
    var pathSegments: [(name: String, path: String)] {
        let components = currentPath.split(separator: "/").map(String.init)
        var segments: [(name: String, path: String)] = [("/", "/")]
        var accumulated = ""
        for component in components {
            accumulated += "/\(component)"
            segments.append((component, accumulated))
        }
        return segments
    }

    /// Sorted items: directories first, then files, both alphabetically.
    var sortedItems: [TerminalFileItem] {
        let dirs = items.filter(\.isDirectory).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let files = items.filter { !$0.isDirectory }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return dirs + files
    }

    // MARK: - Setup

    func configure(apiClient: APIClient, serverId: String) {
        self.apiClient = apiClient
        self.serverId = serverId
    }

    /// Resets all state to defaults. Called when switching to a new chat
    /// so the file browser starts fresh.
    func reset() {
        // Cancel the persistent shell before clearing state
        stopShell()

        currentPath = "/home/user"
        items = []
        isLoading = false
        errorMessage = nil
        pathHistory = []
        commandInput = ""
        shellOutput = ""
        isShellStarting = false
        isShellReady = false
        isTerminalExpanded = false
        outputScrollToken = 0
        showNewFolderAlert = false
        newFolderName = ""
        renamingFile = nil
        renameText = ""
    }

    // MARK: - Navigation

    /// Loads the contents of the current directory.
    func loadDirectory() async {
        guard let apiClient, !serverId.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await apiClient.terminalListFiles(serverId: serverId, path: currentPath)
        } catch {
            logger.error("Failed to list files at \(self.currentPath): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            items = []
        }
        isLoading = false
    }

    /// Navigates into a directory.
    func navigateToDirectory(_ path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    /// Navigates to a specific path segment (breadcrumb tap).
    func navigateToPath(_ path: String) {
        guard path != currentPath else { return }
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    /// Navigates back to the previous directory.
    func navigateBack() {
        guard let previous = pathHistory.popLast() else { return }
        currentPath = previous
        Task { await loadDirectory() }
    }

    /// Refreshes the current directory.
    func refresh() {
        Task { await loadDirectory() }
    }

    // MARK: - File Operations

    /// Creates a new folder in the current directory.
    func createFolder(name: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        let folderPath = currentPath.hasSuffix("/")
            ? "\(currentPath)\(name)"
            : "\(currentPath)/\(name)"
        do {
            try await apiClient.terminalMkdir(serverId: serverId, path: folderPath)
            await loadDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes a file or directory.
    func deleteItem(_ item: TerminalFileItem) async {
        guard let apiClient, !serverId.isEmpty else { return }
        do {
            try await apiClient.terminalDeleteFile(serverId: serverId, path: item.path)
            // Remove from local list immediately for snappy feel
            items.removeAll { $0.path == item.path }
        } catch {
            errorMessage = error.localizedDescription
            await loadDirectory() // Refresh to get accurate state
        }
    }

    /// Downloads a file and returns the local URL for sharing/preview.
    func downloadFile(_ item: TerminalFileItem) async -> URL? {
        guard let apiClient, !serverId.isEmpty else { return nil }
        do {
            let (data, _) = try await apiClient.terminalDownloadFile(serverId: serverId, path: item.path)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("terminal_downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent(item.name)
            try data.write(to: fileURL)
            return fileURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Uploads a file to the current directory.
    func uploadFile(data: Data, fileName: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        do {
            try await apiClient.terminalUploadFile(
                serverId: serverId,
                fileData: data,
                fileName: fileName,
                destinationPath: currentPath
            )
            await loadDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Persistent Shell Session

    /// Starts a persistent bash shell session. Called automatically when the terminal
    /// section is first expanded.
    ///
    /// Launches `bash` via `/execute`, stores the process ID, then starts a
    /// background task that continuously polls for output using the offset-based
    /// long-poll endpoint.
    func startShell() async {
        guard let apiClient, !serverId.isEmpty else { return }
        guard !isShellReady, !isShellStarting else { return }

        isShellStarting = true
        shellOutput = ""
        shellOutputOffset = 0

        do {
            let result = try await apiClient.terminalExecute(
                serverId: serverId,
                command: "bash",
                cwd: currentPath
            )
            shellProcessId = result.id
            shellOutputOffset = result.nextOffset
            if !result.output.isEmpty {
                appendOutput(result.output)
            }
            isShellReady = true
            isShellStarting = false
            logger.info("Shell started — processId: \(result.id)")
            startPollingShell()
        } catch {
            isShellStarting = false
            isShellReady = false
            appendOutput("\r\n[Failed to start shell: \(error.localizedDescription)]\r\n")
            logger.error("Failed to start shell: \(error.localizedDescription)")
        }
    }

    /// Sends a line of text as stdin to the running bash process.
    ///
    /// The input is appended with `\n` so the shell treats it as an Enter press.
    /// If the user types "clear", the local output buffer is cleared immediately
    /// for a snappy feel (the server may or may not honour ANSI clear).
    func sendInput(_ text: String) {
        guard let apiClient, !serverId.isEmpty else { return }
        guard let processId = shellProcessId else {
            // Shell not yet started — start it first then send input
            Task {
                await startShell()
                sendInput(text)
            }
            return
        }

        // Echo input locally so the user sees what they typed
        commandInput = ""
        appendOutput("\r\n$ \(text)")

        // Handle "clear" locally for instant feedback
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "clear" {
            shellOutput = ""
            outputScrollToken += 1
        }

        Task {
            do {
                try await apiClient.terminalSendInput(
                    serverId: serverId,
                    processId: processId,
                    input: text + "\n"
                )
            } catch {
                appendOutput("\r\n[Input error: \(error.localizedDescription)]")
                logger.error("sendInput error: \(error.localizedDescription)")
            }
        }
    }

    /// Clears the on-screen terminal output buffer.
    func clearOutput() {
        shellOutput = ""
        outputScrollToken += 1
    }

    // MARK: - Private Shell Helpers

    private func startPollingShell() {
        shellPollingTask?.cancel()
        shellPollingTask = Task {
            await pollShellOutput()
        }
    }

    private func stopShell() {
        shellPollingTask?.cancel()
        shellPollingTask = nil
        shellProcessId = nil
        isShellReady = false
        isShellStarting = false
    }

    /// Continuously long-polls for new output from the running bash process.
    ///
    /// Uses offset-based polling: each call to `terminalGetCommandStatus` returns
    /// only the output produced since the last read. When the process exits (unlikely
    /// for a bash session), the loop terminates.
    private func pollShellOutput() async {
        guard let apiClient else { return }

        while !Task.isCancelled {
            guard let processId = shellProcessId else { break }

            do {
                let status = try await apiClient.terminalGetCommandStatus(
                    serverId: serverId,
                    processId: processId,
                    offset: shellOutputOffset
                )

                if !status.output.isEmpty {
                    appendOutput(status.output)
                }
                shellOutputOffset = status.nextOffset

                if !status.isRunning {
                    // Bash exited — offer to restart
                    appendOutput("\r\n[Shell session ended]\r\n")
                    isShellReady = false
                    shellProcessId = nil
                    logger.info("Shell process exited.")
                    break
                }
            } catch {
                if Task.isCancelled { break }
                logger.error("Poll error: \(error.localizedDescription)")
                // Brief back-off before retrying after a network error
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Appends text to the output buffer and bumps the scroll token.
    ///
    /// Filters out known harmless bash warnings that appear when bash runs
    /// without a PTY (pseudo-terminal). These are not real errors — they are
    /// standard output from bash in containerised/non-interactive environments.
    private func appendOutput(_ text: String) {
        let filtered = filterBashWarnings(text)
        guard !filtered.isEmpty else { return }
        shellOutput += filtered
        outputScrollToken += 1
    }

    /// Strips lines that are known harmless bash non-PTY startup warnings.
    private func filterBashWarnings(_ text: String) -> String {
        let suppressedPrefixes = [
            "bash: cannot set terminal process group",
            "bash: no job control in this shell"
        ]
        // Split on both \r\n and \n, filter, then rejoin with \r\n
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: "\r "))
            return !suppressedPrefixes.contains { trimmed.hasPrefix($0) }
        }
        return kept.joined(separator: "\n")
    }
}
