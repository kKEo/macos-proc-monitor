import AppKit
import PmonCore
import SwiftUI

// The three list-and-detail tabs: slowdowns, findings and applications.

/// A list on the left, the selected item on the right.
struct MasterDetail<List: View, Detail: View>: View {
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail
    var body: some View {
        HSplitView {
            list.frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
            detail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Slowdowns

struct SlowdownsTab: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        let shown = model.episodes.filter { model.showAway || $0.episode.userPresent || $0.episode.end == nil }
        MasterDetail {
            VStack(spacing: 0) {
                HStack {
                    Text("\(shown.count) slowdown\(shown.count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Include while away", isOn: $model.showAway).toggleStyle(.checkbox).font(.callout)
                }
                .padding(8)
                List(shown, selection: $model.selectedEpisode) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(when(row.episode)).monospacedDigit()
                            Spacer()
                            Text("peak \(row.episode.peak)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack(spacing: 8) {
                            DimensionTag(dim: row.episode.dominant)
                            Text(length(row.episode)).font(.caption).foregroundStyle(.secondary)
                            if !row.episode.userPresent { Text("away").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                        }
                        Text(row.episode.end == nil ? "In progress" : (row.cause ?? "No single application"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(row.id)
                }
            }
        } detail: {
            if let d = model.episodeDetail {
                EpisodeDetailView(detail: d, model: model)
            } else {
                Placeholder(symbol: "tortoise", title: "No slowdown selected",
                            text: shown.isEmpty ? "No slowdowns in this period." : "Pick one on the left.")
            }
        }
    }
}

struct EpisodeDetailView: View {
    var detail: EpisodeDetail
    @ObservedObject var model: DashboardModel

    var body: some View {
        let e = detail.episode
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("\(when(e)) · \(length(e))").font(.title3.weight(.semibold))
                        DimensionTag(dim: e.dominant)
                    }
                    Text(detail.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "Index around the slowdown", subtitle: "Five minutes either side; shaded: the slowdown") {
                    let w = detail.window
                    TimeChart(series: [Series(name: "Index", color: Palette.blue, points: w.compactMap { s in s.index.map { (s.ts, Double($0)) } })],
                              unit: "", yMax: 100, threshold: (60, "slowdown"), bands: bands([e]), area: true, height: 150)
                    let active = dimensions.filter { d in (e.means[d] ?? 0) > 0 || w.contains { ($0.scores[d] ?? 0) >= 20 } }
                    if !active.isEmpty {
                        TimeChart(series: active.map { d in
                            Series(name: Palette.dimensionLabel[d] ?? d, color: Palette.dimension[d] ?? .gray, points: w.map { ($0.ts, Double($0.scores[d] ?? 0)) })
                        }, unit: "", yMax: 100, bands: bands([e]), height: 130)
                    }
                    if w.isEmpty { Text("The raw samples for this period have expired.").font(.caption).foregroundStyle(.secondary) }
                }
                Card(title: "Who caused it", subtitle: "Share of each dimension during the slowdown. Click an application for its history.") {
                    if detail.blame.isEmpty {
                        Text(e.end == nil ? "Causes are worked out when the slowdown ends." : "No application stands out.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        blameTable(detail.blame)
                    }
                }
                if !detail.evidence.isEmpty {
                    Card(title: "Evidence", subtitle: "Collected by the optional collectors") {
                        ForEach(Array(detail.evidence.enumerated()), id: \.offset) { _, ev in
                            HStack(alignment: .firstTextBaseline) {
                                Text(ev.label).font(.callout.weight(.medium)).frame(width: 150, alignment: .leading)
                                Text(ev.text).font(.callout).textSelection(.enabled)
                                Spacer()
                                if let path = ev.path {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                } else if ev.label != "Short-lived processes" {
                                    Text("file expired").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Facts(rows: [
                    ("In focus", e.focusApp ?? "–"),
                    ("You were", e.userPresent ? "at the Mac" : "away"),
                    ("Power", e.lowPower ? "Low Power Mode" : (e.onBattery ? "battery" : "power adapter")),
                    ("After wake", e.afterWake ? "yes" : "no"),
                    ("Peak / mean index", "\(e.peak) / \(e.mean)"),
                ])
            }
            .padding(16)
        }
    }

    private func blameTable(_ list: [Blame]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                ForEach(["Application", "Through", "Share", "Role", "What it did"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(Array(list.prefix(12).enumerated()), id: \.offset) { _, b in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Button(b.app) { model.showApp(named: b.app) }.buttonStyle(.link)
                        if let p = b.topProcess, p != b.app { Text("mostly \(p)").font(.caption2).foregroundStyle(.secondary) }
                    }
                    DimensionTag(dim: b.dim)
                    HStack(spacing: 6) {
                        UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 3, topTrailing: 3))
                            .fill(Palette.dimension[b.dim] ?? .gray)
                            .frame(width: max(2, 70 * min(1, b.share)), height: 10)
                            .frame(width: 70, alignment: .leading)
                        Text(Fmt.num(b.share * 100) + " %").monospacedDigit().fixedSize()
                    }
                    Text(b.role == "victim" ? "affected" : (b.confidence == 0 ? "cause (estimate)" : "cause"))
                        .foregroundStyle(b.role == "victim" ? .secondary : .primary)
                    Text(Explain.describe(b)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }
}

// MARK: - Findings

struct FindingsTab: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        MasterDetail {
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.findings.filter { $0.status == "open" }.count) active").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Include resolved", isOn: $model.showClosedFindings).toggleStyle(.checkbox).font(.callout)
                }
                .padding(8)
                List(model.findings, selection: $model.selectedFinding) { f in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(f.app).font(.body.weight(.medium))
                            Spacer()
                            SeverityTag(severity: f.severity, open: f.status == "open")
                        }
                        Text(Queries.sentence(f)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(f.id)
                }
            }
        } detail: {
            if let f = model.selectedFindingValue {
                FindingDetailView(finding: f, series: model.findingSeries, model: model)
            } else {
                Placeholder(symbol: "checkmark.seal", title: "No findings",
                            text: "Nothing chronic has been found: no leaks, runaway processes, wakeup storms or heavy writers.")
            }
        }
    }
}

struct FindingDetailView: View {
    var finding: Queries.Finding
    var series: [AppPoint]
    @ObservedObject var model: DashboardModel

