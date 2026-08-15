import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SearchResultRow: View {
    let item: FileItem
    let model: ExplorerModel
    let store: ThumbnailStore
    let availableWidth: CGFloat

    @State private var thumbnail: NSImage?
    @State private var hoveringMatches = false

    static let rowPadding: CGFloat = 8
    private static let columnSpacing: CGFloat = 16
    private static let posterFraction = 0.3
    private static let posterRange: ClosedRange<CGFloat> = 132...240
    private static let detailsRange: ClosedRange<CGFloat> = 120...300
    private static let matchesHeight: CGFloat = 116
    private static let restingOpacity = 0.45

    private var posterWidth: CGFloat {
        let share = (availableWidth * Self.posterFraction).rounded()
        return min(max(share, Self.posterRange.lowerBound), Self.posterRange.upperBound)
    }

    private var posterHeight: CGFloat {
        (posterWidth * 9 / 16).rounded()
    }

    private var moments: [MatchMoment] {
        model.moments[item.url] ?? []
    }

    private var isSelected: Bool {
        model.selection == item.id
    }

    private var isVideo: Bool {
        item.contentType?.conforms(to: .movie) ?? false
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            poster
            details
            matches
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Self.rowPadding)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in handleClick() }
        )
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { model.revealInFinder(item) }
        }
        .task(id: item) {
            if let cached = store.cachedThumbnail(for: item, at: nil) {
                thumbnail = cached
                return
            }
            let image = await store.thumbnail(for: item, at: nil)
            guard !Task.isCancelled, let image else {
                return
            }
            thumbnail = image
        }
    }

    private var poster: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .opacity(0.7)
            }
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(radius: 2)
            }
        }
        .frame(width: posterWidth, height: posterHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(AppFont.title)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(metadata)
                .font(AppFont.detail)
                .foregroundStyle(.supporting)
                .lineLimit(1)
            Label(model.location(of: item), systemImage: "folder")
                .font(AppFont.detail)
                .foregroundStyle(.supporting)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(
            minWidth: Self.detailsRange.lowerBound,
            idealWidth: 260,
            maxWidth: Self.detailsRange.upperBound,
            alignment: .leading
        )
    }

    private var matches: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(heading)
                .font(AppFont.caption)
                .foregroundStyle(.supporting)
            ScrollView(.horizontal) {
                if moments.isEmpty {
                    stillScore
                } else {
                    momentStrip
                }
            }
            .scrollIndicators(.never)
            .frame(height: Self.matchesHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(hoveringMatches ? 1 : Self.restingOpacity)
        .animation(.easeOut(duration: 0.12), value: hoveringMatches)
        .onHover { hoveringMatches = $0 }
    }

    private var heading: String {
        guard !moments.isEmpty else {
            return "Match"
        }
        return moments.count == 1 ? "Matching moment" : "Matching moments"
    }

    private var stillScore: some View {
        VStack(alignment: .leading, spacing: 4) {
            MatchTile {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(white: 0.35))
                }
            }
            if let score = model.scores[item.url] {
                MarkedValue(mark: .similarity, value: SearchResultRow.formatted(score))
            } else {
                Text("Filename match")
                    .font(AppFont.caption)
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: MatchColumn.width, alignment: .leading)
    }

    private var momentStrip: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(moments, id: \.self) { moment in
                MomentChip(item: item, moment: moment, store: store)
            }
        }
        .padding(.bottom, 2)
    }

    private func handleClick() {
        if let event = NSApp.currentEvent, event.clickCount >= 2 {
            model.activate(item)
        } else {
            model.select(item)
        }
    }

    private func open() {
        model.select(item)
        model.openSelection()
    }

    private var metadata: String {
        var parts = [item.kind]
        if item.size >= 0 {
            parts.append(item.formattedSize)
        }
        parts.append(item.formattedModificationDate)
        return parts.joined(separator: " · ")
    }

    static func formatted(_ score: Float) -> String {
        String(format: "%.3f", score)
    }
}

private struct MomentChip: View {
    let item: FileItem
    let moment: MatchMoment
    let store: ThumbnailStore

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MatchTile {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            MarkedValue(mark: .timeRange, value: TimeRangeLabel.formatted(moment.range))
            MarkedValue(mark: .similarity, value: SearchResultRow.formatted(moment.score))
        }
        .frame(width: MatchColumn.width, alignment: .leading)
        .task(id: moment) {
            let time = moment.range.lowerBound
            if let cached = store.cachedThumbnail(for: item, at: time) {
                thumbnail = cached
                return
            }
            let image = await store.thumbnail(for: item, at: time)
            guard !Task.isCancelled else {
                return
            }
            thumbnail = image
        }
    }
}

private enum MatchColumn {
    static let width: CGFloat = 120
    static let tileHeight: CGFloat = 68
}

private struct MatchTile<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(white: 0.72))
            content
        }
        .frame(width: MatchColumn.width, height: MatchColumn.tileHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct MarkedValue: View {
    enum Mark {
        case timeRange
        case similarity
    }

    let mark: Mark
    let value: String

    private static let markSide: CGFloat = 16
    private static let markSpacing: CGFloat = 5

    var body: some View {
        HStack(spacing: Self.markSpacing) {
            markLabel
                .foregroundStyle(.supporting)
                .frame(width: Self.markSide, height: Self.markSide)
            Text(value)
                .font(AppFont.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var markLabel: some View {
        switch mark {
        case .timeRange:
            Image(systemName: "clock")
                .font(AppFont.caption)
                .accessibilityLabel("Time range")
        case .similarity:
            Text("\u{2248}")
                .font(AppFont.title)
                .accessibilityLabel("Cosine similarity")
        }
    }
}
