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

struct Session: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = Session.currentVersion
    var groups: [TabGroup]

    struct TabGroup: Codable, Equatable {
        var frame: CGRect
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

    enum DiskStamp: Codable, Equatable {
        case missing
        case present(byteCount: UInt64, modified: Date)
    }

    struct Viewport: Codable, Equatable {
        var topLine: Int
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

struct RestoreAction: Equatable {
    var path: String?
    var replacement: String?
    var viewport: Session.Viewport?
    var conflict: Conflict?

    enum Conflict: Equatable {
        case changedOnDisk(path: String)
    }
}

extension RestoreAction {
    /// The buffer this action would have opened, for carrying it into the next session.
    var buffer: Session.Buffer {
        let content: Session.Content
        switch (path, replacement) {
        case (let path?, let text?):
            content = .dirty(path: path, onDisk: FileSystemProbe().stamp(of: path), text: text)
        case (let path?, nil):
            content = .clean(path: path)
        case (nil, let text):
            content = .untitled(text: text ?? "")
        }
        return Session.Buffer(content: content, viewport: viewport)
    }
}

enum ConflictChoice {
    case keepSuspendedEdits
    case useVersionOnDisk
    case keepBoth
}

extension RestoreAction {
    func resolved(_ choice: ConflictChoice) -> [RestoreAction] {
        guard conflict != nil else { return [self] }
        let suspended = RestoreAction(path: path, replacement: replacement, viewport: viewport, conflict: nil)
        let onDisk = RestoreAction(path: path, replacement: nil, viewport: nil, conflict: nil)
        switch choice {
        case .keepSuspendedEdits:
            return [suspended]
        case .useVersionOnDisk:
            return [onDisk]
        case .keepBoth:
            var untitled = suspended
            untitled.path = nil
            return [onDisk, untitled]
        }
    }
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

    func restorePlan(disk: DiskProbing) -> [PlannedGroup] {
        return groups.compactMap { group in
            var actions = [RestoreAction]()
            var selectedSurvivor = 0
            for (index, buffer) in group.tabs.enumerated() {
                if index == group.selectedTab { selectedSurvivor = actions.count }
                guard let action = Session.action(for: buffer, disk: disk) else { continue }
                actions.append(action)
            }
            guard !actions.isEmpty else { return nil }
            return (group.frame, actions, min(selectedSurvivor, actions.count - 1))
        }
    }

    private static func action(for buffer: Buffer, disk: DiskProbing) -> RestoreAction? {
        switch buffer.content {
        case .untitled(let text):
            return RestoreAction(path: nil, replacement: text, viewport: buffer.viewport, conflict: nil)
        case .clean(let path):
            guard disk.stamp(of: path) != .missing else { return nil }
            return RestoreAction(path: path, replacement: nil, viewport: buffer.viewport, conflict: nil)
        case .dirty(let path, let stored, let text):
            let current = disk.stamp(of: path)
            let changed = current != .missing && current != stored
            return RestoreAction(path: path, replacement: text, viewport: buffer.viewport,
                                 conflict: changed ? .changedOnDisk(path: path) : nil)
        }
    }

    static func fit(_ frame: CGRect, to visibleFramesMainFirst: [CGRect]) -> CGRect {
        guard let main = visibleFramesMainFirst.first,
            !visibleFramesMainFirst.contains(where: { $0.intersects(frame) })
            else { return frame }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(origin: CGPoint(x: main.minX, y: main.maxY - size.height), size: size)
    }
}

struct SessionStore {
    let fileURL: URL

    func save(_ session: Session) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(session)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
    }

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
