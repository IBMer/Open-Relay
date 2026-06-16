import SwiftUI

/// A sheet that lists all files previously uploaded to the server by the current user.
///
/// The user can search and select one or more files. On confirmation,
/// the selected files are returned as pre-completed `ChatAttachment` objects
/// (with `uploadedFileId` already set) so they don't need to be re-uploaded.
struct ServerFilesPickerSheet: View {
    @Binding var isPresented: Bool
    var apiClient: APIClient?
    var onFilesSelected: ([ChatAttachment]) -> Void

    @Environment(\.theme) private var theme

    @State private var files: [FileInfoResponse] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedIds: Set<String> = []

    private var filtered: [FileInfoResponse] {
        guard !searchText.isEmpty else { return files }
        let q = searchText.lowercased()
        return files.filter { fileName($0).lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading files…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textSecondary)
                        Text(errorMessage)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") { Task { await loadFiles() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "doc")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textTertiary)
                        Text(searchText.isEmpty ? "No files uploaded yet" : "No files match \(searchText)")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, id: \.id) { file in
                        fileRow(file)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Attach Files")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Attach \(selectedIds.isEmpty ? "" : "(\(selectedIds.count))")") {
                        confirmSelection()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedIds.isEmpty)
                }
            }
            .background(theme.background.ignoresSafeArea())
        }
        .onAppear {
            Task { await loadFiles() }
        }
    }

    // MARK: - Row

    private func fileRow(_ file: FileInfoResponse) -> some View {
        let isSelected = selectedIds.contains(file.id)
        let name = fileName(file)
        let ct: String? = file.contentType
        return Button {
            if isSelected { selectedIds.remove(file.id) }
            else { selectedIds.insert(file.id) }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: fileIcon(for: ct))
                    .scaledFont(size: 18)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textSecondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)

                    if let ct, !ct.isEmpty {
                        Text(ct)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? theme.brandPrimary.opacity(0.08) : Color.clear)
    }

    // MARK: - Actions

    private func loadFiles() async {
        guard let apiClient else {
            errorMessage = "No server connection"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            files = try await apiClient.getUserFiles()
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func confirmSelection() {
        let selected = files.filter { selectedIds.contains($0.id) }
        let attachments: [ChatAttachment] = selected.map { file in
            let name = fileName(file)
            var attachment = ChatAttachment(
                type: .file,
                name: name
            )
            attachment.uploadStatus = .completed
            attachment.uploadedFileId = file.id
            // Build a file object in the same shape the upload API returns,
            // so the send pipeline's "file" inner field is correct.
            let ct = file.contentType ?? "application/octet-stream"
            attachment.uploadedFileObject = [
                "id": file.id,
                "filename": file.filename ?? name,
                "meta": [
                    "name": name,
                    "content_type": ct,
                    "size": file.size ?? 0
                ]
            ]
            return attachment
        }
        onFilesSelected(attachments)
        isPresented = false
    }

    // MARK: - Helpers

    /// Returns a human-readable display name for a `FileInfoResponse`.
    private func fileName(_ file: FileInfoResponse) -> String {
        file.filename ?? file.id
    }

    private func fileIcon(for contentType: String?) -> String {
        guard let ct = contentType?.lowercased() else { return "doc" }
        if ct.hasPrefix("image/") { return "photo" }
        if ct.hasPrefix("video/") { return "video" }
        if ct.hasPrefix("audio/") { return "waveform" }
        if ct.contains("pdf") { return "doc.richtext" }
        if ct.contains("word") || ct.contains("document") { return "doc.text" }
        if ct.contains("spreadsheet") || ct.contains("excel") { return "tablecells" }
        if ct.contains("presentation") || ct.contains("powerpoint") { return "rectangle.on.rectangle" }
        if ct.contains("json") || ct.contains("xml") || ct.contains("html") { return "curlybraces" }
        if ct.contains("zip") || ct.contains("tar") || ct.contains("gzip") { return "archivebox" }
        if ct.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }
}
