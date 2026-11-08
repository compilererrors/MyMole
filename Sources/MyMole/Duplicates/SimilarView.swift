import ImageIO
import StorageKit
import SwiftUI

/// Identical files or pictures that look alike: the Duplicates pane shows
/// one or the other, switched in its toolbar.
enum DuplicatesShow: String, CaseIterable, Identifiable {
    case identical, similar
    static let key = "duplicates.show"
    var id: String { rawValue }
    var title: String { self == .identical ? String(localized: "Identical Files") : String(localized: "Similar Photos") }
}

struct DuplicatesPane: View {
    let duplicates: DuplicatesModel
    let similar: SimilarModel
    @AppStorage(DuplicatesShow.key) private var show: DuplicatesShow = .identical

    var body: some View {
        switch show {
        case .identical: DuplicatesView(model: duplicates)
        case .similar: SimilarView(model: similar)
        }
    }
}

/// The switch between the two, in the toolbar of either.
struct DuplicatesShowPicker: ToolbarContent {
    @AppStorage(DuplicatesShow.key) private var show: DuplicatesShow = .identical

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $show) {
                ForEach(DuplicatesShow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Pictures that look alike: groups on the left, the pictures of the
/// selected groups on the right. The best of each group, the one with the
/// most pixels, is listed first, and one picture always stays.
struct SimilarView: View {
    @Bindable var model: SimilarModel
    @State private var confirming = false
    @SceneStorage("similar.filter") private var query = ""
    @State private var filtered = OffMain<[SimilarGroup]>([])

    private struct FilterKey: Equatable {
        let groups: [SimilarGroup]
        let query: String
    }

    nonisolated static func matching(_ groups: [SimilarGroup], query: String) -> [SimilarGroup] {
        let search = TextQuery(query)
        return search.isEmpty ? groups : groups.filter { group in
            group.images.contains { search.matches($0.name, $0.folder) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !model.groups.isEmpty {
                        DSListHeading("Photo groups", detail: "Select a group to compare its pictures.")
                    }
                    groups
                }.frame(minWidth: 300, maxWidth: .infinity)
                if !model.groups.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        DSListHeading("Pictures in selected groups", detail: "Inspect the pictures before choosing any for removal.")
                        pictures
                    }.frame(minWidth: 320, maxWidth: .infinity)
                }
            }
        }
        .dsBottom(showing: !model.chosen.isEmpty) {
            DSActionBar {
                DSText(
                    String(localized: "\(model.chosen.count.formatted()) chosen · \(ByteSize.format(model.chosenBytes))")
                        + DSFilterField.hiddenNote(chosen: model.chosen, shown: Set(filtered.value.flatMap { $0.images.map(\.path) })),
                    .lead)
            } trailing: {
                Button("Unchoose All") { model.chosen = [] }
                Button("Move to Trash…") { confirming = true }
                    .primaryAction()
                    .disabled(model.trashBlocker != nil)
                    .help(model.trashBlocker ?? String(localized: "Move the chosen pictures to the Trash"))
            }
        } toast: {
            if let n = model.notice {
                DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
            }
        }
        .paneToolbar("Duplicates", subtitle: "Pictures that look alike in your own folders") {
            DuplicatesShowPicker()
            ToolbarItem(placement: .primaryAction) {
                if model.scanning {
                    Button {
                        model.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop searching; the last complete result stays")
                } else {
                    Button {
                        model.scan()
                    } label: {
                        Label("Search Again", systemImage: "arrow.clockwise")
                    }
                    .help("Look for pictures that look alike again")
                }
            }
        }
        .actionConfirmation(
            String(localized: "Move \(model.chosen.count.formatted()) picture\(model.chosen.count == 1 ? "" : "s") to the Trash?"),
            isPresented: $confirming,
            message: String(
                localized:
                    "\(ByteSize.format(model.chosenBytes)). One picture of each group stays where it is. Look at them first: pictures that look alike aren't always copies. You can undo right after."
            )
        ) { model.trashChosen() }
        .task(id: FilterKey(groups: model.groups, query: query)) {
            let (groups, query) = (model.groups, query)
            await filtered.update(count: groups.reduce(0) { $0 + $1.images.count }) { Self.matching(groups, query: query) }
        }
    }

    private var header: some View {
        DSPaneHeader {
            DSMetric(
                ByteSize.format(model.spareBytes),
                "in \(model.groups.count.formatted()) group\(model.groups.count == 1 ? "" : "s") of pictures that look alike")
        } actions: {
            DSControlField("Filter photo groups") {
                DSFilterField(String(localized: "Filter by name or folder"), text: $query).frame(width: 280)
            }
            DSControlField("Choose pictures for removal") {
                Button("Choose All but the Best") {
                    let shown = Set(filtered.value.map(\.id))
                    let selected = model.selection.intersection(shown)
                    model.chooseAllButBest(in: selected.isEmpty ? shown : selected)
                }
                .disabled(filtered.value.isEmpty || filtered.working)
                .help(
                    "In the selected visible groups, or all visible groups when none is selected: every picture but the one with the most pixels"
                )
                .fixedSize()
            }
        } strip: {
            if model.scanning {
                DSRunningCapsule(text: String(localized: "Looking at pictures"), since: model.startedAt)
                if let s = model.step, s.total > 0 { DSScanProgress(fraction: Double(s.done) / Double(s.total)) }
                DSStripButton("Stop", symbol: "stop.fill") { model.stop() }
            } else if let at = model.scannedAt {
                DSCapsule("Searched \(at.formatted(.relative(presentation: .named)))", symbol: "checkmark", tint: .green)
            }
            DSCapsule("Pictures in Pictures, Desktop, Documents and Downloads", symbol: "photo")
                .help(
                    "The Photos library is left alone: remove pictures there in Photos. Nothing leaves the Mac; pictures are compared by a small fingerprint made here."
                )
            if model.truncated {
                DSCapsule(
                    "Only the first \(SimilarImages.limit.formatted()) pictures were looked at", symbol: "exclamationmark.triangle.fill",
                    tint: .orange)
            }
            if !model.unreadable.isEmpty {
                DSCapsule(
                    "\(model.unreadable.count) folder\(model.unreadable.count == 1 ? "" : "s") couldn't be read",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(model.unreadable.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
            }
        }
        .contextualControls(
            "Review similar photos",
            detail:
                "Choosing keeps the picture with the most pixels in each selected visible group, or all visible groups if none is selected. Review the pictures before removal."
        )
    }

    private var groups: some View {
        FileTable(
            rows: filtered.value.map { g in
                FileRow(
                    id: g.id, name: g.best?.name ?? "", size: g.best?.bytes ?? 0, freeable: g.spare, items: g.images.count, symbol: "photo.on.rectangle",
                    subtitle: String(localized: "\(g.images.count) pictures"))
            },
            columns: [.name, .freeable, .items],
            titles: [.items: String(localized: "Pictures")],
            autosave: "similar.groups",
            defaultSort: .freeable,
            selection: $model.selection,
            marks: nil,
            onOpen: { ids in FileActions.reveal(model.groups.filter { ids.contains($0.id) }.flatMap { $0.images.map(\.path) }) })
        .overlay {
            if !model.groups.isEmpty, filtered.value.isEmpty, !filtered.working {
                ContentUnavailableView.search(text: query)
            } else if model.groups.isEmpty {
                if model.scanning {
                    DSLoading("Looking at pictures…")
                } else if model.scannedAt != nil, !model.unreadable.isEmpty {
                    DSIncompleteEmpty(what: String(localized: "Similar photos"), unreadable: model.unreadable) { model.scan() }
                } else if model.scannedAt != nil {
                    ContentUnavailableView(
                        String(localized: "No Pictures Look Alike"), systemImage: "photo.on.rectangle",
                        description: Text("No two pictures of 50 KB or more in the searched folders look the same."))
                } else {
                    CenterCard(symbol: "photo.on.rectangle", title: "Similar Photos", subtitle: "Finds bursts, resized and re-saved copies of the same picture in Pictures, Desktop, Documents and Downloads. Pictures are only read.") {
                        Button("Start Search") { model.scan() }.primaryAction()
                    }
                }
            }
        }
    }

    /// The format and how close the picture is to the best one of its group.
    static func likeness(_ i: SimilarImage, in g: SimilarGroup) -> String {
        let format = (i.name as NSString).pathExtension.uppercased()
        let d = g.difference(i)
        let close: String = if i.path == g.best?.path {
            String(localized: "the best of \(g.images.count)")
        } else if d == 0 {
            String(localized: "looks the same as the best")
        } else if d <= SimilarImages.threshold {
            String(localized: "\(d) of 64 points differ from the best")
        } else {
            String(localized: "alike another picture here, not the best itself")
        }
        return format.isEmpty ? close : format + " · " + close
    }

    private var pictures: some View {
        VStack(spacing: 0) {
            if let g = model.shownGroups.first {
                SimilarStrip(group: g)
                Divider()
            }
            pictureTable
        }
    }

    private var pictureTable: some View {
        FileTable(
            rows: model.shownGroups.flatMap { g in
                g.images.map { i in
                    var r = FileRow(
                        id: i.path, name: i.name, size: i.bytes, modified: i.modified, kind: "\(i.width) × \(i.height)",
                        location: i.folder, symbol: "photo", subtitle: Self.likeness(i, in: g))
                    if i.path == g.best?.path {
                        r.badge = String(localized: "Best")
                        r.badgeTint = .systemGreen
                        r.badgeHelp = String(localized: "Kept as the best: the most pixels, then the biggest file, then the newest")
                    } else if g.isLinkedOnly(i) {
                        r.badge = String(localized: "Linked")
                        r.badgeTint = .systemOrange
                        r.badgeHelp = String(localized: "Not alike the best picture itself, only alike another picture of the group. Look at it closely.")
                    }
                    model.keep.mark(&r)
                    return r
                }
            },
            columns: [.name, .kind, .size, .modified, .location],
            titles: [.kind: String(localized: "Pixels")],
            autosave: "similar.pictures",
            defaultSort: .name,
            selection: $model.fileSelection,
            marks: model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            menu: { ids in
                [
                    .quickLook,
                    .action(String(localized: "Show in Finder")) { FileActions.reveal(ids) },
                    .divider,
                    ids.contains(where: { !model.chosen.contains($0) })
                        ? .action(String(localized: "Choose for Removal")) { model.choose(ids) }
                        : .action(String(localized: "Unchoose")) { model.chosen.subtract(ids) },
                    model.keep.menuEntry(ids, keep: model.keepAlways, stop: model.stopKeeping),
                ]
            })
        .overlay {
            if model.shownGroups.isEmpty, !model.groups.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Group Selected"), systemImage: "photo.on.rectangle",
                    description: Text("Select a group on the left to see its pictures."))
            }
        }
    }
}

/// The pictures of one group side by side, the best first, small enough
/// to compare at a glance; each with its pixels, size and how close it is.
private struct SimilarStrip: View {
    let group: SimilarGroup

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                ForEach(group.images.prefix(12)) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Thumbnail(path: i.path)
                            .frame(width: 150, height: 110)
                            .overlay(alignment: .topLeading) {
                                if i.path == group.best?.path {
                                    Text("Best").font(.caption2.bold()).padding(3).background(.green, in: .rect(cornerRadius: 3)).foregroundStyle(.white).padding(4)
                                }
                            }
                        DSName(i.name, .metadata, lines: 1)
                        DSText("\(i.width) × \(i.height) · \(ByteSize.format(i.bytes))", .metadata, lines: 1)
                        DSText(SimilarView.likeness(i, in: group), .metadata, lines: 2)
                    }
                    .frame(width: 150)
                    .onTapGesture(count: 2) { FileActions.reveal([i.path]) }
                }
            }
            .padding(DS.Space.md)
        }
        .frame(height: 200)
    }
}

/// A small picture of the file, drawn off the main thread.
private struct Thumbnail: View {
    let path: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .task(id: path) {
            let path = path
            image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            }.value
        }
    }
}
