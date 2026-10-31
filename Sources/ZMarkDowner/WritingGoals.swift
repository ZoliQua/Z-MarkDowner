import AppKit
import MarkDownerCore

/// Daily word count and per-document goals (stored in the user defaults).
final class WritingGoals {
    static let shared = WritingGoals()

    private let defaults = UserDefaults.standard
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var today: String { dayFormatter.string(from: Date()) }

    /// Words added today across all documents (deletions are not subtracted).
    var wordsToday: Int {
        (defaults.dictionary(forKey: "wordsWritten") as? [String: Int])?[today] ?? 0
    }

    func record(_ added: Int) {
        guard added > 0, added < 5_000 else { return }   // ignore pastes of whole documents
        var log = (defaults.dictionary(forKey: "wordsWritten") as? [String: Int]) ?? [:]
        let before = log[today] ?? 0
        log[today] = before + added
        // Keep the last 60 days
        if log.count > 60 { for key in log.keys.sorted().dropLast(60) { log[key] = nil } }
        defaults.set(log, forKey: "wordsWritten")
        let goal = Settings.shared.dailyWordGoal
        if goal > 0, before < goal, before + added >= goal {
            NotificationCenter.default.post(name: Self.dailyGoalReached, object: nil)
        }
    }

    static let dailyGoalReached = Notification.Name("ZMarkDownerDailyGoalReached")

    func goal(for url: URL) -> Int? {
        (defaults.dictionary(forKey: "documentGoals") as? [String: Int])?[url.standardizedFileURL.path]
    }

    func setGoal(_ goal: Int?, for url: URL) {
        var goals = (defaults.dictionary(forKey: "documentGoals") as? [String: Int]) ?? [:]
        goals[url.standardizedFileURL.path] = (goal ?? 0) > 0 ? goal : nil
        defaults.set(goals, forKey: "documentGoals")
    }
}

/// Popover with document statistics and writing goals.
final class StatisticsViewController: NSViewController {
    private weak var windowController: DocumentWindowController?
    private let grid = NSGridView()
    private var values: [String: NSTextField] = [:]
    private let goalField = NSTextField()
    private let dailyField = NSTextField()
    private let goalBar = NSProgressIndicator()
    private let dailyBar = NSProgressIndicator()

    init(windowController: DocumentWindowController) {
        self.windowController = windowController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let rows: [(String, String)] = [
        ("words", L("stats.words", "Words")), ("characters", L("stats.characters", "Characters")),
        ("charactersNoSpaces", L("stats.charactersNoSpaces", "Characters (no spaces)")),
        ("sentences", L("stats.sentences", "Sentences")), ("paragraphs", L("stats.paragraphs", "Paragraphs")),
        ("sentenceLength", L("stats.sentenceLength", "Average sentence length")),
        ("reading", L("stats.reading", "Reading time")), ("speaking", L("stats.speaking", "Speaking time")),
        ("selection", L("stats.selection", "Selection")),
    ]

    override func loadView() {
        grid.rowSpacing = 6
        grid.columnSpacing = 14
        let title = NSTextField(labelWithString: L("stats.title", "Statistics"))
        title.font = .boldSystemFont(ofSize: 13)
        grid.addRow(with: [title, NSGridCell.emptyContentView])
        for (key, english) in Self.rows {
            let label = NSTextField(labelWithString: english)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            value.alignment = .right
            values[key] = value
            grid.addRow(with: [label, value])
        }

        let goals = NSTextField(labelWithString: L("stats.goals", "Goals"))
        goals.font = .boldSystemFont(ofSize: 13)
        grid.addRow(with: [goals, NSGridCell.emptyContentView])
        for (field, action, placeholder) in [(goalField, #selector(goalChanged), L("stats.goalPlaceholder", "words")),
                                             (dailyField, #selector(dailyChanged), L("stats.goalPlaceholder", "words"))] {
            field.placeholderString = placeholder
            field.alignment = .right
            field.target = self
            field.action = action
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        for bar in [goalBar, dailyBar] {
            bar.style = .bar
            bar.controlSize = .small
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        grid.addRow(with: [NSTextField(labelWithString: L("stats.documentGoal", "Document goal")), goalField])
        grid.addRow(with: [NSGridCell.emptyContentView, goalBar])
        grid.addRow(with: [NSTextField(labelWithString: L("stats.dailyGoal", "Daily goal")), dailyField])
        grid.addRow(with: [NSGridCell.emptyContentView, dailyBar])
        let today = NSTextField(labelWithString: "")
        today.textColor = .secondaryLabelColor
        values["today"] = today
        grid.addRow(with: [NSTextField(labelWithString: L("stats.today", "Written today")), today])
        grid.column(at: 1).xPlacement = .trailing
        grid.row(at: Self.rows.count + 1).topPadding = 8

        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        view = container
        refresh()
    }

    private func minutes(_ value: Double) -> String {
        let total = Int((value * 60).rounded())
        return total < 60 ? LF("stats.seconds", "%d s", total) : LF("stats.minutesSeconds", "%d min %d s", total / 60, total % 60)
    }

    func refresh() {
        guard isViewLoaded, let wc = windowController else { return }
        let s = wc.statistics
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        func n(_ v: Int) -> String { nf.string(from: NSNumber(value: v)) ?? "\(v)" }
        values["words"]?.stringValue = n(s.words)
        values["characters"]?.stringValue = n(s.characters)
        values["charactersNoSpaces"]?.stringValue = n(s.charactersWithoutSpaces)
        values["sentences"]?.stringValue = n(s.sentences)
        values["paragraphs"]?.stringValue = n(s.paragraphs)
        values["sentenceLength"]?.stringValue = String(format: "%.1f", s.averageSentenceLength)
        values["reading"]?.stringValue = minutes(s.readingMinutes)
        values["speaking"]?.stringValue = minutes(s.speakingMinutes)
        if let sel = wc.selectionStatistics {
            values["selection"]?.stringValue = LF("stats.selectionWords", "%d words", sel.words)
        } else {
            values["selection"]?.stringValue = "–"
        }
        let goal = wc.documentGoal ?? 0
        if !(goalField.currentEditor() != nil) { goalField.stringValue = goal > 0 ? "\(goal)" : "" }
        goalBar.doubleValue = goal > 0 ? min(1, Double(s.words) / Double(goal)) : 0
        let daily = Settings.shared.dailyWordGoal
        if !(dailyField.currentEditor() != nil) { dailyField.stringValue = daily > 0 ? "\(daily)" : "" }
        let today = WritingGoals.shared.wordsToday
        dailyBar.doubleValue = daily > 0 ? min(1, Double(today) / Double(daily)) : 0
        values["today"]?.stringValue = daily > 0 ? LF("status.goal", "%d / %d words", today, daily) : LF("stats.selectionWords", "%d words", today)
    }

    @objc private func goalChanged() {
        windowController?.documentGoal = Int(goalField.stringValue.filter(\.isNumber))
        refresh()
    }

    @objc private func dailyChanged() {
        Settings.shared.dailyWordGoal = Int(dailyField.stringValue.filter(\.isNumber)) ?? 0
        refresh()
    }
}