    static let kindNames = ["leak_suspect": "Possible memory leak", "runaway_cpu": "Runaway CPU use", "wakeup_storm": "Wakeup storm",
                            "disk_writer": "Heavy disk writer", "anomaly": "Unusual behaviour", "crash_loop": "Crash loop",
                            "disk_nearly_full": "Disk nearly full"]

    var body: some View {
        let f = finding
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(Self.kindNames[f.kind] ?? f.kind).font(.title3.weight(.semibold))
                        SeverityTag(severity: f.severity, open: f.status == "open")
                    }
                    Text(Queries.sentence(f)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Facts(rows: [
                    ("Application", f.app),
                    (f.status == "open" ? "Active since" : "Seen from", "\(Fmt.day(f.first)) \(Fmt.clock(f.first))"),
                    (f.status == "open" ? "Last confirmed" : "Until", "\(Fmt.day(f.last)) \(Fmt.clock(f.last))"),
                ])
                if !["disk_nearly_full", "crash_loop"].contains(f.kind) || !series.isEmpty {
                    let bandsForSpan = [Band(id: f.id, start: date(f.first), end: date(max(f.last, f.first + 60_000)))]
                    Card(title: "Memory of \(f.app)", subtitle: "Average footprint; shaded: the period the finding covers") {
                        TimeChart(series: [Series(name: "Memory", color: Palette.orange, points: series.compactMap { p in p.footprintMB.map { (p.ts, $0) } })],
                                  unit: "MB", bands: bandsForSpan, area: true, height: 150)
                    }
                    Card(title: "CPU of \(f.app)", subtitle: "Average share of one core") {
                        TimeChart(series: [Series(name: "CPU", color: Palette.blue, points: series.map { ($0.ts, $0.cpuPct) })],
                                  unit: "%", bands: bandsForSpan, area: true, height: 150)
                    }
                }
                Card(title: "Evidence", subtitle: "The numbers that triggered the finding") {
                    Facts(rows: f.evidence.keys.sorted().map { k in
                        let v = f.evidence[k]
                        let text = (v as? NSNumber).map { Fmt.num($0.doubleValue, $0.doubleValue.rounded() == $0.doubleValue ? 0 : 2) } ?? "\(v ?? "")"
                        return (k.replacingOccurrences(of: "_", with: " "), text)
                    })
                }
                if !f.app.hasPrefix("This Mac") {
                    Button { model.showApp(named: f.app) } label: { Label("Open \(f.app) in Apps", systemImage: "arrow.right.circle") }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Apps

struct AppsTab: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        MasterDetail {
            List(model.apps, selection: $model.selectedApp) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(a.name).lineLimit(1)
                        Spacer()
                        Text(Fmt.num(a.cpuCoreMinutes, 1) + " core-min").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack(spacing: 10) {
                        Text("peak \(Fmt.size(mb: a.peakMB))")
                        Text("in focus \(Fmt.num(a.focusPct)) %")
                        if a.blameMinutes >= 0.05 {
                            HStack(spacing: 3) {
                                Image(systemName: "tortoise.fill").foregroundStyle(Palette.critical)
                                Text("caused \(Fmt.num(a.blameMinutes, 1)) min of slowdown")
                            }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(a.id)
            }
        } detail: {
            if let d = model.appDetail {
                AppDetailView(detail: d, model: model)
            } else {
                Placeholder(symbol: "app.dashed", title: "No application selected", text: "Pick one on the left.")
            }
        }
    }
}

struct AppDetailView: View {
    var detail: AppDetail
    @ObservedObject var model: DashboardModel

    var body: some View {
        let s = detail.series
        let grain = detail.bucketMs == 60_000 ? "minute" : (detail.bucketMs == 3_600_000 ? "hour" : "day")
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(detail.app.name).font(.title3.weight(.semibold))
                    Text(detail.app.kind).font(.caption).padding(.horizontal, 6).background(.quaternary, in: Capsule())
                }
                Card(title: "CPU", subtitle: "Average share of one core, per \(grain). Shaded: slowdowns it took part in — click one to open it.") {
                    TimeChart(series: [Series(name: "CPU", color: Palette.blue, points: s.map { ($0.ts, $0.cpuPct) })],
                              unit: "%", bands: bands(detail.episodes.map(\.episode)), area: true, onBandTap: { model.showEpisode($0) })
                }
                Card(title: "Memory", subtitle: "Average and highest footprint, per \(grain)") {
                    TimeChart(series: [
                        Series(name: "Highest", color: Palette.orange, points: s.compactMap { p in p.footprintMaxMB.map { (p.ts, $0) } }),
                        Series(name: "Average", color: Palette.magenta, points: s.compactMap { p in p.footprintMB.map { (p.ts, $0) } }),
                    ], unit: "MB")
                }
                Card(title: "Disk traffic", subtitle: "Read plus written, per \(grain)") {
                    TimeChart(series: [Series(name: "Disk", color: Palette.aqua, points: s.map { ($0.ts, $0.diskMB) })], unit: "MB", digits: 1, area: true)
                }
                Card(title: "Slowdowns it took part in", subtitle: "Click one to open it") {
                    if detail.episodes.isEmpty {
                        Text("None in this period.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(detail.episodes.prefix(20), id: \.episode.id) { item in
                        Button { model.showEpisode(item.episode.id) } label: {
                            HStack {
                                Text(when(item.episode)).monospacedDigit()
                                Text(length(item.episode)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                                DimensionTag(dim: item.dim)
                                Text(item.role == "victim" ? "affected" : "\(Fmt.num(item.share * 100)) % of the cause")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .font(.callout).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !detail.findings.isEmpty {
                    Card(title: "Findings") {
                        ForEach(detail.findings) { f in
                            Button { model.showFinding(f.id) } label: {
                                HStack {
                                    SeverityTag(severity: f.severity, open: f.status == "open")
                                    Text(Queries.sentence(f)).lineLimit(2)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .font(.callout).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}
