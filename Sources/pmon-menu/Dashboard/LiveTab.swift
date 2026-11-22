import PmonCore
import SwiftUI

/// The last few minutes, sample by sample, re-read every 5 seconds.
struct LiveTab: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        let p = model.live
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(p.last)
                Card(title: "Sluggishness index", subtitle: "0 is idle, 100 a saturated resource; a slowdown opens when it stays at 60 or above") {
                    TimeChart(series: [Series(name: "Index", color: Palette.blue, points: p.compactMap { s in s.index.map { (s.ts, Double($0)) } })],
                              unit: "", yMax: 100, threshold: (60, "slowdown"), bands: openBands(p), area: true, height: 170)
                }
                Card(title: "What drives it", subtitle: "Sub-score of each dimension (0–100)") {
                    let active = dimensions.filter { d in p.contains { ($0.scores[d] ?? 0) > 0 } }
                    TimeChart(series: (active.isEmpty ? ["cpu"] : active).map { d in
                        Series(name: Palette.dimensionLabel[d] ?? d, color: Palette.dimension[d] ?? .gray, points: p.map { ($0.ts, Double($0.scores[d] ?? 0)) })
                    }, unit: "", yMax: 100)
                }
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "CPU busy", subtitle: "All cores, and the performance and efficiency clusters") {
                        TimeChart(series: [
                            Series(name: "All", color: Palette.blue, points: p.compactMap { s in s.cpuPct.map { (s.ts, $0) } }),
                            Series(name: "Performance", color: Palette.orange, points: p.compactMap { s in s.pPct.map { (s.ts, $0) } }),
                            Series(name: "Efficiency", color: Palette.aqua, points: p.compactMap { s in s.ePct.map { (s.ts, $0) } }),
                        ], unit: "%", yMax: 100)
                    }
                    Card(title: "Memory available", subtitle: "Share of memory the system considers available; low means pressure") {
                        TimeChart(series: [Series(name: "Available", color: Palette.orange, points: p.compactMap { s in s.memLevelPct.map { (s.ts, $0) } })],
                                  unit: "%", yMax: 100, area: true)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Compression and swap", subtitle: "Data compressed (original size), the RAM holding it, and swap") {
                        TimeChart(series: [
                            Series(name: "Compressed data", color: Palette.orange, points: p.compactMap { s in s.compressedGB.map { (s.ts, $0) } }),
                            Series(name: "Held in RAM", color: Palette.yellow, points: p.compactMap { s in s.compressorGB.map { (s.ts, $0) } }),
                            Series(name: "Swap", color: Palette.magenta, points: p.compactMap { s in s.swapGB.map { (s.ts, $0) } }),
                        ], unit: "GB", digits: 2)
                    }
                    Card(title: "Disk", subtitle: "Throughput") {
                        TimeChart(series: [
                            Series(name: "Read", color: Palette.aqua, points: p.compactMap { s in s.diskReadMBs.map { (s.ts, $0) } }),
                            Series(name: "Write", color: Palette.violet, points: p.compactMap { s in s.diskWriteMBs.map { (s.ts, $0) } }),
                        ], unit: "MB/s", digits: 1)
                    }
                    Card(title: "Network", subtitle: "Throughput") {
                        TimeChart(series: [
                            Series(name: "In", color: Palette.blue, points: p.compactMap { s in s.netInMBs.map { (s.ts, $0) } }),
                            Series(name: "Out", color: Palette.yellow, points: p.compactMap { s in s.netOutMBs.map { (s.ts, $0) } }),
                        ], unit: "MB/s", digits: 2)
                    }
                }
                Card(title: "Busy right now", subtitle: "Applications in the latest process sweep. Click one for its history.") {
                    topApps
                }
            }
            .padding(16)
        }
    }

    private func openBands(_ p: [LivePoint]) -> [Band] {
        // Runs of samples taken while an episode was open.
        var out: [Band] = []
        var start: Date?
        for (i, s) in p.enumerated() {
            if s.episodeOpen, start == nil { start = s.ts }
            if let st = start, !s.episodeOpen || i == p.count - 1 {
                out.append(Band(id: Int64(out.count), start: st, end: s.ts)); start = nil
            }
        }
        return out
    }

    private func header(_ last: LivePoint?) -> some View {
        TileRow {
            StatTile(value: last?.index.map(String.init) ?? "–", label: "sluggishness now",
                     note: last.map { s in
                         let top = dimensions.map { ($0, s.scores[$0] ?? 0) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(2)
                         return top.isEmpty ? "nothing elevated" : top.map { "\(Palette.dimensionLabel[$0.0] ?? $0.0) \($0.1)" }.joined(separator: ", ")
                     })
            StatTile(value: last?.cpuPct.map { Fmt.num($0) + " %" } ?? "–", label: "CPU busy")
            StatTile(value: last?.memLevelPct.map { Fmt.num($0) + " %" } ?? "–", label: "memory available",
                     note: last?.swapGB.map { "swap \(Fmt.num($0, 2)) GB" })
            StatTile(value: last.map { Fmt.num(($0.diskReadMBs ?? 0) + ($0.diskWriteMBs ?? 0), 1) } ?? "–", label: "disk MB/s")
            StatTile(value: last?.ts.formatted(date: .omitted, time: .standard) ?? "–", label: "latest sample", note: "updates every 5 s")
        }
    }

    private var topApps: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                ForEach(["Application", "CPU, % of a core", "Memory", "Processes", ""], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            let top = max(100, model.topApps.map(\.cpuPct).max() ?? 100)
            ForEach(model.topApps) { a in
                GridRow {
                    Button { model.showApp(id: a.id) } label: {
                        HStack(spacing: 6) {
                            Text(a.name)
                            if a.focus { Text("in focus").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                        }
                    }
                    .buttonStyle(.link)
                    HStack(spacing: 6) {
                        GeometryReader { g in
                            UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 3, topTrailing: 3))
                                .fill(Palette.blue).frame(width: max(2, g.size.width * a.cpuPct / top))
                        }
                        .frame(width: 120, height: 10)
                        Text(Fmt.num(a.cpuPct)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Text(Fmt.size(mb: a.footprintMB)).monospacedDigit()
                    Text(String(a.procs)).monospacedDigit()
                    Text(a.kind == "app" ? "" : a.kind).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
