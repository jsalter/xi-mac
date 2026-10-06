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

import Foundation

/// Everything needed to bring the app back as it was after a quit.
struct Session: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = Session.currentVersion
    /// Front to back: index 0 is the key window's group. May be empty.
    var groups: [TabGroup]

    struct TabGroup: Codable, Equatable {
        /// The group's window frame in screen coordinates.
        var frame: CGRect
        /// In tab order. Never empty.
        var tabs: [Buffer]
        var selectedTab: Int
    }

    struct Buffer: Codable, Equatable {
        var content: Content
        var viewport: Viewport?
    }

    enum Content: Codable, Equatable {
        case untitled(text: String)
        case clean(path: String)
        case dirty(path: String, onDisk: DiskStamp, text: String)
    }

    /// Size and modification date of the file a dirty buffer was derived from.
    enum DiskStamp: Codable, Equatable {
        case missing
        case present(byteCount: UInt64, modified: Date)
    }

    struct Viewport: Codable, Equatable {
        var topLine: Int
        /// Nil when the caret was not within the visible lines.
        var caret: Caret?
    }

    /// Column is in UTF-8 units, as core uses.
    struct Caret: Codable, Equatable {
        var line: Int
        var column: Int
    }

    private enum CodingKeys: String, CodingKey {
        case version, groups
    }
}

extension Session {
    enum ValidationError: Error {
        case unknownVersion(Int)
        case emptyGroup
        case selectedTabOutOfRange
        case duplicatePath(String)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        groups = try container.decode([TabGroup].self, forKey: .groups)
        try validate()
    }

    func validate() throws {
        guard version == Session.currentVersion else { throw ValidationError.unknownVersion(version) }
        var seen = Set<String>()
        for group in groups {
            guard !group.tabs.isEmpty else { throw ValidationError.emptyGroup }
            guard group.tabs.indices.contains(group.selectedTab) else { throw ValidationError.selectedTabOutOfRange }
            for path in group.tabs.compactMap({ $0.content.path }) {
                guard seen.insert(path).inserted else { throw ValidationError.duplicatePath(path) }
            }
        }
    }
}

extension Session.Content {
    var path: String? {
        switch self {
        case .untitled: return nil
        case .clean(let path), .dirty(let path, _, _): return path
        }
    }
}

/// What to do for one buffer, computed from the stored session and the current disk state.
struct RestoreAction: Equatable {
    /// What `new_view` gets; nil is untitled.
    var path: String?
    /// Text to `select_all` and `insert` once the view exists.
    var replacement: String?
    var viewport: Session.Viewport?
    /// A line for the user explaining a non-obvious restore.
    var note: String?
}

protocol DiskProbing {
    func stamp(of path: String) -> Session.DiskStamp
}

struct FileSystemProbe: DiskProbing {
    func stamp(of path: String) -> Session.DiskStamp {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? UInt64,
            let modified = attributes[.modificationDate] as? Date
            else { return .missing }
        return .present(byteCount: size, modified: modified)
    }
}

extension Session {
    typealias PlannedGroup = (frame: CGRect, actions: [RestoreAction], selectedTab: Int)

    /// Decides each buffer's action. A clean buffer whose file is gone is dropped (and a group that
    /// empties with it). A dirty buffer whose file changed since the suspend comes back untitled so a later
    /// save cannot overwrite the newer file; one whose file is missing reopens at its path.
    func restorePlan(disk: DiskProbing) -> [PlannedGroup] {
        return groups.compactMap { group in
            var actions = [RestoreAction]()
            var selected = 0
            for (index, buffer) in group.tabs.enumerated() {
                // If the selected tab is dropped, this is the index of the next survivor.
                if index == group.selectedTab { selected = actions.count }
                guard let action = Session.action(for: buffer, disk: disk) else { continue }
                actions.append(action)
            }
            guard !actions.isEmpty else { return nil }
            return (group.frame, actions, min(selected, actions.count - 1))
        }
    }

    private static func action(for buffer: Buffer, disk: DiskProbing) -> RestoreAction? {
        switch buffer.content {
        case .untitled(let text):
            return RestoreAction(path: nil, replacement: text, viewport: buffer.viewport, note: nil)
        case .clean(let path):
            guard disk.stamp(of: path) != .missing else { return nil }
            return RestoreAction(path: path, replacement: nil, viewport: buffer.viewport, note: nil)
        case .dirty(let path, let stored, let text):
            let current = disk.stamp(of: path)
            if current == .missing || current == stored {
                return RestoreAction(path: path, replacement: text, viewport: buffer.viewport, note: nil)
            }
            let name = (path as NSString).lastPathComponent
            return RestoreAction(path: nil, replacement: text, viewport: buffer.viewport,
                                 note: "\(name) changed on disk; suspended edits reopened as a new buffer")
        }
    }

    /// Returns `frame` if it is visible on some screen, otherwise a frame of the same size (limited to the
    /// first screen's size) at the top left of the first screen. `visibleFrames` lists the main screen first.
    static func fit(_ frame: CGRect, to visibleFrames: [CGRect]) -> CGRect {
        guard let main = visibleFrames.first,
            !visibleFrames.contains(where: { $0.intersects(frame) })
            else { return frame }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(origin: CGPoint(x: main.minX, y: main.maxY - size.height), size: size)
    }
}

struct SessionStore {
    let fileURL: URL

    /// Writes atomically so a crash mid-write leaves the previous session intact.
    func save(_ session: Session) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(session)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
    }

    /// Nil when there is no usable session. A file that fails to decode or validate is renamed aside
    /// rather than deleted, so the user's text is never destroyed by a bug here.
    func load() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let quarantined = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp)")
            try? FileManager.default.moveItem(at: fileURL, to: quarantined)
            return nil
        }
    }
}
