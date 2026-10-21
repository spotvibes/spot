import SwiftUI
import Kingfisher

struct CachedThumbnailImage: View {
    let cacheKey: String
    let remoteURL: URL?
    var contentMode: SwiftUI.ContentMode = .fill
    var cornerRadius: CGFloat = 0

    @State private var progress: Double?
    @State private var failed = false

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private var content: some View {
        if failed || remoteURL == nil {
            failurePlaceholder
        } else if let remoteURL {
            KFImage(source: remoteURL.isFileURL
                    ? .provider(LocalFileImageDataProvider(fileURL: remoteURL, cacheKey: cacheKey))
                    : remoteURL.convertToSource(overrideCacheKey: cacheKey))
                .placeholder { downloadingPlaceholder }
                .onProgress { received, total in
                    guard total > 0 else { return }
                    progress = Double(received) / Double(total)
                }
                .onFailure { _ in failed = true }
                .cacheOriginalImage()
                .resizable()
                .aspectRatio(contentMode: contentMode)
        }
    }

    private var downloadingPlaceholder: some View {
        ZStack {
            Rectangle().foregroundColor(Color(.secondarySystemBackground))
            VStack(spacing: 4) {
                ProgressView()
                if let progress, progress > 0.02 {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var failurePlaceholder: some View {
        ZStack {
            Rectangle().foregroundColor(Color(.secondarySystemBackground))
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.secondary)
        }
    }
}
