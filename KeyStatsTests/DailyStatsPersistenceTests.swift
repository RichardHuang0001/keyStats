import XCTest
@testable import KeyStatsCore

final class DailyStatsPersistenceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var failWrites = false
    private var writes = 0
    private let yesterday = Date(timeIntervalSince1970: 1_700_000_000)
    private var today: Date { yesterday.addingTimeInterval(86400) }

    override func setUpWithError() throws {
        suite = "KeyStats.persistence.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func stats(_ date: Date, _ count: Int) -> DailyStats {
        var value = DailyStats(date: date)
        value.keyPresses = count
        return value
    }
    private func store() -> DailyStatsPersistence {
        DailyStatsPersistence(defaults: defaults, historyURL: directory.appendingPathComponent("history.json")) { [unowned self] data, url in
            self.writes += 1
            if self.failWrites { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
    }
    func testFailedMigrationPreservesLegacyUntilSuccessfulRetry() throws {
        let old = stats(yesterday, 40)
        let key = DailyStatsPersistence.dayKey(yesterday)
        try defaults.set(JSONEncoder().encode([key: old]), forKey: "dailyStatsHistory")
        failWrites = true
        let persistence = store()
        let loaded = persistence.load(today: today)
        XCTAssertEqual(loaded.history[key]?.keyPresses, 40)
        XCTAssertFalse(persistence.save(current: loaded.current, history: loaded.history))
        XCTAssertNotNil(defaults.data(forKey: "dailyStatsHistory"))
        failWrites = false
        XCTAssertTrue(persistence.save(current: loaded.current, history: loaded.history))
        XCTAssertNil(defaults.data(forKey: "dailyStatsHistory"))
        XCTAssertEqual(store().load(today: today).history[key]?.keyPresses, 40)
    }
    func testPreviousDayRecoveredWithoutDoubleCountingAcrossRestarts() throws {
        try defaults.set(JSONEncoder().encode(stats(yesterday, 123)), forKey: "dailyStats")
        let key = DailyStatsPersistence.dayKey(yesterday)
        failWrites = true
        for _ in 0..<3 {
            let persistence = store()
            let loaded = persistence.load(today: today)
            XCTAssertEqual(loaded.history[key]?.keyPresses, 123)
            XCTAssertEqual(loaded.current.keyPresses, 0)
            XCTAssertFalse(persistence.save(current: loaded.current, history: loaded.history))
        }
        failWrites = false
        let persistence = store()
        let loaded = persistence.load(today: today)
        XCTAssertTrue(persistence.save(current: loaded.current, history: loaded.history))
        XCTAssertEqual(store().load(today: today).history[key]?.keyPresses, 123)
    }
    func testRolloverKeepsSeveralDaysDuringFailureAndOrdinarySavesSkipHistory() {
        let persistence = store()
        _ = persistence.load(today: yesterday)
        var history: [String: DailyStats] = [:]
        failWrites = true
        for day in 0..<3 {
            let value = stats(yesterday.addingTimeInterval(Double(day) * 86400), 10 + day)
            let key = DailyStatsPersistence.dayKey(value.date)
            history[key] = value
            persistence.archive(value)
            XCTAssertFalse(persistence.save(current: stats(value.date.addingTimeInterval(86400), 0), history: history))
        }
        let restarted = store()
        let loaded = restarted.load(today: yesterday.addingTimeInterval(3 * 86400))
        XCTAssertEqual(loaded.history.count, 3)
        failWrites = false
        XCTAssertTrue(restarted.save(current: loaded.current, history: loaded.history))
        let savedWrites = writes
        XCTAssertTrue(restarted.save(current: loaded.current, history: loaded.history))
        XCTAssertEqual(writes, savedWrites)
    }
    func testReplacementAndResetDoNotResurrectRecoveryData() {
        let persistence = store()
        _ = persistence.load(today: today)
        persistence.archive(stats(yesterday, 100))
        failWrites = true
        let replacement = [DailyStatsPersistence.dayKey(today): stats(today, 0)]
        persistence.replaceHistory(replacement)
        XCTAssertFalse(persistence.save(current: stats(today, 0), history: replacement))
        let loaded = store().load(today: today)
        XCTAssertNil(loaded.history[DailyStatsPersistence.dayKey(yesterday)])
        XCTAssertEqual(loaded.current.keyPresses, 0)
    }
    func testSuccessfulMigrationCommitsLegacyAndCurrentTogether() throws {
        let key = DailyStatsPersistence.dayKey(yesterday)
        try defaults.set(JSONEncoder().encode([key: stats(yesterday, 40)]), forKey: "dailyStatsHistory")
        try defaults.set(JSONEncoder().encode(stats(yesterday, 60)), forKey: "dailyStats")
        let persistence = store()
        let loaded = persistence.load(today: today)
        XCTAssertEqual(loaded.history[key]?.keyPresses, 60)
        XCTAssertTrue(persistence.save(current: loaded.current, history: loaded.history))
        XCTAssertNil(defaults.data(forKey: "dailyStatsHistory"))
        XCTAssertEqual(store().load(today: today).history[key]?.keyPresses, 60)
    }

    func testReplayAfterFileCommitBeforeJournalClearIsIdempotent() {
        let url = directory.appendingPathComponent("history.json")
        let persistence = DailyStatsPersistence(defaults: defaults, historyURL: url) { data, url in
            try data.write(to: url, options: .atomic)
            // Simulate interruption after the replacement committed but before
            // save can clear the journal; disk and journal both contain this day.
            throw CocoaError(.fileWriteUnknown)
        }
        _ = persistence.load(today: today)
        let archived = stats(yesterday, 80)
        let key = DailyStatsPersistence.dayKey(yesterday)
        persistence.archive(archived)
        XCTAssertFalse(persistence.save(current: stats(today, 3), history: [key: archived]))
        let restarted = store()
        let loaded = restarted.load(today: today)
        XCTAssertEqual(loaded.history[key]?.keyPresses, 80)
        XCTAssertEqual(loaded.current.keyPresses, 3)
        XCTAssertTrue(restarted.save(current: loaded.current, history: loaded.history))
        XCTAssertEqual(store().load(today: today).history[key]?.keyPresses, 80)
    }

    func testExplicitResetOverridesOldCurrentAndOldRecoveryOnRestart() {
        let persistence = store()
        _ = persistence.load(today: today)
        let key = DailyStatsPersistence.dayKey(today)
        persistence.archive(stats(today, 100))
        failWrites = true
        XCTAssertFalse(persistence.save(current: stats(today, 100), history: [key: stats(today, 100)]))
        persistence.archive(stats(today, 0))
        XCTAssertFalse(persistence.save(current: stats(today, 0), history: [key: stats(today, 0)]))
        let loaded = store().load(today: today)
        XCTAssertEqual(loaded.current.keyPresses, 0)
        XCTAssertEqual(loaded.history[key]?.keyPresses, 0)
    }

    func testOverwriteImportHidesDaysFromExistingFileEvenWhenWriteFails() {
        let persistence = store()
        _ = persistence.load(today: today)
        let key = DailyStatsPersistence.dayKey(yesterday)
        persistence.archive(stats(yesterday, 200))
        XCTAssertTrue(persistence.save(current: stats(today, 20), history: [key: stats(yesterday, 200)]))
        failWrites = true
        persistence.replaceHistory([:])
        XCTAssertFalse(persistence.save(current: stats(today, 0), history: [:]))
        let restarted = store()
        let loaded = restarted.load(today: today)
        XCTAssertTrue(loaded.history.isEmpty)
        XCTAssertEqual(loaded.current.keyPresses, 0)
        failWrites = false
        XCTAssertTrue(restarted.save(current: loaded.current, history: loaded.history))
        XCTAssertTrue(store().load(today: today).history.isEmpty)
    }

}
