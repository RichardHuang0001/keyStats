import Foundation

/// Daily persistence journal. Call only while holding StatsManager's state lock.
/// Ordinary saves encode current + uncommitted days, never the complete history.
/// UserDefaults durability remains asynchronous; this does not promise recovery
/// of input received since the last save or after an OS/power failure.
final class DailyStatsPersistence {
    private struct Checkpoint: Codable {
        var current: DailyStats
        var pending: [String: DailyStats]
        var replacesHistory: Bool
    }

    private let defaults: UserDefaults
    private let historyURL: URL
    private let writeHistory: (Data, URL) throws -> Void
    private let checkpointKey = "dailyStatsRecovery.v1"
    private var pending: [String: DailyStats] = [:]
    private var replacesHistory = false
    private var historyDirty = false

    init(defaults: UserDefaults, historyURL: URL,
         writeHistory: @escaping (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
             try data.write(to: url, options: .atomic)
         }) {
        self.defaults = defaults
        self.historyURL = historyURL
        self.writeHistory = writeHistory
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func load(today: Date) -> (history: [String: DailyStats], current: DailyStats) {
        let decoder = JSONDecoder()
        var history: [String: DailyStats] = [:]
        if let data = try? Data(contentsOf: historyURL),
           let stored = try? decoder.decode([String: DailyStats].self, from: data) {
            history = stored
        } else if let data = defaults.data(forKey: "dailyStatsHistory"),
                  let stored = try? decoder.decode([String: DailyStats].self, from: data) {
            history = stored
            // Do not remove the legacy copy until save has committed the file.
            historyDirty = true
        }
        let checkpoint = defaults.data(forKey: checkpointKey).flatMap { try? decoder.decode(Checkpoint.self, from: $0) }
        if let checkpoint {
            pending = checkpoint.pending
            replacesHistory = checkpoint.replacesHistory
            if replacesHistory { history = pending }
            else { history.merge(pending) { _, new in new } }
            historyDirty = historyDirty || replacesHistory || !pending.isEmpty
        }
        let saved = checkpoint?.current ?? defaults.data(forKey: "dailyStats").flatMap { try? decoder.decode(DailyStats.self, from: $0) }
        let current: DailyStats
        if let saved, Calendar.current.isDate(saved.date, inSameDayAs: today) {
            current = saved
        } else {
            if let saved {
                var archived = saved
                archived.date = Calendar.current.startOfDay(for: saved.date)
                history[Self.dayKey(archived.date)] = archived
                archive(archived)
            }
            current = history[Self.dayKey(today)] ?? DailyStats(date: today)
        }
        return (history, current)
    }

    func archive(_ stats: DailyStats) {
        pending[Self.dayKey(stats.date)] = stats
        historyDirty = true
    }

    /// Imports are replacement transactions; their checkpoint must also preserve
    /// deletions, so an old history file cannot resurrect removed days on restart.
    func replaceHistory(_ history: [String: DailyStats]) {
        pending = history
        replacesHistory = true
        historyDirty = true
    }

    @discardableResult
    func save(current: DailyStats, history: [String: DailyStats]) -> Bool {
        do {
            let encoder = JSONEncoder()
            let checkpoint = Checkpoint(current: current, pending: pending, replacesHistory: replacesHistory)
            // One blob keeps current and recovery days consistent across restart.
            // It remains authoritative over the compatibility dailyStats key.
            defaults.set(try encoder.encode(checkpoint), forKey: checkpointKey)
            defaults.set(try encoder.encode(current), forKey: "dailyStats")
            guard historyDirty else { return true }
            try writeHistory(encoder.encode(history), historyURL)
            defaults.removeObject(forKey: "dailyStatsHistory")
            pending.removeAll()
            replacesHistory = false
            historyDirty = false
            defaults.set(try encoder.encode(Checkpoint(current: current, pending: [:], replacesHistory: false)), forKey: checkpointKey)
            return true
        } catch {
            // Keep the journal and dirty flag; the next scheduled save retries.
            print("⚠️ Daily statistics persistence failed: \(error)")
            return false
        }
    }
}
