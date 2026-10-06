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
        for group in plan.reversed() {
            for action in group.actions {
                do {
                    try documents.restoreDocument(action) { [weak self] in self?.documentIsReady() }
                } catch {
                    documentIsReady()
                }
            }
        }
    }

    private func documentIsReady() {
        guard case .restoring(let pending) = phase else { return }
        phase = pending > 1 ? .restoring(pendingViews: pending - 1) : .live
    }

    private func capture() throws -> Session {
        var groups = [Session.TabGroup]()
        for window in NSApp.orderedWindows {
            guard let document = window.windowController?.document as? Document else { continue }
            groups.append(Session.TabGroup(frame: window.frame, tabs: [try document.sessionBuffer()], selectedTab: 0))
        }
        return Session(groups: groups)
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
