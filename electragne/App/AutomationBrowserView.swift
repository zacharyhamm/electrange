import SwiftUI

struct AutomationBrowserView: View {
    let engine: AutomationEngine
    let log: LLMLog

    @State private var automations: [AutomationRecord] = []
    @State private var runs: [AutomationRunSummary] = []
    @State private var selection: String?
    @State private var creating = false
    @State private var showSidebar = true

    init(engine: AutomationEngine, log: LLMLog = .shared) {
        self.engine = engine
        self.log = log
    }

    // HSplitView, not NavigationSplitView: the latter is backed by an
    // NSSplitViewController that expects to be the root of a SwiftUI window
    // scene. Inside our manually hosted NSWindow (sizingOptions = []) it is
    // not bound to the window, so divider drags grow the split view past the
    // window bounds and the panes slide off-screen.
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                if showSidebar {
                    sidebarList
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)
                }
                detail
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 800 = sidebar max (320) + detail min (480: run-history HSplitView 180+300).
        .frame(minWidth: 800, minHeight: 500)
        .task { await reload() }
        .onChange(of: selection) { _, _ in creating = false }
    }

    private var header: some View {
        HStack {
            Button("Toggle Sidebar", systemImage: "sidebar.leading") {
                showSidebar.toggle()
            }
            Spacer()
            Button("New Automation", systemImage: "plus") { creating = true }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            Section("Scheduled") {
                ForEach(automations, id: \.id) { automation in
                    AutomationLabel(
                        name: automation.name,
                        schedule: scheduleText(automation)
                    )
                    .tag(activeKey(automation.id))
                }
            }
            if !archived.isEmpty {
                Section("History") {
                    ForEach(archived) { automation in
                        AutomationLabel(name: automation.name, schedule: "No longer scheduled")
                            .tag(historyKey(automation.automationID))
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if creating {
            AutomationEditorView(
                automation: nil,
                runs: [],
                engine: engine,
                log: log,
                onChange: { Task { await reload() } },
                onCreate: { record in
                    creating = false
                    selection = activeKey(record.id)
                    Task { await reload() }
                }
            )
            .id("new")
        } else if let automation = selectedAutomation {
            AutomationEditorView(
                automation: automation,
                runs: runs.filter { $0.automationID == automation.id },
                engine: engine,
                log: log,
                onChange: { Task { await reload() } },
                onCreate: { _ in }
            )
            .id("\(automation.id)-\(automation.name)-\(automation.intervalSeconds)-\(automation.instruction)-\(automation.schedule?.text ?? "")")
        } else if let historical = selectedHistory {
            HistoricalAutomationView(
                automation: historical,
                runs: runs.filter { $0.automationID == historical.automationID },
                log: log,
                onClear: { Task { await reload() } }
            )
        } else if automations.isEmpty, archived.isEmpty {
            ContentUnavailableView(
                "No Automations",
                systemImage: "clock.arrow.2.circlepath",
                description: Text("Click + to create one, or ask Electragne in chat.")
            )
        } else {
            ContentUnavailableView("Select an Automation", systemImage: "clock.arrow.2.circlepath")
        }
    }

    private var selectedAutomation: AutomationRecord? {
        guard let selection, selection.hasPrefix("active:") else { return nil }
        return automations.first { activeKey($0.id) == selection }
    }

    private var selectedHistory: AutomationRunSummary? {
        guard let selection, selection.hasPrefix("history:") else { return nil }
        return archived.first { historyKey($0.automationID) == selection }
    }

    private var archived: [AutomationRunSummary] {
        let activeIDs = Set(automations.map(\.id))
        return Dictionary(grouping: runs.filter { !activeIDs.contains($0.automationID) }, by: \.automationID)
            .values
            .compactMap { $0.max { $0.startedAt < $1.startedAt } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func reload() async {
        automations = engine.list().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        runs = await log.automationRuns()
        let validKeys = Set(automations.map { activeKey($0.id) } + archived.map { historyKey($0.automationID) })
        if selection.map(validKeys.contains) != true {
            selection = automations.first.map { activeKey($0.id) }
                ?? archived.first.map { historyKey($0.automationID) }
        }
    }

    private func scheduleText(_ automation: AutomationRecord) -> String {
        "Every \(TimerToolService.durationText(automation.intervalSeconds))"
            + (automation.schedule.map { " · \($0.text)" } ?? "")
    }

    private func activeKey(_ id: String) -> String { "active:\(id)" }
    private func historyKey(_ id: String) -> String { "history:\(id)" }
}

private struct AutomationLabel: View {
    let name: String
    let schedule: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).lineLimit(1)
            Text(schedule).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct AutomationEditorView: View {
    private static let weekdays = [
        (1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"),
        (5, "Thu"), (6, "Fri"), (7, "Sat"),
    ]

    /// Nil means the editor is creating a new automation.
    let automation: AutomationRecord?
    let runs: [AutomationRunSummary]
    let engine: AutomationEngine
    let log: LLMLog
    let onChange: () -> Void
    let onCreate: (AutomationRecord) -> Void

    @State private var name: String
    @State private var interval: String
    @State private var instruction: String
    @State private var hasWindow: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var weekdays: Set<Int>
    @State private var error: String?
    @State private var confirmDelete = false

    init(
        automation: AutomationRecord?,
        runs: [AutomationRunSummary],
        engine: AutomationEngine,
        log: LLMLog,
        onChange: @escaping () -> Void,
        onCreate: @escaping (AutomationRecord) -> Void
    ) {
        self.automation = automation
        self.runs = runs
        self.engine = engine
        self.log = log
        self.onChange = onChange
        self.onCreate = onCreate
        _name = State(initialValue: automation?.name ?? "")
        _interval = State(initialValue: String(automation?.intervalSeconds ?? 3_600))
        _instruction = State(initialValue: automation?.instruction ?? "")
        _hasWindow = State(initialValue: automation?.schedule?.startMinute != nil)
        _start = State(initialValue: Self.date(minute: automation?.schedule?.startMinute ?? 540))
        _end = State(initialValue: Self.date(minute: automation?.schedule?.endMinute ?? 1_020))
        _weekdays = State(initialValue: Set(automation?.schedule?.weekdays ?? []))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Automation") {
                    TextField("Name", text: $name)
                    LabeledContent("Run every") {
                        HStack {
                            TextField("Seconds", text: $interval).frame(width: 100)
                            Text("seconds").foregroundStyle(.secondary)
                        }
                    }
                    TextEditor(text: $instruction)
                        .font(.body)
                        .frame(minHeight: 70)
                        .accessibilityLabel("Instruction")
                }

                Section("Schedule") {
                    Toggle("Limit to a time window", isOn: $hasWindow)
                    if hasWindow {
                        DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                        DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                    }
                    LabeledContent("Active days") {
                        HStack(spacing: 4) {
                            ForEach(Self.weekdays, id: \.0) { day, label in
                                Toggle(label, isOn: weekdayBinding(day)).toggleStyle(.button)
                            }
                        }
                    }
                    Text(weekdays.isEmpty ? "No days selected means every day." : "Runs only on selected days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }

                HStack {
                    if automation != nil {
                        Button("Delete Automation", role: .destructive) { confirmDelete = true }
                        Button("Run Now") { runNow() }
                    }
                    Spacer()
                    Button(automation == nil ? "Create" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 320)

            if let automation {
                Divider()
                AutomationRunHistoryView(
                    automationID: automation.id,
                    runs: runs,
                    log: log,
                    onClear: onChange
                )
            }
        }
        .alert("Delete ‘\(automation?.name ?? "")’?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let automation { _ = engine.remove(id: automation.id) }
                onChange()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will stop running. Its activity history will be kept until you clear it.")
        }
    }

    private func runNow() {
        guard let automation else { return }
        guard engine.runNow(id: automation.id) else {
            error = "This automation is already running or no longer exists."
            return
        }
        error = nil
        onChange()
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { error = "Name cannot be empty."; return }
        guard !trimmedInstruction.isEmpty else { error = "Instruction cannot be empty."; return }
        guard let seconds = Int(interval), (60...604_800).contains(seconds) else {
            error = "Interval must be a whole number from 60 to 604,800 seconds."
            return
        }
        let startMinute = Self.minute(start)
        let endMinute = Self.minute(end)
        guard !hasWindow || startMinute != endMinute else {
            error = "Start and end times must differ."
            return
        }
        let schedule = hasWindow || !weekdays.isEmpty
            ? AutomationSchedule(
                startMinute: hasWindow ? startMinute : nil,
                endMinute: hasWindow ? endMinute : nil,
                weekdays: weekdays.isEmpty ? nil : weekdays.sorted()
            )
            : nil
        if let automation {
            guard engine.edit(
                id: automation.id,
                name: trimmedName,
                intervalSeconds: seconds,
                instruction: trimmedInstruction,
                schedule: schedule
            ) != nil else {
                error = "This automation no longer exists."
                return
            }
            error = nil
            onChange()
        } else {
            let record = engine.add(
                name: trimmedName,
                intervalSeconds: seconds,
                instruction: trimmedInstruction,
                schedule: schedule
            )
            error = nil
            onCreate(record)
        }
    }

    private func weekdayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { weekdays.contains(day) },
            set: { enabled in
                if enabled { weekdays.insert(day) } else { weekdays.remove(day) }
            }
        )
    }

    private static func date(minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minute(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

private struct HistoricalAutomationView: View {
    let automation: AutomationRunSummary
    let runs: [AutomationRunSummary]
    let log: LLMLog
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Deleted Automation") {
                    LabeledContent("Name", value: automation.name)
                    LabeledContent("Run every", value: TimerToolService.durationText(automation.intervalSeconds))
                    LabeledContent("Schedule", value: automation.schedule ?? "Any time")
                    LabeledContent("Instruction", value: automation.instruction)
                }
            }
            .formStyle(.grouped)
            .frame(height: 210)
            Divider()
            AutomationRunHistoryView(
                automationID: automation.automationID,
                runs: runs,
                log: log,
                onClear: onClear
            )
        }
    }
}

private struct AutomationRunHistoryView: View {
    let automationID: String
    let runs: [AutomationRunSummary]
    let log: LLMLog
    let onClear: () -> Void

    @State private var selection: String?
    @State private var entries: [AutomationLogEntry] = []
    @State private var confirmClear = false
    @State private var clearError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run History").font(.headline)
                Spacer()
                Button("Clear History", role: .destructive) { confirmClear = true }
                    .disabled(runs.isEmpty)
            }
            .padding(10)

            if runs.isEmpty {
                ContentUnavailableView(
                    "No Runs Yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Activity will appear after this automation runs.")
                )
            } else {
                HSplitView {
                    List(runs, selection: $selection) { run in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.startedAt, style: .date)
                            HStack {
                                Text(run.startedAt, style: .time)
                                Text(run.status.capitalized)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(run.id)
                    }
                    .frame(minWidth: 180, idealWidth: 220)

                    // NSTextView, deliberately: wrapping SwiftUI Text in this pane
                    // creates a geometry feedback cycle (text height ↔ container
                    // width via legacy scrollers / split view) that spins the main
                    // thread at 100%. NSScrollView has no intrinsic size, so the
                    // log content cannot feed back into SwiftUI layout at all.
                    LogTextView(text: Self.transcript(of: entries))
                        .frame(minWidth: 300)
                }
            }
        }
        .task(id: selection) { await loadSelection() }
        .onAppear { selection = selection ?? runs.first?.id }
        .onChange(of: runs.map(\.id)) { _, ids in
            if selection.map(ids.contains) != true { selection = ids.first }
        }
        .alert("Clear all history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every recorded run for this automation.")
        }
        .alert("Could Not Clear History", isPresented: Binding(
            get: { clearError != nil },
            set: { if !$0 { clearError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(clearError ?? "")
        }
    }

    private func loadSelection() async {
        guard let selection else { entries = []; return }
        entries = await log.automationEntries(automationID: automationID, runID: selection)
    }

    private static func transcript(of entries: [AutomationLogEntry]) -> String {
        entries.map { entry in
            let time = entry.timestamp.map {
                " — " + $0.formatted(date: .omitted, time: .standard)
            } ?? ""
            return "── \(entry.kind)\(time)\n\(entry.text)"
        }
        .joined(separator: "\n\n")
    }

    private func clear() {
        Task {
            do {
                try await log.clearAutomationHistory(automationID)
                onClear()
            } catch {
                clearError = error.localizedDescription
            }
        }
    }
}

/// Read-only, selectable AppKit text view for run transcripts. AppKit's text
/// system wraps and scrolls internally without reporting an intrinsic size,
/// so large or oddly-wrapping content can never re-enter SwiftUI layout.
private struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
            textView.scroll(.zero)
        }
    }
}
