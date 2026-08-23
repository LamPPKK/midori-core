import SwiftUI

@available(iOS 26.0, macOS 26.0, *)
struct FirefoxBookmarksLibraryView: View {
    @Bindable var model: FirefoxSyncViewModel
    let isPrivateContext: Bool
    let onOpenURL: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bookmarkToRename: XanhBookmarkRecord?
    @State private var bookmarkToDelete: XanhBookmarkRecord?
    @State private var replacementTitle = ""

    var body: some View {
        List {
            Section {
                Text(model.bookmarksStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Refresh bookmarks", systemImage: "arrow.clockwise") {
                    Task { await model.loadBookmarks() }
                }
            }

            Section("Bookmarks") {
                ForEach(model.bookmarks) { bookmark in
                    HStack(spacing: 10) {
                        Button {
                            guard let url = bookmark.openableURL,
                                  XanhPlacesPolicy.isAllowedWebURL(url) else { return }
                            onOpenURL(url)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bookmark.displayTitle)
                                    .lineLimit(1)
                                Text(bookmark.rawURL ?? "No URL")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(bookmark.openableURL == nil)

                        Menu("Bookmark actions", systemImage: "ellipsis.circle") {
                            Button("Rename", systemImage: "pencil") {
                                replacementTitle = bookmark.displayTitle
                                bookmarkToRename = bookmark
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                bookmarkToDelete = bookmark
                            }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(isPrivateContext)
                    }
                }
            }
        }
        .navigationTitle("Firefox Bookmarks")
        .task { await model.loadBookmarks() }
        .alert(
            "Rename bookmark",
            isPresented: Binding(
                get: { bookmarkToRename != nil },
                set: { if !$0 { bookmarkToRename = nil } }
            )
        ) {
            TextField("Bookmark title", text: $replacementTitle)
            Button("Cancel", role: .cancel) { bookmarkToRename = nil }
            Button("Rename") {
                guard let bookmark = bookmarkToRename else { return }
                bookmarkToRename = nil
                Task {
                    await model.renameBookmark(
                        bookmark,
                        title: replacementTitle,
                        isPrivate: isPrivateContext
                    )
                }
            }
        } message: {
            Text("The exact Firefox Places GUID is preserved.")
        }
        .confirmationDialog(
            "Delete this bookmark?",
            isPresented: Binding(
                get: { bookmarkToDelete != nil },
                set: { if !$0 { bookmarkToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete bookmark", role: .destructive) {
                guard let bookmark = bookmarkToDelete else { return }
                bookmarkToDelete = nil
                Task { await model.deleteBookmark(bookmark, isPrivate: isPrivateContext) }
            }
            Button("Cancel", role: .cancel) { bookmarkToDelete = nil }
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct FirefoxHistoryLibraryView: View {
    @Bindable var model: FirefoxSyncViewModel
    let isPrivateContext: Bool
    let onOpenURL: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var visitToDelete: XanhHistoryVisitRecord?

    var body: some View {
        List {
            Section {
                Text(model.historyStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Refresh history", systemImage: "arrow.clockwise") {
                    Task { await model.loadRecentHistory() }
                }
                Button("Clear all Sync history", systemImage: "trash", role: .destructive) {
                    model.isConfirmingClearHistory = true
                }
                .disabled(isPrivateContext)
            }

            Section("Recent visits") {
                ForEach(model.recentHistory) { visit in
                    HStack(spacing: 10) {
                        Button {
                            guard XanhPlacesPolicy.isAllowedWebURL(visit.url) else { return }
                            onOpenURL(visit.url)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(visit.displayTitle)
                                        .lineLimit(1)
                                    if visit.isRemote {
                                        Image(systemName: "icloud")
                                            .accessibilityLabel("Remote visit")
                                    }
                                }
                                Text(visit.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(lastVisitedLabel(visit.visitedAtEpochMillis))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button("Delete visit", systemImage: "trash", role: .destructive) {
                            visitToDelete = visit
                        }
                        .labelStyle(.iconOnly)
                        .disabled(isPrivateContext)
                    }
                }
            }
        }
        .navigationTitle("Firefox History")
        .task { await model.loadRecentHistory() }
        .confirmationDialog(
            "Delete this exact history visit?",
            isPresented: Binding(
                get: { visitToDelete != nil },
                set: { if !$0 { visitToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete visit", role: .destructive) {
                guard let visit = visitToDelete else { return }
                visitToDelete = nil
                Task { await model.deleteHistoryVisit(visit, isPrivate: isPrivateContext) }
            }
            Button("Cancel", role: .cancel) { visitToDelete = nil }
        }
        .confirmationDialog(
            "Clear all Firefox Sync history?",
            isPresented: $model.isConfirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                Task { await model.clearHistory(isPrivate: isPrivateContext) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes local Places history and publishes the deletion on the next Sync. Website cookies and cache are not cleared.")
        }
    }

    private func lastVisitedLabel(_ epochMillis: Int64) -> String {
        Date(timeIntervalSince1970: Double(epochMillis) / 1_000).formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
}
