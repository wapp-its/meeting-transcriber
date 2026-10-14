import SwiftUI

/// The Hugging Face model browser: a search over WhisperKit repositories and,
/// for a chosen one, its loadable variants with their download size, its
/// license, a gated notice and a link to its model card.
///
/// - **It changes no setting.** "Use" and "Cancel" report through `onUse` and
///   `onCancel`; the presenter decides what a pick writes and closes the sheet.
/// - **All state is on `search`**, never in `@State`, so a test that drives a
///   control reads the result on the object the control wrote to.
/// - **Closing the window stops pending work** through `search.cancel()` in
///   `onDisappear`, whichever way the window closes.
struct HuggingFaceModelBrowserView: View {
    @Bindable var search: HuggingFaceModelSearch
    let onUse: (HuggingFaceModelVariant, HuggingFaceRepositoryListing) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find a WhisperKit model on Hugging Face")
                .font(.headline)
            TextField("Search", text: $search.query, prompt: Text("Model name, at least 2 characters"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(A11yID.huggingFaceSearchField)
            statusLine
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(A11yID.huggingFaceCancelButton)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 440)
        .onDisappear { search.cancel() }
    }

    /// Progress while a search or listing runs, and the model's one-line message.
    private var statusLine: some View {
        HStack(spacing: 6) {
            if search.isSearching || search.isListing {
                ProgressView()
                    .controlSize(.small)
            }
            if let message = search.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let listing = search.listing {
            listingDetails(listing)
        } else {
            List(search.results) { summary in
                Button { search.choose(summary) } label: { resultRow(summary) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(A11yID.huggingFaceResult(summary.id))
            }
        }
    }

    private func resultRow(_ summary: HuggingFaceModelSummary) -> some View {
        HStack {
            Text(summary.id)
            Spacer()
            if let downloads = Self.downloadsText(summary.downloads) {
                Text(downloads)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func listingDetails(_ listing: HuggingFaceRepositoryListing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Back to results") { search.backToResults() }
                .accessibilityIdentifier(A11yID.huggingFaceBackButton)
            Text(listing.id)
                .font(.title3)
            Text(listing.license?.displayText ?? "License not stated — check the model card")
            if listing.isGated {
                Text("Gated: accept the terms on huggingface.co and add your Hugging Face token in Settings.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Model card on Hugging Face", destination: listing.modelCardURL)
                .accessibilityIdentifier(A11yID.huggingFaceModelCardLink)
            variantList(listing)
        }
    }

    @ViewBuilder
    private func variantList(_ listing: HuggingFaceRepositoryListing) -> some View {
        if listing.variants.isEmpty {
            Text("No variant this app can load. The model files have to sit in one folder per variant.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            List(listing.variants) { variant in
                HStack {
                    VStack(alignment: .leading) {
                        Text(variant.name)
                        Text(Self.sizeText(variant.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use") { onUse(variant, listing) }
                        .accessibilityIdentifier(A11yID.huggingFaceUseVariant(variant.name))
                }
            }
        }
    }

    /// Nil when the Hub left the count out, so the row shows none rather than a zero.
    private static func downloadsText(_ downloads: Int?) -> String? {
        guard let downloads else { return nil }
        return downloads == 1 ? "1 download" : "\(downloads.formatted()) downloads"
    }

    private static func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "size unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
