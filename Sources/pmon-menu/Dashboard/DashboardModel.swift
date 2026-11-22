import Foundation
import PmonCore
import SwiftUI

/// The dashboard's tabs. Every menu entry opens the one window on one of these.
enum DashboardTab: String, CaseIterable, Identifiable {
    case overview, live, slowdowns, findings, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .live: return "Live"
        case .slowdowns: return "Slowdowns"
        case .findings: return "Findings"
        case .apps: return "Apps"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .live: return "waveform.path.ecg"
        case .slowdowns: return "tortoise"
        case .findings: return "exclamationmark.triangle"
        case .apps: return "app.dashed"
        }
    }
}

/// State behind the window: what is selected and what has been read for it.
@MainActor
final class DashboardModel: ObservableObject {
    let data: DashboardData

    @Published var tab: DashboardTab = .overview { didSet { if tab != oldValue { refresh() } } }
    @Published var range: TimeRange = .day { didSet { if range != oldValue { refresh() } } }
    @Published var liveMinutes = 15 { didSet { if liveMinutes != oldValue { refresh() } } }

    /// nil: no database. Otherwise the age of the newest sample, in seconds.
    @Published var sampleAge: Double?
    @Published var noDatabase = false
    @Published var error: String?

    @Published var live: [LivePoint] = []
    @Published var topApps: [TopApp] = []
    @Published var overview: Overview?

    @Published var episodes: [EpisodeRow] = []
    @Published var showAway = false
    @Published var selectedEpisode: Int64? { didSet { if selectedEpisode != oldValue { loadEpisode() } } }
    @Published var episodeDetail: EpisodeDetail?

    @Published var findings: [Queries.Finding] = []
    @Published var activeFindings = 0
    @Published var showClosedFindings = false { didSet { if showClosedFindings != oldValue { refresh() } } }
    @Published var selectedFinding: Int64? { didSet { if selectedFinding != oldValue { loadFindingSeries() } } }
    @Published var findingSeries: [AppPoint] = []

    @Published var apps: [AppSummary] = []
    @Published var selectedApp: Int64? { didSet { if selectedApp != oldValue { loadApp() } } }
    @Published var appDetail: AppDetail?

    /// True while the window is on screen; nothing is read otherwise.
    var visible = false
    private var timer: Timer?
    private var ticks = 0

    var stale: Bool { (sampleAge ?? .infinity) > 180 }

    init(dbPath: String) {
        data = DashboardData(path: dbPath)
    }

    // MARK: Lifecycle

    func appeared() {
        visible = true
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func disappeared() {
        visible = false
        timer?.invalidate()
        timer = nil
    }

    /// The live tab follows every sample; the others are re-read every minute.
    private func tick() {
        guard visible else { return }
        ticks += 1
        if tab == .live || ticks % 12 == 0 { refresh(quiet: true) }
    }

    // MARK: Navigation (used by the menu and by drill-down)

    func show(_ tab: DashboardTab) { self.tab = tab }

    func showEpisode(_ id: Int64?) {
        tab = .slowdowns
        if let id { selectedEpisode = id; showAway = true }
    }

    func showLatestEpisode() {
        tab = .slowdowns
        Task {
            if let id = try? await data.latestEpisodeId() { selectedEpisode = id; showAway = true }
        }
    }

    func showFinding(_ id: Int64) {
        // Show resolved findings too unless this one is known to be active.
        if findings.first(where: { $0.id == id })?.status != "open" { showClosedFindings = true }
        tab = .findings
        selectedFinding = id
    }

    func showApp(id: Int64) {
        tab = .apps
        selectedApp = id
    }

    func showApp(named name: String) {
        Task {
            if let ref = try? await data.appRef(name: name) { showApp(id: ref.id) }
        }
    }

    // MARK: Reading

    func refresh(quiet: Bool = false) {
        guard visible else { return }
        let tab = self.tab, range = self.range, minutes = liveMinutes, closed = showClosedFindings
        Task {
            do {
                let age = try await data.sampleAge()
                sampleAge = age
                noDatabase = false
                activeFindings = try await data.activeFindingCount()
                switch tab {
                case .live:
                    live = try await data.live(minutes: minutes)
                    topApps = try await data.topApps()
                case .overview:
                    overview = try await data.overview(range: range)
                case .slowdowns:
                    episodes = try await data.episodes(range: range)
                    if selectedEpisode == nil { selectedEpisode = episodes.first(where: { showAway || $0.episode.userPresent })?.id }
                    else if !quiet || episodeDetail?.episode.end == nil { loadEpisode() }
                case .findings:
                    findings = try await data.findings(includeClosed: closed)
                    if selectedFinding == nil || !findings.contains(where: { $0.id == selectedFinding }) { selectedFinding = findings.first?.id }
                    else if !quiet || findingSeries.isEmpty { loadFindingSeries() }
                case .apps:
                    apps = try await data.apps(range: range)
                    if selectedApp == nil { selectedApp = apps.first?.id } else if !quiet { loadApp() }
                }
                error = nil
            } catch is NoDatabase {
                noDatabase = true
            } catch {
                self.error = "\(error)"
            }
        }
    }

    private func loadEpisode() {
        guard let id = selectedEpisode else { episodeDetail = nil; return }
        Task {
            let detail = try? await data.episode(id: id)
            if selectedEpisode == id { episodeDetail = detail }
        }
    }

    var selectedFindingValue: Queries.Finding? { findings.first { $0.id == selectedFinding } }

    /// The finding's application over the finding's span, with an hour either side.
    private func loadFindingSeries() {
        findingSeries = []
        guard let f = selectedFindingValue else { return }
        Task {
            guard let ref = try? await data.appRef(name: f.app) else { return }
            let to = f.status == "open" ? msNow() : f.last + 3_600_000
            let from = min(f.first - 3_600_000, to - 6 * 3_600_000)
            let series = (try? await data.appSeries(ref.id, from: from, to: to))?.points ?? []
            if selectedFinding == f.id { findingSeries = series }
        }
    }

    private func loadApp() {
        guard let id = selectedApp else { appDetail = nil; return }
        let range = self.range
        Task {
            guard let ref = try? await data.appRef(id: id) else { return }
            let detail = try? await data.appDetail(ref, range: range)
            if selectedApp == id { appDetail = detail }
        }
    }
}
