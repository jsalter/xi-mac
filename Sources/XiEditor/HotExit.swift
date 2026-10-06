// Copyright 2026 The xi-editor Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Cocoa

struct TextUnreadableError: LocalizedError {
    let name: String

    var errorDescription: String? {
        return "the text of “\(name)” could not be read"
    }
}

/// Makes quitting a suspend: `suspend()` writes every window's buffer into the session store, and
/// `resume()` on the next launch builds the windows back.
final class HotExit {
    enum Phase {
        case dormant
        /// Restored documents that have not yet been given a core view.
        case restoring(pendingViews: Int)
        case live
    }

    enum Outcome {
        case suspended
        case refused(reason: String)
    }

    private let store: SessionStore
    private let documents: XiDocumentController
    private(set) var phase = Phase.dormant
    private(set) var restoredAnyWindow = false

    init(store: SessionStore, documents: XiDocumentController) {
        self.store = store
        self.documents = documents
    }

    /// Writes the session unless the app is not live. Until every restored document has its core view the
    /// text of some buffers cannot be read, and the stored session is exactly the state being restored.
    func suspend() -> Outcome {
        guard case .live = phase else { return .suspended }
        do {
            let session = try capture()
            try session.validate()
            try store.save(session)
            return .suspended
        } catch {
            return .refused(reason: error.localizedDescription)
        }
    }

    /// Runs once and never writes the store.
    func resume() {
        guard case .dormant = phase else { return }
        guard let session = store.load() else {
            phase = .live
            return
        }
        let plan = session.restorePlan(disk: FileSystemProbe()).map(resolvingConflicts)
        restoredAnyWindow = !plan.isEmpty
        let total = plan.reduce(0) { $0 + $1.actions.count }
        phase = total == 0 ? .live : .restoring(pendingViews: total)
        let screens = NSScreen.screens.map { $0.visibleFrame }
        for group in plan.reversed() {
            var windows = [NSWindow]()
            for action in group.actions {
                do {
                    let document = try documents.restoreDocument(action) { [weak self] in self?.documentIsReady() }
                    if let window = document.windowControllers.first?.window { windows.append(window) }
                } catch {
                    documentIsReady()
                }
            }
            arrange(windows, selected: group.selectedTab, frame: Session.fit(group.frame, to: screens))
        }
    }

    /// Joins `windows` into one native tab group in order, then shows it. Called back to front, so the
    /// first group ends up frontmost.
    private func arrange(_ windows: [NSWindow], selected: Int, frame: CGRect) {
        guard let anchor = windows.first else { return }
        if #available(OSX 10.12, *) {
            // Each tab goes right after the previous one, which keeps the stored order.
            var previous = anchor
            for window in windows.dropFirst() {
                previous.addTabbedWindow(window, ordered: .above)
                previous = window
            }
        }
        let front = windows[min(selected, windows.count - 1)]
        if #available(OSX 10.13, *) {
            front.tabGroup?.selectedWindow = front
        }
        front.makeKeyAndOrderFront(nil)
        front.setFrame(frame, display: true)
    }

    private func documentIsReady() {
        guard case .restoring(let pending) = phase else { return }
        phase = pending > 1 ? .restoring(pendingViews: pending - 1) : .live
    }

    private func capture() throws -> Session {
        var groups = [Session.TabGroup]()
        var grouped = Set<NSWindow>()
        for window in NSApp.orderedWindows where !grouped.contains(window) && document(of: window) != nil {
            let members = tabs(of: window)
            grouped.formUnion(members)
            let buffers = try members.compactMap { try document(of: $0)?.sessionBuffer() }
            groups.append(Session.TabGroup(frame: window.frame, tabs: buffers, selectedTab: selectedIndex(of: window, in: members)))
        }
        return Session(groups: groups)
    }

    private func document(of window: NSWindow) -> Document? {
        return window.windowController?.document as? Document
    }

    /// The document windows sharing `window`'s native tab group, in tab order.
    private func tabs(of window: NSWindow) -> [NSWindow] {
        guard #available(OSX 10.12, *), let tabbed = window.tabbedWindows else { return [window] }
        return tabbed.filter { document(of: $0) != nil }
    }

    private func selectedIndex(of window: NSWindow, in members: [NSWindow]) -> Int {
        guard #available(OSX 10.13, *), let selected = window.tabGroup?.selectedWindow else { return 0 }
        return members.firstIndex(of: selected) ?? 0
    }

    private func resolvingConflicts(in group: Session.PlannedGroup) -> Session.PlannedGroup {
        var actions = [RestoreAction]()
        var selectedTab = group.selectedTab
        for (index, action) in group.actions.enumerated() {
            let resolved = resolve(action)
            if index < group.selectedTab { selectedTab += resolved.count - 1 }
            actions += resolved
        }
        return (group.frame, actions, selectedTab)
    }

    private func resolve(_ action: RestoreAction) -> [RestoreAction] {
        guard case .changedOnDisk(let path)? = action.conflict else { return [action] }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\((path as NSString).lastPathComponent)” changed on disk while XiEditor was suspended."
        alert.informativeText = "Your suspended edits and the file on disk have diverged."
        alert.addButton(withTitle: "Keep Suspended Edits")
        alert.addButton(withTitle: "Use Version on Disk")
        alert.addButton(withTitle: "Keep Both")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return action.resolved(.useVersionOnDisk)
        case .alertThirdButtonReturn: return action.resolved(.keepBoth)
        default: return action.resolved(.keepSuspendedEdits)
        }
    }
}
