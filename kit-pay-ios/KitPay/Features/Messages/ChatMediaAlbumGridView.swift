import SwiftUI
import UIKit

/// In-bubble grid for a `ChatMediaAlbum` (2+ consecutive captionless photos/videos).
///
/// The grid only shows thumbnails/placeholders from locally available plaintext — it never
/// triggers downloads itself. Every cell performs its own fresh local-only identity resolution
/// (account, current persisted row, full projection) and nothing — including an in-memory
/// thumbnail-cache hit — is shown for a row that does not currently resolve. Tapping any cell
/// reports the item so the presenter can open the gallery (which does load on demand).
struct ChatMediaAlbumGridView: View {
    let album: ChatMediaAlbum
    let isOutgoing: Bool
    /// Tap on any cell (an item from `album.items`).
    let onTap: (ChatMediaAlbumItem) -> Void
    /// Long-press menu for one cell. Album members are ordinary messages: each can be answered,
    /// reacted to, forwarded, and deleted on its own, exactly as it could outside an album.
    var cellMenu: ((ChatMediaAlbumItem) -> AnyView)? = nil
    /// Anything that belongs on top of one cell — today, that cell's own reaction chips.
    var cellBadge: ((ChatMediaAlbumItem) -> AnyView)? = nil

    /// Message IDs whose cells resolved a clearly portrait image; drives the tall two-up
    /// variant. Populated by the cells themselves after their identity-gated load, so layout
    /// never reads bytes or caches directly.
    @State private var portraitCells: Set<UUID> = []

    private enum Metrics {
        static let gap: CGFloat = 2
        static let smallEdge: CGFloat = 84
        static let squareEdge: CGFloat = 126
        static let portraitHeight: CGFloat = 168
        static let featuredEdge: CGFloat = 168
        static let outerCornerRadius: CGFloat = 17
        static let cellCornerRadius: CGFloat = 6
        static let visibleGridCells = 4
        /// Two-up cells go tall only when both photos are clearly portrait.
        static let portraitAspectThreshold: CGFloat = 0.85
    }

