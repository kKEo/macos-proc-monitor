import PmonCore
import SwiftUI

/// The dashboard on collected data: headline numbers, history charts, and who caused what.
struct OverviewTab: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ScrollView {
            if let o = model.overview {
                VStack(alignment: .leading, spacing: 14) {
                    tiles(o)
                    let grain = o.bucketMs == 60_000 ? "minute" : (o.bucketMs == 3_600_000 ? "hour" : "day")
                    Card(title: "Sluggishness", subtitle: "Highest and average index in each \(grain). Shaded: slowdowns — click one to open it.") {
                        TimeChart(series: [
                            Series(name: "Highest", color: Palette.blue, points: o.series.compactMap { p in p.slugMax.map { (p.ts, $0) } }),
                            Series(name: "Average", color: Palette.violet, points: o.series.compactMap { p in p.slugAvg.map { (p.ts, $0) } }),
                        ], unit: "", yMax: 100, threshold: (60, "slowdown"), bands: bands(o.episodes), height: 190,
                        onBandTap: { model.showEpisode($0) })
                    }
                    HStack(alignment: .top, spacing: 14) {
                        Card(title: "CPU busy", subtitle: "Share of all cores, per \(grain)") {
                            TimeChart(series: [
                                Series(name: "Highest", color: Palette.blue, points: o.series.compactMap { p in p.cpuMax.map { (p.ts, $0) } }),
                                Series(name: "Average", color: Palette.violet, points: o.series.compactMap { p in p.cpuAvg.map { (p.ts, $0) } }),
                            ], unit: "%", yMax: 100)
                        }
                        Card(title: "Memory", subtitle: "Data compressed (original size) and swap in use, highest per \(grain)") {
                            TimeChart(series: [
                                Series(name: "Compressed data", color: Palette.orange, points: o.series.compactMap { p in p.compressedGB.map { (p.ts, $0) } }),
                                Series(name: "Swap", color: Palette.magenta, points: o.series.compactMap { p in p.swapGB.map { (p.ts, $0) } }),
                            ], unit: "GB", digits: 1)
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        Card(title: "Disk traffic", subtitle: "Read plus written, per \(grain)") {
                            TimeChart(series: [Series(name: "Disk", color: Palette.aqua, points: o.series.map { ($0.ts, $0.diskMB) })],
                                      unit: "MB", area: true)
                        }
                        Card(title: "GPU busy", subtitle: "Average per \(grain)") {
                            TimeChart(series: [Series(name: "GPU", color: Palette.magenta, points: o.series.compactMap { p in p.gpuAvg.map { (p.ts, $0) } })],
                                      unit: "%", yMax: 100, area: true)
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        Card(title: "Applications that caused slowdowns",
                             subtitle: "Slowdown caused, in minutes: blame share × length, summed. Click to open the app.") {
                            if o.offenders.isEmpty {
                                Text("No application caused a measurable slowdown.").font(.callout).foregroundStyle(.secondary)
                            } else {
                                BarList(rows: o.offenders.map {
                                    .init(id: $0.app, label: $0.app, value: $0.minutes, text: Fmt.num($0.minutes, 1) + " min",
                                          color: Palette.dimension[$0.via] ?? Palette.blue)
                                }, onTap: { model.showApp(named: $0.id) })
                                HStack(spacing: 12) {
                                    Text("Colour: main bottleneck").font(.caption).foregroundStyle(.secondary)
                                    ForEach(Array(Set(o.offenders.map(\.via))).sorted(), id: \.self) { DimensionTag(dim: $0) }
                                }
                            }
                        }
                        Card(title: "Recent slowdowns", subtitle: "Click one to see what caused it") {
                            let recent = o.episodes.reversed().filter { $0.userPresent || $0.end == nil }.prefix(8)
                            if recent.isEmpty {
                                Text("None while you were at the Mac.").font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(Array(recent)) { e in
                                Button { model.showEpisode(e.id) } label: {
                                    HStack {
                                        Text(when(e)).monospacedDigit()
                                        Text(length(e)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                                        DimensionTag(dim: e.dominant)
                                        Spacer()
                                        Text("peak \(e.peak)").foregroundStyle(.secondary).monospacedDigit()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .font(.callout).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Card(title: "Background cost", subtitle: "Applications in focus less than 5 % of the time. Click a row to open the app.") {
                        if o.background.isEmpty {
                            Text("Nothing notable ran in the background.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                GridRow {
                                    ForEach(["Application", "CPU, core-min", "Peak memory", "Written", "Energy"], id: \.self) {
                                        Text($0).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(o.background, id: \.app) { b in
                                    GridRow {
                                        Button(b.app) { model.showApp(named: b.app) }.buttonStyle(.link)
                                        Text(Fmt.num(b.cpuCoreMinutes, 1)).monospacedDigit()
                                        Text(Fmt.size(mb: b.peakMb)).monospacedDigit()
                                        Text(Fmt.size(mb: b.writtenMb)).monospacedDigit()
                                        Text(b.energyMwh.map { Fmt.num($0, 1) + " mWh" } ?? "–").monospacedDigit()
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }

    private func tiles(_ o: Overview) -> some View {
        let t = o.totals
        return TileRow {
            StatTile(value: String(t.episodes), label: "slowdown\(t.episodes == 1 ? "" : "s") while you were at the Mac",
                     note: t.away > 0 ? "\(t.away) more while away" : nil)
            StatTile(value: Fmt.duration(t.sluggishMs), label: "spent slowed down",
                     note: t.presentMs > 0 ? "\(Fmt.num(Double(t.sluggishMs) * 100 / Double(t.presentMs), 1)) % of the time you were present" : nil)
            StatTile(value: Fmt.duration(t.observedMs), label: "observed awake", note: "\(Fmt.duration(t.presentMs)) with you present")
            Button { model.show(.findings) } label: {
                StatTile(value: String(o.activeFindings), label: "active finding\(o.activeFindings == 1 ? "" : "s")", note: "Click to review")
            }
            .buttonStyle(.plain)
        }
    }
}
