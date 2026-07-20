import AppKit
import SwiftUI
import HwhisperCore

/// Whether completed dictations are recorded to the local history store.
/// On by default; the store is local-only (0600 SQLite file), but the user
/// can still opt out entirely from Settings.
enum HistorySettings {
    private static let enabledKey = "historyEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

extension Notification.Name {
    /// Posted by `AppDelegate` after a dictation is saved to history so an
    /// open history view refreshes live instead of requiring a reopen.
    static let hwhisperHistoryDidRecord = Notification.Name("hwhisperHistoryDidRecord")
}

// MARK: - Main window content

private enum MainSection: String, CaseIterable, Identifiable {
    case home
    case history
    case dictionary
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "홈"
        case .history: "히스토리"
        case .dictionary: "개인 사전"
        case .settings: "설정"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

/// The app's main window (§BACKLOG v0.2-1 "독립 앱 형태"): a sidebar shell
/// that hosts history today and is the future home of 개인 사전 etc. The
/// dictation pipeline itself never depends on this window being open.
struct MainView: View {
    let historyStore: SQLiteHistoryStore
    let personalDictionary: FilePersonalDictionary
    /// 홈이 기본 진입 탭 — "열자마자 히스토리가 나와 사용성이 떨어진다"는
    /// 피드백 반영. 히스토리는 사이드바/메뉴(⌘Y)로 한 단계 뒤에 둔다.
    @State private var selection: MainSection = .home

    init(
        historyStore: SQLiteHistoryStore,
        personalDictionary: FilePersonalDictionary,
        initialSection: String? = nil
    ) {
        self.historyStore = historyStore
        self.personalDictionary = personalDictionary
        if let initialSection, let section = MainSection(rawValue: initialSection) {
            _selection = State(initialValue: section)
        }
    }

    var body: some View {
        NavigationSplitView {
            // 브랜드 그라운드: 시스템 사이드바 머티리얼 대신 먹(ink) 고정 —
            // "일반 맥 앱처럼 보인다"는 피드백에 따라 브랜드 보드의 단일
            // 잉크 세계를 창 자체에 입힌다 (창 외형은 컨트롤러에서 darkAqua
            // 고정).
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    BrandGlyph(height: 17)
                    Text("hwhisper")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)

                List(MainSection.allCases, selection: Binding(get: { selection }, set: { selection = $0 ?? .history })) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
                .scrollContentBackground(.hidden)
            }
            .background(Brand.ink)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 230)
        } detail: {
            switch selection {
            case .home:
                HomeView(
                    store: historyStore,
                    onOpenSettings: { selection = .settings },
                    onOpenHistory: { selection = .history }
                )
            case .history:
                HistoryListView(store: historyStore)
            case .dictionary:
                DictionaryView(dictionary: personalDictionary)
            case .settings:
                ScrollView {
                    SettingsView(embedded: true)
                        .frame(maxWidth: 560)
                        .padding(.vertical, 12)
                }
                .background(Brand.inkDeep)
                .navigationTitle("설정")
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .tint(Brand.accent)
    }
}

// MARK: - History

private struct HistoryListView: View {
    let store: SQLiteHistoryStore
    @State private var items: [HistoryItem] = []
    @State private var query = ""
    @State private var loadError: String?
    @State private var confirmingDeleteAll = false
    /// Row IDs whose "복사됨" feedback is currently showing.
    @State private var copiedIDs: Set<UUID> = []