    var body: some View {
        layout
            .clipShape(
                RoundedRectangle(cornerRadius: Metrics.outerCornerRadius, style: .continuous)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Album of \(album.items.count) media items")
    }

    @ViewBuilder
    private var layout: some View {
        switch album.items.count {
        case 2:
            twoUp
        case 3:
            threeUp
        default:
            gridOfFour
        }
    }

    // MARK: 2 items: side-by-side squares; tall variant when both are portrait.

    private var twoUp: some View {
        let height = bothTwoUpItemsArePortrait ? Metrics.portraitHeight : Metrics.squareEdge
        return HStack(spacing: Metrics.gap) {
            ForEach(Array(album.items.enumerated()), id: \.element.messageID) { index, item in
                cell(
                    item,
                    index: index,
                    size: CGSize(width: Metrics.squareEdge, height: height)
                )
            }
        }
    }

    /// Aspect facts come from the cells' own identity-gated loads; a cell that has not resolved
    /// (or a video, whose bytes do not decode as an image) is assumed square.
    private var bothTwoUpItemsArePortrait: Bool {
        album.items.allSatisfy { portraitCells.contains($0.messageID) }
    }

    // MARK: 3 items: featured left + two stacked right.

    private var threeUp: some View {
        HStack(alignment: .top, spacing: Metrics.gap) {
            cell(
                album.items[0],
                index: 0,
                size: CGSize(width: Metrics.featuredEdge, height: Metrics.featuredEdge)
            )
            VStack(spacing: Metrics.gap) {
                cell(
                    album.items[1],
                    index: 1,
                    size: CGSize(width: Metrics.smallEdge, height: Metrics.smallEdge)
                )
                cell(
                    album.items[2],
                    index: 2,
                    size: CGSize(width: Metrics.smallEdge, height: Metrics.smallEdge)
                )
            }
        }
    }

    // MARK: 4+ items: 2x2, with a "+N" scrim on the 4th cell when more are hidden.

    private var gridOfFour: some View {
        let visible = Array(album.items.prefix(Metrics.visibleGridCells))
        let hiddenCount = album.items.count - Metrics.visibleGridCells
        return VStack(spacing: Metrics.gap) {
            HStack(spacing: Metrics.gap) {
                gridCell(visible, at: 0, hiddenCount: hiddenCount)
                gridCell(visible, at: 1, hiddenCount: hiddenCount)
            }
            HStack(spacing: Metrics.gap) {
                gridCell(visible, at: 2, hiddenCount: hiddenCount)
                gridCell(visible, at: 3, hiddenCount: hiddenCount)
            }
        }
    }

    @ViewBuilder
    private func gridCell(
        _ visible: [ChatMediaAlbumItem],
        at index: Int,
        hiddenCount: Int
    ) -> some View {
        if visible.indices.contains(index) {
            cell(
                visible[index],
                index: index,
                size: CGSize(width: Metrics.squareEdge, height: Metrics.squareEdge),
                overflowCount: index == Metrics.visibleGridCells - 1 ? max(0, hiddenCount) : 0
            )
        }
    }

    // MARK: Cells

    private func cell(
        _ item: ChatMediaAlbumItem,
        index: Int,
        size: CGSize,
        overflowCount: Int = 0
    ) -> some View {
        let content = ChatMediaAlbumGridCell(
            item: item,
            index: index,
            total: album.items.count,
            size: size,
            isOutgoing: isOutgoing,
            overflowCount: overflowCount,
            cornerRadius: Metrics.cellCornerRadius,
            onTap: { onTap(item) },
            badge: cellBadge?(item),
            onImageAspectRatio: { ratio in
                if ratio < Metrics.portraitAspectThreshold {
                    portraitCells.insert(item.messageID)
                } else {
                    portraitCells.remove(item.messageID)
                }
            }
        )
        // Attached only when there is a menu to show, so a thread that offers none keeps the
        // plain, undelayed tap.
        return Group {
            if let cellMenu {
                content.contextMenu { cellMenu(item) }
            } else {
                content
            }
        }
    }
}

// MARK: - One grid cell

private struct ChatMediaAlbumGridCell: View {
    let item: ChatMediaAlbumItem
    let index: Int
    let total: Int
    let size: CGSize
    let isOutgoing: Bool
    /// > 0 renders the "+N" scrim over this cell.
    let overflowCount: Int
    let cornerRadius: CGFloat
    let onTap: () -> Void
    /// Drawn over this cell's bottom-trailing corner; nil when there is nothing to show.
    var badge: AnyView? = nil
    /// Reports width/height of a resolved image so the parent can pick the tall two-up layout.
    var onImageAspectRatio: ((CGFloat) -> Void)? = nil

    @EnvironmentObject private var model: AppModel
    /// Bytes and facts of this cell's own fresh identity resolution (local-only; the grid never
    /// downloads). Every rendered pixel is gated on this being non-nil, so a thumbnail-cache hit
    /// can never outlive the persisted row it was cut from: the cache key is the row's
    /// content-bound storage key, and it is only consulted after that row re-resolves.
    @State private var loaded: SecureMediaLoadPolicy.LoadedItem?
    @State private var videoPoster: UIImage?
    @State private var fileImageThumbnail: UIImage?

    private var kind: KitChatMediaKind {
        KitChatMediaKind(mediaType: loaded?.mediaType ?? item.mediaType)
    }

    /// The requested thumbnail bucket is the cell's larger edge so scaledToFill never upscales.
    private var maxPixel: CGFloat { max(size.width, size.height) }

