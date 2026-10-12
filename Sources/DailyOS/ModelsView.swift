import DailyOSApp
import DailyOSCore
import SwiftUI

struct ModelsView: View {
    @ObservedObject var viewModel: ModelsViewModel
    var onChooseCustomFile: () -> Void
    var onRevealModelDirectory: () -> Void
    var onDeleteRequiringConfirmation: (ModelCatalogEntry) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Headers only earn their space when there are two groups
                // to tell apart.
                let showsHeaders = !viewModel.downloadedEntries.isEmpty && !viewModel.availableEntries.isEmpty
                if !viewModel.downloadedEntries.isEmpty {
                    catalogSection(title: showsHeaders ? "Local Models" : nil, entries: viewModel.downloadedEntries)
                }
                if !viewModel.availableEntries.isEmpty {
                    catalogSection(title: showsHeaders ? "Available to Download" : nil, entries: viewModel.availableEntries)
                }

                HStack {
                    Spacer()
                    Button("Choose Custom File…", action: onChooseCustomFile)
                    Button("Open Models Folder", action: onRevealModelDirectory)
                }
            }
            .padding(20)
        }
        // Picks up a `.gguf` dropped into the folder from Finder.
        .onAppear { viewModel.refresh() }
    }

    @ViewBuilder
    private func catalogSection(title: String?, entries: [ModelCatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                ModelCardView(entry: entry, viewModel: viewModel, onDeleteRequiringConfirmation: {
                    onDeleteRequiringConfirmation(entry)
                })
            }
        }
    }
}

private struct ModelCardView: View {
    let entry: ModelCatalogEntry
    @ObservedObject var viewModel: ModelsViewModel
    var onDeleteRequiringConfirmation: () -> Void

    private var isDownloaded: Bool {
        viewModel.downloadedEntries.contains(entry)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.displayName).font(.headline)
                    if !entry.quantization.isEmpty {
                        Text(entry.quantization).font(.caption).foregroundStyle(.secondary)
                    }
                    if viewModel.isActive(entry) {
                        // No second color meaning here (CONTEXT.md: Semantic
                        // monochromatism) — a plain checkmark carries "active"
                        // without a colored badge.
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
                if case .downloading(let fraction)? = viewModel.progress[entry.id]?.state {
                    ProgressView(value: fraction).frame(maxWidth: 220)
                } else if case .failed(let message)? = viewModel.progress[entry.id]?.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            actions
        }
        .padding(12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        // The active model's card is tinted gray, never colored (CONTEXT.md,
        // Semantic monochromatism).
        .background(.primary.opacity(viewModel.isActive(entry) ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }

    @ViewBuilder
    private var actions: some View {
        if isDownloaded {
            if !viewModel.isActive(entry) {
                Button("Use") { Task { await viewModel.select(entry) } }
            }
            Button {
                if viewModel.requiresConfirmationBeforeDeleting(entry) {
                    onDeleteRequiringConfirmation()
                } else {
                    try? viewModel.delete(entry)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        } else if case .downloading? = viewModel.progress[entry.id]?.state {
            Button("Cancel") { viewModel.cancelDownload(entry) }
        } else {
            Button("Download") { viewModel.download(entry) }
        }
    }
}
