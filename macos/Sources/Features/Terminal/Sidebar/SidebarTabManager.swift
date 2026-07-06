import Cocoa
import Combine
import GhosttyKit

/// Observes the tab group of a window and publishes tab metadata for the sidebar.
class SidebarTabManager: ObservableObject {
    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let pwd: String?
        let metadata: [String: String]
        let isSelected: Bool
        let needsAttention: Bool
        let window: NSWindow

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return (pwd as NSString).lastPathComponent
        }

        /// Title with bell emoji stripped (the sidebar uses its own attention indicator).
        var displayTitle: String {
            title.hasPrefix("🔔 ") ? String(title.dropFirst(3)) : title
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.isSelected == rhs.isSelected
                && lhs.pwd == rhs.pwd && lhs.metadata == rhs.metadata
                && lhs.needsAttention == rhs.needsAttention
        }
    }

    @Published var tabs: [TabItem] = []

    /// Windows that need attention, cleared when the tab is selected.
    private var attentionWindows: Set<ObjectIdentifier> = []

    /// Whether bells should trigger the sidebar attention indicator.
    /// Derived from `bell-features` containing `attention`.
    private let bellTriggersAttention: Bool

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    /// Combine subscriptions to the currently-selected surface's pwd/title, so
    /// the active tab updates instantly instead of waiting for the next poll.
    private var surfaceCancellables: Set<AnyCancellable> = []
    private var observedSurfaceID: ObjectIdentifier?

    /// Fallback poll interval. Covers changes that have no change event of their
    /// own (sidebar metadata like the git branch, and background tabs' pwd/title).
    /// The active tab's pwd/title are handled by Combine, and tab add/remove +
    /// selection are handled by the key-window notifications, so this can be
    /// relatively slow. The timer only runs while the window is on-screen.
    private let pollInterval: TimeInterval = 1.0

    init(window: NSWindow, bellTriggersAttention: Bool = true) {
        self.window = window
        self.bellTriggersAttention = bellTriggersAttention
        setupObservers()
        refresh()
    }

    deinit {
        timer?.invalidate()
        surfaceCancellables.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        let titleObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePollingState()
            self?.refresh()
        }
        observers.append(titleObserver)

        let resignObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        observers.append(resignObserver)

        // Bell: respect bell-features config
        if bellTriggersAttention {
            let bellObserver = center.addObserver(
                forName: .terminalWindowBellDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let controller = notification.object as? BaseTerminalController,
                      let w = controller.window else { return }
                let hasBell = notification.userInfo?[Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
                if hasBell {
                    self.markAttention(window: w)
                }
            }
            observers.append(bellObserver)
        }

        // Desktop notifications (OSC 9/99, command completion): always trigger attention
        let desktopNotifObserver = center.addObserver(
            forName: .ghosttyDesktopNotificationDidFire,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceView = notification.object as? Ghostty.SurfaceView,
                  let w = surfaceView.window else { return }
            self.markAttention(window: w)
        }
        observers.append(desktopNotifObserver)

        // Pause the fallback poll whenever the window leaves the screen
        // (minimized, hidden, on another Space, or fully covered) and resume it
        // when the window becomes visible again. A backgrounded window then does
        // no polling at all.
        let occlusionObserver = center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let w = notification.object as? NSWindow, w === self.window else { return }
            self.updatePollingState()
        }
        observers.append(occlusionObserver)

        updatePollingState()
    }

    // MARK: - Polling

    /// Start or stop the fallback poll based on whether the window is on-screen.
    private func updatePollingState() {
        guard let window, window.occlusionState.contains(.visible) else {
            stopTimer()
            return
        }
        startTimer()
        // Catch up on anything missed while we weren't polling.
        refresh()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopTimer() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Subscribe to the selected surface's pwd/title so the active tab refreshes
    /// the instant they change, rather than on the next poll tick.
    private func observeSelectedSurface(_ surface: Ghostty.SurfaceView?) {
        let newID = surface.map(ObjectIdentifier.init)
        guard newID != observedSurfaceID else { return }
        observedSurfaceID = newID
        surfaceCancellables.removeAll()
        guard let surface else { return }

        surface.$pwd
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &surfaceCancellables)

        surface.$title
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &surfaceCancellables)
    }

    // MARK: - Attention

    private func markAttention(window w: NSWindow) {
        attentionWindows.insert(ObjectIdentifier(w))
        refresh()
    }

    private func clearAttention(for id: ObjectIdentifier) {
        attentionWindows.remove(id)
    }

    // MARK: - Refresh

    func refresh() {
        guard let window else { return }

        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            tabWindows = [window]
        }

        let selectedWindow = window.tabGroup?.selectedWindow ?? window

        // Keep the Combine subscription pointed at the currently-selected surface.
        let selectedController = selectedWindow.windowController as? BaseTerminalController
        observeSelectedSurface(selectedController?.focusedSurface)

        let newTabs = tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let wid = ObjectIdentifier(w)

            return TabItem(
                id: wid,
                title: w.title,
                pwd: surface?.pwd,
                metadata: surface?.sidebarMetadata ?? [:],
                isSelected: w === selectedWindow,
                needsAttention: attentionWindows.contains(wid) && w !== selectedWindow,
                window: w
            )
        }

        if newTabs != tabs {
            tabs = newTabs
        }
    }

    // MARK: - Tab Actions

    func selectTab(_ tab: TabItem) {
        clearAttention(for: tab.id)
        tab.window.makeKeyAndOrderFront(nil)
    }

    func closeTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? TerminalController else { return }
        controller.closeTab(nil)
    }

    func renameTab(_ tab: TabItem, to newTitle: String) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.titleOverride = newTitle.isEmpty ? nil : newTitle
        refresh()
    }

    func promptRenameTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.promptTabTitle()
    }

    func closeOtherTabs(_ tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        for w in tabWindows where ObjectIdentifier(w) != tab.id {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard let window else { return }
        guard let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty else { return }
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < tabbedWindows.count,
              destinationIndex >= 0, destinationIndex < tabbedWindows.count else { return }

        let movingWindow = tabbedWindows[sourceIndex]
        let targetWindow = tabbedWindows[destinationIndex]

        if sourceIndex > destinationIndex {
            targetWindow.addTabbedWindow(movingWindow, ordered: .below)
        } else {
            targetWindow.addTabbedWindow(movingWindow, ordered: .above)
        }

        if let selectedWindow = window.tabGroup?.selectedWindow {
            selectedWindow.makeKeyAndOrderFront(nil)
        }

        refresh()
    }

    func closeTabsToTheRight(of tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        guard let idx = tabWindows.firstIndex(where: { ObjectIdentifier($0) == tab.id }) else { return }
        for w in tabWindows[(idx + 1)...] {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }
}