    private var thumbnail: UIImage? {
        // Identity gate: no current resolution, no pixels — not even already-cached ones.
        guard let loaded else { return nil }
        switch kind {
        case .video:
            return ChatMediaThumbnailStore.shared.cachedThumbnail(
                forKey: item.thumbnailKey,
                maxPixel: maxPixel
            ) ?? videoPoster
        case .image:
            if loaded.localFileURL != nil {
                return ChatMediaThumbnailStore.shared.cachedThumbnail(
                    forKey: item.thumbnailKey,
                    maxPixel: maxPixel
                ) ?? fileImageThumbnail
            }
            return ChatMediaThumbnailStore.shared.thumbnail(
                forKey: item.thumbnailKey,
                maxPixel: maxPixel,
                from: loaded.data
            )
        default:
            return nil
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    placeholder
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { overlays }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    badge.padding(4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .task(id: "\(item.messageID):\(item.thumbnailKey)") {
            // Fresh local-only identity resolution per (message, sealed-descriptor) key; a
            // replaced row changes the key and re-fires this. Failure clears any previously
            // shown pixels instead of serving stale state.
            if let localFile = await model.loadProtectedLocalMediaFile(
                messageID: item.messageID,
                conversationId: item.conversationID,
                itemIndex: nil
            ) {
                loaded = SecureMediaLoadPolicy.LoadedItem(localFile: localFile)
            } else {
                loaded = try? await model.loadSecureMediaItem(
                    messageID: item.messageID,
                    conversationId: item.conversationID,
                    itemIndex: nil,
                    allowsDownload: false
                )
            }
            guard let loaded else { return }
            switch KitChatMediaKind(mediaType: loaded.mediaType) {
            case .video:
                if let localFileURL = loaded.localFileURL {
                    videoPoster = await ChatMediaThumbnailStore.shared.videoThumbnail(
                        forKey: item.thumbnailKey,
                        maxPixel: maxPixel,
                        fromFileURL: localFileURL,
                        mediaType: loaded.mediaType,
                        expectedByteCount: loaded.byteCount,
                        protectedOriginalLease: loaded.localFileLease
                    )
                } else {
                    videoPoster = await ChatMediaThumbnailStore.shared.videoThumbnail(
                        forKey: item.thumbnailKey,
                        maxPixel: maxPixel,
                        from: loaded.data,
                        mediaType: loaded.mediaType,
                        expectedByteCount: loaded.byteCount
                    )
                }
            case .image:
                let thumb: UIImage?
                if let localFileURL = loaded.localFileURL {
                    thumb = ChatMediaThumbnailStore.shared.thumbnail(
                        forKey: item.thumbnailKey,
                        maxPixel: maxPixel,
                        fromFileURL: localFileURL
                    )
                    fileImageThumbnail = thumb
                } else {
                    thumb = ChatMediaThumbnailStore.shared.thumbnail(
                        forKey: item.thumbnailKey,
                        maxPixel: maxPixel,
                        from: loaded.data
                    )
                }
                if let thumb, thumb.size.height > 0 {
                    onImageAspectRatio?(thumb.size.width / thumb.size.height)
                }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var overlays: some View {
        if overflowCount > 0 {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.45))
            Text("+\(overflowCount)")
                .font(.title3.bold())
                .foregroundStyle(.white)
        } else if kind == .video, thumbnail != nil {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
        }
    }

    /// Cells without locally resolved bytes stay neutral: kind icon plus the plaintext byte size.
    private var placeholder: some View {
        VStack(spacing: 5) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 17, weight: .semibold))
            Text(ChatMediaBytes.label(item.plaintextByteSize))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isOutgoing ? .white : KitColor.secondaryText)
        .frame(width: size.width, height: size.height)
        .background(
            isOutgoing ? Color.white.opacity(0.09) : KitColor.paleGreen.opacity(0.24)
        )
    }

    private var accessibilityLabel: String {
        let noun = kind == .video ? "Video" : "Photo"
        if overflowCount > 0 {
            return "\(noun) \(index + 1) of \(total), plus \(overflowCount) more"
        }
        return "\(noun) \(index + 1) of \(total)"
    }
}
