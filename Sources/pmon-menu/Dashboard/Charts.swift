import AppKit
import Charts
import PmonCore
import SwiftUI

/// The reference categorical palette, with separate light and dark steps. Colour follows the
/// entity: each dimension and each measure always gets the same slot.
enum Palette {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
    static let blue = dynamic(0x2a78d6, 0x3987e5)
    static let orange = dynamic(0xeb6834, 0xd95926)
    static let aqua = dynamic(0x1baf7a, 0x199e70)
    static let yellow = dynamic(0xeda100, 0xc98500)
    static let magenta = dynamic(0xe87ba4, 0xd55181)
    static let green = dynamic(0x008300, 0x0ca30c)
    static let violet = dynamic(0x6250d6, 0x9085e9)

    /// Status colours: reserved for state, always next to an icon or a word.
    static let warning = dynamic(0xc98500, 0xeda100)
    static let critical = dynamic(0xd03b3b, 0xe66767)

    static let dimension: [String: Color] = ["cpu": blue, "memory": orange, "disk": aqua, "thermal": yellow, "gpu": magenta, "ui": green]
    static let dimensionLabel = ["cpu": "CPU", "memory": "Memory", "disk": "Disk", "thermal": "Thermal", "gpu": "GPU", "ui": "UI"]
}

/// One line in a time chart.
struct Series: Identifiable {
    var name: String
    var color: Color
    var points: [(Date, Double)]
    var id: String { name }
}

/// A band to shade behind a time chart, such as a slowdown.
struct Band: Identifiable {
    var id: Int64
    var start: Date, end: Date
}

/// A line chart over time with a single y axis, a legend for two or more series, an optional
/// threshold rule, shaded bands, and a crosshair with the values under the pointer.
struct TimeChart: View {
    var series: [Series]
    var unit: String
    var digits = 0
    var yMax: Double?
    var threshold: (value: Double, label: String)?
    var bands: [Band] = []
    var area = false
    var height: CGFloat = 160
    var onBandTap: ((Int64) -> Void)?

    @State private var hover: Date?

    private func format(_ v: Double) -> String { Fmt.num(v, digits) + (unit.isEmpty ? "" : " " + unit) }

    /// The point of each series nearest to the pointer.
    private func nearest(_ d: Date) -> [(Series, Date, Double)] {
        series.compactMap { s in
            s.points.min { abs($0.0.timeIntervalSince(d)) < abs($1.0.timeIntervalSince(d)) }.map { (s, $0.0, $0.1) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if series.count >= 2 {
                HStack(spacing: 14) {
                    ForEach(series) { s in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1).fill(s.color).frame(width: 12, height: 3)
                            Text(s.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if series.allSatisfy({ $0.points.isEmpty }) {
                Text("No data for this period").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: height)
            } else {
                chart.frame(height: height)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(bands) { b in
                RectangleMark(xStart: .value("Start", b.start), xEnd: .value("End", b.end))
                    .foregroundStyle(Palette.critical.opacity(0.10))
            }
            if let t = threshold {
                RuleMark(y: .value(t.label, t.value))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) { Text(t.label).font(.caption2).foregroundStyle(.secondary) }
            }
            ForEach(series) { s in
                ForEach(Array(s.points.enumerated()), id: \.offset) { _, p in
                    if area && series.count == 1 {
                        AreaMark(x: .value("Time", p.0), y: .value(s.name, p.1))
                            .foregroundStyle(s.color.opacity(0.15))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Time", p.0), y: .value(s.name, p.1), series: .value("Series", s.name))
                        .foregroundStyle(s.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let h = hover {
                RuleMark(x: .value("Time", h))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(h)
                    }
                ForEach(nearest(h), id: \.0.id) { s, d, v in
                    PointMark(x: .value("Time", d), y: .value(s.name, v))
                        .foregroundStyle(s.color)
                        .symbolSize(50)
                }
            }
        }
        .chartYScale(domain: 0...max(yMax ?? 0, series.flatMap { $0.points.map(\.1) }.max() ?? 1, threshold?.value ?? 0, 0.0001))
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.num(d, d < 10 && digits > 0 ? 1 : 0)) } }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                            hover = proxy.value(atX: p.x - origin.x, as: Date.self)
                        case .ended: hover = nil
                        }
                    }
                    .onTapGesture { p in
                        guard let onBandTap, let origin = proxy.plotFrame.map({ geo[$0].origin }),
                              let d = proxy.value(atX: p.x - origin.x, as: Date.self),
                              let b = bands.first(where: { $0.start <= d && d <= $0.end }) else { return }
                        onBandTap(b.id)
                    }
            }
        }
    }

    private func tooltip(_ d: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            ForEach(nearest(d), id: \.0.id) { s, _, v in
                HStack(spacing: 5) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(s.name).font(.caption)
                    Spacer(minLength: 8)
                    Text(format(v)).font(.caption.monospacedDigit())
                }
            }
            if onBandTap != nil, bands.contains(where: { $0.start <= d && d <= $0.end }) {
                Text("Click to open this slowdown").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(minWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}

/// Horizontal bars, one per row, with the value printed at the end; for rankings.
struct BarList: View {
    struct Row: Identifiable { var id: String; var label: String; var value: Double; var text: String; var color: Color }
    var rows: [Row]
    var onTap: ((Row) -> Void)?

    var body: some View {
        let top = rows.map(\.value).max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Text(r.label).font(.callout).lineLimit(1).frame(width: 190, alignment: .leading)
                    GeometryReader { g in
                        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 4, topTrailing: 4))
                            .fill(r.color)
                            .frame(width: max(2, g.size.width * CGFloat(r.value / max(top, 0.0001))))
                    }
                    .frame(height: 12)
                    Text(r.text).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap?(r) }
                .help(onTap == nil ? "" : "Open \(r.label)")
            }
        }
    }
}

/// A headline number with a label.
struct StatTile: View {
    var value: String
    var label: String
    var note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.callout)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A titled block on a dashboard page.
struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
