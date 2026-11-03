import StorageKit
import SwiftUI
import SystemKit

struct DashboardView: View {
    let app: AppModel

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    var body: some View {
        DSPage(width: .full) {
                // The ring and the cards beside it share one height, top and bottom.
                HStack(alignment: .top, spacing: DS.Space.lg) {
                    diskRing
                    VStack(spacing: Theme.gap) {
                        HStack(spacing: Theme.gap) {
                            StatTile(caption: "Health") {
                                Metric(app.status.map { String($0.health.score) } ?? "—")
                                DSText(app.status?.health.summary ?? " ", .metadata)
                            }
                            StatTile(caption: "Memory") {
                                let pct = app.status?.memory?.usedPercent ?? 0
                                Metric(app.status == nil ? "—" : "\(Int(pct))%")
                                UsageBar(fraction: pct / 100)
                            }
                            StatTile(caption: "Last cleanup") {
                                if let last = app.lastCleanup {
                                    Metric(ByteSize.format(last.freedBytes))
                                    Text(last.date.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Metric("Never")
                                    Text("Nothing cleaned yet").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Smart Scan").font(.headline)
                                Text("Previews every module at once. Nothing is deleted until you confirm.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                app.scanAll()
                                app.pane = .clean
                            } label: {
                                Label("Scan", systemImage: "sparkles")
                            }
                            .primaryAction()
                        }
                        .frame(maxHeight: .infinity)
                        .card()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                DSSectionHeader("Tools")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.gap)], spacing: Theme.gap) {
                    quick(.clean, "Caches, logs and leftovers")
                    quick(.uninstall, "Apps and everything they leave")
                    quick(.optimize, "Refresh system databases")
                    quick(.projects, "node_modules, target, .build…")
                    quick(.installer, "Forgotten .dmg and .pkg files")
                    quick(.diskMap, "See where the space went")
                }
                }
        }
        .paneToolbar(greeting, subtitle: "Here's how your Mac is doing")
        .task {
            async let s: Void = app.refreshStatus()
            async let h: Void = app.refreshHistory()
            _ = await (s, h)
        }
    }

    private var diskRing: some View {
        let disk = app.status?.startupVolume
        let frac = (disk?.usedPercent ?? 0) / 100
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: frac)
                .stroke(Theme.load(frac * 100), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: frac)
            VStack(spacing: 2) {
                Metric(disk == nil ? "—" : "\(Int(disk!.usedPercent))%")
                Text("disk used").font(.caption).foregroundStyle(.secondary)
                if let d = disk {
                    Text("\(ByteSize.format(d.used)) of \(ByteSize.format(d.total))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 170, height: 170)
        .padding(14)
        .frame(maxHeight: .infinity)
        .card(padding: 8)
        .frame(width: 210)
    }

    private func quick(_ pane: Pane, _ text: String) -> some View {
        Button {
            app.pane = pane
        } label: {
            HStack(spacing: 12) {
                Image(systemName: pane.symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    DSText(pane.title, .heading)
                    // One line, so every tile in a row is the same height.
                    DSText(text, .metadata, lines: 1)
                }
                .layoutPriority(1)
                Spacer()
                if let badge = app.badge(for: pane) {
                    Text(badge).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .card(padding: 14)
            .contentShape(.rect(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
    }
}
