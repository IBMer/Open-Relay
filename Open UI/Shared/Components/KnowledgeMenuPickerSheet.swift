import SwiftUI

// MARK: - Knowledge Menu Picker Sheet

/// A full-screen sheet wrapper around `KnowledgePickerView` for use from
/// the + attachment menu. Unlike the inline `#` trigger picker (which floats
/// above the input field and uses live query state from the VM), this sheet
/// owns its own search state and loads knowledge items independently.
struct KnowledgeMenuPickerSheet: View {
    @Binding var isPresented: Bool
    @Binding var selectedItems: [KnowledgeItem]
    var apiClient: APIClient?

    @Environment(\.theme) private var theme
    @State private var query: String = ""
    @State private var items: [KnowledgeItem] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            KnowledgePickerView(
                query: query,
                items: items,
                isLoading: isLoading,
                keyboardHeight: 0,
                onSelect: { item in
                    if !selectedItems.contains(where: { $0.id == item.id }) {
                        selectedItems.append(item)
                    }
                    isPresented = false
                },
                onDismiss: {
                    isPresented = false
                }
            )
            .navigationTitle("Attach Knowledge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .themed()
        .task {
            await loadItems()
        }
    }

    private func loadItems() async {
        guard let apiClient else { return }
        isLoading = true
        do {
            let fetched = try await apiClient.getKnowledgeItems()
            items = fetched
        } catch {
            // silently fail — empty list shown
        }
        isLoading = false
    }
}
