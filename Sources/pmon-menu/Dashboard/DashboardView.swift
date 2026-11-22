import PmonCore
import SwiftUI

/// The window's content: a sidebar of tabs and the selected tab.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<DashboardTab?>(get: { model.tab }, set: { if let t = $0 { model.tab = t } })) {
                ForEach(DashboardTab.allCases) { t in
                    Label(t.title, systemImage: t.symbol).tag(t)
                        .badge(t == .findings ? model.activeFindings : 0)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            VStack(spacing: 0) {
                StatusBanner(model: model)
                content
            }
            .navigationTitle(model.tab.title)
            .toolbar { toolbar }
        }
    }

    @ViewBuilder private var content: some View {
        if model.noDatabase {
            Placeholder(symbol: "externaldrive.badge.questionmark", title: "No data yet",
                        text: "pmon has not recorded anything on this Mac. Start the daemon with `pmon install`.")
        } else {
            switch model.tab {
            case .overview: OverviewTab(model: model)
            case .live: LiveTab(model: model)
            case .slowdowns: SlowdownsTab(model: model)
            case .findings: FindingsTab(model: model)
            case .apps: AppsTab(model: model)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.tab == .live {
                Picker("Window", selection: $model.liveMinutes) {
                    Text("5 min").tag(5); Text("15 min").tag(15); Text("1 hour").tag(60)
                }
                .pickerStyle(.segmented)
                .help("How much of the recent past the live charts show")
            } else if model.tab != .findings {
                Picker("Range", selection: $model.range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Period the charts and lists cover")
            }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Read the database again")
                .keyboardShortcut("r")
        }
    }
}

/// Says when the daemon is not recording, so stale charts are not mistaken for live ones.
struct StatusBanner: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        if let error = model.error {
            banner("xmark.octagon.fill", Palette.critical, "Could not read the database: \(error)")
        } else if !model.noDatabase, model.stale {
            let age = model.sampleAge.map { "last sample \(Fmt.duration(Int64($0 * 1000))) ago" } ?? "no samples yet"
            banner("pause.circle.fill", Palette.warning, "The daemon is not recording (\(age)). `pmon status` shows why.")
        }
    }

    private func banner(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(color.opacity(0.12))
    }
}

struct Placeholder: View {
    var symbol: String, title: String, text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(.init(text)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared bits

func bottleneck(_ dim: String) -> String { Fmt.dimensionNames[dim] ?? dim }

func when(_ e: Episode) -> String { "\(Fmt.day(e.start)) \(Fmt.clock(e.start))" }

func length(_ e: Episode, now: Int64 = msNow()) -> String { e.end == nil ? "ongoing" : Fmt.duration((e.end ?? now) - e.start) }

/// Slowdowns as bands for a time chart.
func bands(_ list: [Episode]) -> [Band] {
    let now = msNow()
    return list.map { Band(id: $0.id, start: date($0.start), end: date(max($0.end ?? now, $0.start + 1000))) }
}

/// A small coloured capsule naming a dimension; the word carries the meaning, the colour identity.
struct DimensionTag: View {
    var dim: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Palette.dimension[dim] ?? .gray).frame(width: 7, height: 7)
            Text(Palette.dimensionLabel[dim] ?? dim).font(.caption)
        }
    }
}

struct SeverityTag: View {
    var severity: Int, open: Bool
    var body: some View {
        // The icon carries the colour; the word stays in text colour so it reads on any background.
        HStack(spacing: 4) {
            if !open {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("Resolved")
            } else if severity >= 2 {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.critical)
                Text("Serious")
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                Text("Warning")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Label/value rows for detail panes.
struct Facts: View {
    var rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).font(.callout).foregroundStyle(.secondary)
                    Text(r.1).font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}