    private static let searchLimit = 300

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("히스토리를 불러올 수 없습니다", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if items.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("아직 기록이 없습니다")
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Brand.accent)
                        }
                    } description: {
                        Text(HistorySettings.isEnabled
                            ? "딕테이션을 마치면 결과가 여기에 쌓입니다."
                            : "설정에서 '히스토리 저장'이 꺼져 있습니다.")
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                List(items) { item in
                    HistoryRow(
                        item: item,
                        showsCopied: copiedIDs.contains(item.id),
                        onCopy: { copy(item.insertedText, id: item.id) },
                        onCopyRaw: { copy(item.rawText, id: item.id) },
                        onDelete: { delete(item) }
                    )
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.inkDeep)
        .searchable(text: $query, placement: .toolbar, prompt: "히스토리 검색")
        .navigationTitle("히스토리")
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    confirmingDeleteAll = true
                } label: {
                    Label("전체 삭제", systemImage: "trash")
                }
                .disabled(items.isEmpty && query.isEmpty)
                .help("모든 히스토리 삭제")
            }
        }
        .confirmationDialog("모든 히스토리를 삭제할까요?", isPresented: $confirmingDeleteAll) {
            Button("전체 삭제", role: .destructive) { deleteAll() }
        } message: {
            Text("삭제된 기록은 되돌릴 수 없습니다.")
        }
        .task { await reload() }
        .onChange(of: query) { _, _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hwhisperHistoryDidRecord)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        do {
            items = try await store.search(query: query, limit: Self.searchLimit)
            loadError = nil
        } catch {
            HwhisperLog.log("history: load failed: \(error)")
            loadError = String(describing: error)
        }
    }

    private func copy(_ text: String, id: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedIDs.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedIDs.remove(id)
        }
    }

    private func delete(_ item: HistoryItem) {
        Task {
            do {
                try await store.delete(id: item.id)
                await reload()
            } catch {
                HwhisperLog.log("history: delete failed: \(error)")
            }
        }
    }

    private func deleteAll() {
        Task {
            do {
                try await store.deleteAll()
                await reload()
            } catch {
                HwhisperLog.log("history: deleteAll failed: \(error)")
            }
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let showsCopied: Bool
    let onCopy: () -> Void
    let onCopyRaw: () -> Void
    let onDelete: () -> Void

    @State private var showsRaw = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E) HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.dateFormatter.string(from: item.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let appName {
                    Text(appName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                outcomeBadge
                Spacer()
                Button {
                    onCopy()
                } label: {
                    Label(showsCopied ? "복사됨" : "복사", systemImage: showsCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        // List 행 안의 borderless 버튼은 상위 .tint가 닿지
                        // 않아 시스템 파랑으로 새는 것을 실화면에서 확인 —
                        // 브랜드 청자를 직접 지정한다.
                        .foregroundStyle(Brand.accent)
                }
                .buttonStyle(.borderless)
            }

            Text(item.insertedText)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(showsRaw ? nil : 4)

            if item.refinedText != nil {
                DisclosureGroup(isExpanded: $showsRaw) {
                    Text(item.rawText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Text("정제 전 원본")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("삽입된 텍스트 복사") { onCopy() }
            if item.refinedText != nil {
                Button("정제 전 원본 복사") { onCopyRaw() }
            }
            Divider()
            Button("삭제", role: .destructive) { onDelete() }
        }
    }

    /// Human-readable app name resolved from the stored bundle ID; falls
    /// back to the bundle ID's last component for apps no longer installed.
    private var appName: String? {
        guard let bundleID = item.targetBundleID else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID.components(separatedBy: ".").last
    }

    @ViewBuilder
    private var outcomeBadge: some View {
        switch item.outcome {
        case "inserted":
            EmptyView()
        case "clipboard":
            Text("클립보드")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.blue.opacity(0.15), in: Capsule())
                .foregroundStyle(.blue)
        default:
            Text("삽입 실패")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Personal dictionary

/// CRUD screen for the personal dictionary (§3 N-3, BACKLOG v0.2-3).
/// Changes take effect on the next dictation — `AppDelegate` reads the
/// shared `FilePersonalDictionary` actor at pipeline time, so there is no
/// stale-cache path to invalidate here.
private struct DictionaryView: View {
    let dictionary: FilePersonalDictionary
    @State private var entries: [DictionaryEntry] = []
    /// Non-nil while the editor sheet is up; a fresh entry (empty term)
    /// means "add", an existing one means "edit".
    @State private var editorState: DictionaryEditorState?

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("개인 사전이 비어 있습니다")
                    } icon: {
                        Image(systemName: "character.book.closed")
                            .foregroundStyle(Brand.accent)
                    }
                } description: {
                    Text("자주 틀리는 이름·서비스명·전문 용어를 등록하면 인식(바이어싱) → 정제(보호) → 최종 치환 3단계에서 항상 올바른 표기로 나옵니다.")
                } actions: {
                    Button("용어 추가") { editorState = .add }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.term).font(.body.weight(.semibold))
                        if !entry.variants.isEmpty {
                            Text("치환 대상: \(entry.variants.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editorState = .edit(entry) }
                    .contextMenu {
                        Button("수정") { editorState = .edit(entry) }
                        Button("삭제", role: .destructive) { delete(entry) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.inkDeep)
        .navigationTitle("개인 사전")
        .toolbar {
            ToolbarItem {
                Button {
                    editorState = .add
                } label: {
                    Label("용어 추가", systemImage: "plus")
                }
                .help("용어 추가")
            }
        }
        .sheet(item: $editorState) { state in
            DictionaryEntryEditor(state: state) { term, variants in
                Task {
                    switch state {
                    case .add:
                        await dictionary.add(term: term, variants: variants)
                    case .edit(let original):
                        await dictionary.update(DictionaryEntry(id: original.id, term: term, variants: variants))
                    }
                    await reload()
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        entries = await dictionary.entries()
    }

    private func delete(_ entry: DictionaryEntry) {
        Task {
            await dictionary.delete(id: entry.id)
            await reload()
        }
    }
}

private enum DictionaryEditorState: Identifiable {
    case add
    case edit(DictionaryEntry)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let entry): entry.id.uuidString
        }
    }
}

private struct DictionaryEntryEditor: View {
    let state: DictionaryEditorState
    let onSave: (String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var variantsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "용어 수정" : "용어 추가")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("올바른 표기 (예: 옴씨)", text: $term)
                Text("인식 힌트와 정제 보호에 그대로 쓰이는 최종 표기입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("잘못 나오는 표기들 — 쉼표로 구분 (예: 옴 씨, 옴시)", text: $variantsText)
                Text("전사/정제 결과에 이 표기가 나타나면 위의 올바른 표기로 자동 치환됩니다. 비워 둬도 인식 힌트·정제 보호는 동작합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "저장" : "추가") {
                    onSave(
                        term.trimmingCharacters(in: .whitespacesAndNewlines),
                        variantsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if case .edit(let entry) = state {
                term = entry.term
                variantsText = entry.variants.joined(separator: ", ")
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = state { return true }
        return false
    }
}

// MARK: - Window controller

/// Owns the main app window. While the window is open the process promotes
/// itself to a regular app (Dock icon, ⌘-tab entry — the "독립 앱" feel the
/// user asked for); closing it demotes back to the accessory/menu-bar-only
/// policy so day-to-day dictation stays unobtrusive.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let historyStore: SQLiteHistoryStore
    private let personalDictionary: FilePersonalDictionary
    private var window: NSWindow?

    init(historyStore: SQLiteHistoryStore, personalDictionary: FilePersonalDictionary) {
        self.historyStore = historyStore
        self.personalDictionary = personalDictionary
    }

    private func makeRootView(section: String?) -> MainView {
        MainView(historyStore: historyStore, personalDictionary: personalDictionary, initialSection: section)
    }

    /// `activate: false` shows the window without yanking focus from the
    /// frontmost app — used by the `--no-activate` test hook so visual
    /// verification doesn't interrupt whatever the user is doing.
    func show(section: String? = nil, activate: Bool = true) {
        NSApp.setActivationPolicy(.regular)

        if let window {
            if let section {
                window.contentView = NSHostingView(rootView: makeRootView(section: section))
            }
            if activate { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
            HwhisperLog.log("main window shown: section=\(section ?? "(kept)") number=\(window.windowNumber)")
            return
        }

        let hostingView = NSHostingView(rootView: makeRootView(section: section))
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "hwhisper"
        // 브랜드 외형: 시스템 라이트/다크와 무관하게 먹(ink) 세계로 고정 —
        // 브랜드 보드의 단일 잉크 그라운드 결정을 창 전체(타이틀바 포함)에
        // 적용한다. 타이틀바는 투명하게 눌러 사이드바/콘텐츠 잉크가 끝까지
        // 차오르게 한다.
        newWindow.appearance = NSAppearance(named: .darkAqua)
        newWindow.backgroundColor = Brand.inkDeepNSColor
        newWindow.titlebarAppearsTransparent = true
        newWindow.contentView = hostingView
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()
        newWindow.setFrameAutosaveName("HwhisperMainWindow")
        window = newWindow

        if activate { NSApp.activate(ignoringOtherApps: true) }
        newWindow.makeKeyAndOrderFront(nil)
        // 무음 실패 금지: "창이 안 뜬다" 류 보고를 로그만으로 판별할 수
        // 있도록 표시 사실·프레임·윈도우 번호를 남긴다 (screencapture -l
        // 검증 훅이기도 함).
        HwhisperLog.log("main window shown: section=\(section ?? "default") frame=\(newWindow.frame) number=\(newWindow.windowNumber)")
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only once the main window goes away, unless some
        // other regular window (e.g. Settings opened standalone) is visible.
        DispatchQueue.main.async {
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey && $0 !== self.window }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
