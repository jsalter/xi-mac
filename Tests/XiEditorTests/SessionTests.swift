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

import XCTest
@testable import XiEditor

private struct FakeDisk: DiskProbing {
    var stamps: [String: Session.DiskStamp]

    func stamp(of path: String) -> Session.DiskStamp {
        return stamps[path] ?? .missing
    }
}

class SessionTests: XCTestCase {

    let frame = CGRect(x: 10, y: 20, width: 300, height: 400)
    let stampA = Session.DiskStamp.present(byteCount: 12, modified: Date(timeIntervalSinceReferenceDate: 1000.5))
    let stampB = Session.DiskStamp.present(byteCount: 13, modified: Date(timeIntervalSinceReferenceDate: 2000))

    func buffer(_ content: Session.Content) -> Session.Buffer {
        return Session.Buffer(content: content, viewport: nil)
    }

    func session(_ tabs: [Session.Content], selectedTab: Int = 0) -> Session {
        let group = Session.TabGroup(frame: frame, tabs: tabs.map(buffer), selectedTab: selectedTab)
        return Session(groups: [group])
    }

    func decode(_ json: String) throws -> Session {
        return try JSONDecoder().decode(Session.self, from: json.data(using: .utf8)!)
    }


    func testDecodesLiteralFixtureForAllContentCases() throws {
        let json = """
        {"version":1,"groups":[{"frame":[[10,20],[300,400]],"selectedTab":1,"tabs":[
          {"content":{"untitled":{"text":"scratch"}},"viewport":{"topLine":3,"caret":{"line":4,"column":2}}},
          {"content":{"clean":{"path":"/a/clean.txt"}}},
          {"content":{"dirty":{"path":"/a/dirty.txt","onDisk":{"present":{"byteCount":12,"modified":1000.5}},"text":"edited"}}},
          {"content":{"dirty":{"path":"/a/new.txt","onDisk":{"missing":{}},"text":""}}}
        ]}]}
        """
        let expected = Session(groups: [Session.TabGroup(frame: frame, tabs: [
            Session.Buffer(content: .untitled(text: "scratch"),
                           viewport: Session.Viewport(topLine: 3, caret: Session.Caret(line: 4, column: 2))),
            buffer(.clean(path: "/a/clean.txt")),
            buffer(.dirty(path: "/a/dirty.txt", onDisk: stampA, text: "edited")),
            buffer(.dirty(path: "/a/new.txt", onDisk: .missing, text: ""))
        ], selectedTab: 1)])
        XCTAssertEqual(expected, try decode(json))
    }

    func testEncodeThenDecodeIsIdentity() throws {
        let original = session([.untitled(text: "héllo 🌍\n\ttab"), .clean(path: "/a/clean.txt"),
                                .dirty(path: "/a/dirty.txt", onDisk: stampA, text: "x")], selectedTab: 2)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(original, try JSONDecoder().decode(Session.self, from: data))
    }

    func testDecodesEmptySession() throws {
        XCTAssertEqual(Session(groups: []), try decode("{\"version\":1,\"groups\":[]}"))
    }

    func testDecodeRejectsEmptyTabs() {
        XCTAssertThrowsError(try decode("{\"version\":1,\"groups\":[{\"frame\":[[0,0],[1,1]],\"selectedTab\":0,\"tabs\":[]}]}"))
    }

    func testDecodeRejectsSelectedTabOutOfRange() throws {
        let original = session([.untitled(text: "a")], selectedTab: 1)
        let data = try JSONEncoder().encode(original)
        XCTAssertThrowsError(try JSONDecoder().decode(Session.self, from: data))
    }

    func testDecodeRejectsDuplicatePath() throws {
        let original = session([.clean(path: "/a/x.txt"), .dirty(path: "/a/x.txt", onDisk: stampA, text: "t")])
        let data = try JSONEncoder().encode(original)
        XCTAssertThrowsError(try JSONDecoder().decode(Session.self, from: data))
    }

    func testDecodeRejectsUnknownVersion() {
        XCTAssertThrowsError(try decode("{\"version\":2,\"groups\":[]}"))
    }


    func testUntitledIgnoresDisk() {
        let plan = session([.untitled(text: "scratch")]).restorePlan(disk: FakeDisk(stamps: [:]))
        XCTAssertEqual(1, plan.count)
        XCTAssertEqual(frame, plan[0].frame)
        XCTAssertEqual([RestoreAction(path: nil, replacement: "scratch", viewport: nil, conflict: nil)], plan[0].actions)
    }

    func testCleanReopensAtPathWhetherOrNotItChanged() {
        let content = Session.Content.clean(path: "/a/c.txt")
        for stamp in [stampA, stampB] {
            let plan = session([content]).restorePlan(disk: FakeDisk(stamps: ["/a/c.txt": stamp]))
            XCTAssertEqual([RestoreAction(path: "/a/c.txt", replacement: nil, viewport: nil, conflict: nil)], plan[0].actions)
        }
    }

    func testCleanWithMissingFileIsDroppedAndEmptyGroupGoes() {
        XCTAssertTrue(session([.clean(path: "/a/c.txt")]).restorePlan(disk: FakeDisk(stamps: [:])).isEmpty)
    }

    func testDirtyKeepsPathWhenDiskUnchanged() {
        let plan = session([.dirty(path: "/a/d.txt", onDisk: stampA, text: "edit")])
            .restorePlan(disk: FakeDisk(stamps: ["/a/d.txt": stampA]))
        XCTAssertEqual([RestoreAction(path: "/a/d.txt", replacement: "edit", viewport: nil, conflict: nil)], plan[0].actions)
    }

    func testDirtyChangedOnDiskKeepsPathAndTextAndFlagsConflict() {
        let plan = session([.dirty(path: "/a/d.txt", onDisk: stampA, text: "edit")])
            .restorePlan(disk: FakeDisk(stamps: ["/a/d.txt": stampB]))
        let expected = RestoreAction(path: "/a/d.txt", replacement: "edit", viewport: nil,
                                     conflict: .changedOnDisk(path: "/a/d.txt"))
        XCTAssertEqual([expected], plan[0].actions)
    }

    func testDirtyCreatedOnDiskSinceSuspendIsAConflict() {
        let plan = session([.dirty(path: "/a/d.txt", onDisk: .missing, text: "edit")])
            .restorePlan(disk: FakeDisk(stamps: ["/a/d.txt": stampA]))
        XCTAssertEqual(.changedOnDisk(path: "/a/d.txt"), plan[0].actions[0].conflict)
    }

    func testDirtyWithMissingFileReopensAtPathWithText() {
        for stored in [stampA, Session.DiskStamp.missing] {
            let plan = session([.dirty(path: "/a/d.txt", onDisk: stored, text: "edit")])
                .restorePlan(disk: FakeDisk(stamps: [:]))
            XCTAssertEqual([RestoreAction(path: "/a/d.txt", replacement: "edit", viewport: nil, conflict: nil)],
                           plan[0].actions)
        }
    }


    let viewport = Session.Viewport(topLine: 7, caret: Session.Caret(line: 8, column: 1))

    var conflicted: RestoreAction {
        return RestoreAction(path: "/a/d.txt", replacement: "edit", viewport: viewport,
                             conflict: .changedOnDisk(path: "/a/d.txt"))
    }

    func testKeepSuspendedEditsBindsTextToPath() {
        let expected = RestoreAction(path: "/a/d.txt", replacement: "edit", viewport: viewport, conflict: nil)
        XCTAssertEqual([expected], conflicted.resolved(.keepSuspendedEdits))
    }

    func testUseVersionOnDiskDropsSuspendedEdits() {
        let expected = RestoreAction(path: "/a/d.txt", replacement: nil, viewport: nil, conflict: nil)
        XCTAssertEqual([expected], conflicted.resolved(.useVersionOnDisk))
    }

    func testKeepBothOpensDiskVersionThenSuspendedEditsUntitled() {
        let onDisk = RestoreAction(path: "/a/d.txt", replacement: nil, viewport: nil, conflict: nil)
        let suspended = RestoreAction(path: nil, replacement: "edit", viewport: viewport, conflict: nil)
        XCTAssertEqual([onDisk, suspended], conflicted.resolved(.keepBoth))
    }

    func testResolvingAnActionWithoutConflictChangesNothing() {
        let plain = RestoreAction(path: "/a/d.txt", replacement: "edit", viewport: viewport, conflict: nil)
        for choice in [ConflictChoice.keepSuspendedEdits, .useVersionOnDisk, .keepBoth] {
            XCTAssertEqual([plain], plain.resolved(choice))
        }
    }

    func testViewportIsCarriedThrough() {
        let original = Session(groups: [Session.TabGroup(
            frame: frame,
            tabs: [Session.Buffer(content: .untitled(text: "a"), viewport: viewport)],
            selectedTab: 0)])
        XCTAssertEqual(viewport, original.restorePlan(disk: FakeDisk(stamps: [:]))[0].actions[0].viewport)
    }

    func testSelectedTabIsRepairedWhenEarlierTabsAreDropped() {
        let tabs: [Session.Content] = [.clean(path: "/gone1"), .untitled(text: "a"), .clean(path: "/gone2"), .untitled(text: "b")]
        let plan = session(tabs, selectedTab: 3).restorePlan(disk: FakeDisk(stamps: [:]))
        XCTAssertEqual(2, plan[0].actions.count)
        XCTAssertEqual(1, plan[0].selectedTab)
    }

    func testSelectedTabMovesToNextSurvivorWhenItIsDropped() {
        let tabs: [Session.Content] = [.untitled(text: "a"), .clean(path: "/gone"), .untitled(text: "b")]
        let plan = session(tabs, selectedTab: 1).restorePlan(disk: FakeDisk(stamps: [:]))
        XCTAssertEqual(1, plan[0].selectedTab)
    }

    func testSelectedTabClampsWhenLastTabIsDropped() {
        let tabs: [Session.Content] = [.untitled(text: "a"), .untitled(text: "b"), .clean(path: "/gone")]
        let plan = session(tabs, selectedTab: 2).restorePlan(disk: FakeDisk(stamps: [:]))
        XCTAssertEqual(1, plan[0].selectedTab)
    }

    func testGroupsKeepOrderAndEmptyGroupsAreDropped() {
        let second = CGRect(x: 50, y: 60, width: 100, height: 100)
        let original = Session(groups: [
            Session.TabGroup(frame: frame, tabs: [buffer(.untitled(text: "front"))], selectedTab: 0),
            Session.TabGroup(frame: second, tabs: [buffer(.clean(path: "/gone"))], selectedTab: 0),
            Session.TabGroup(frame: second, tabs: [buffer(.untitled(text: "back"))], selectedTab: 0)])
        let plan = original.restorePlan(disk: FakeDisk(stamps: [:]))
        XCTAssertEqual(["front", "back"], plan.map { $0.actions[0].replacement })
    }


    func testFitKeepsVisibleFrame() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(frame, Session.fit(frame, to: screens))
    }

    func testFitKeepsFrameVisibleOnASecondaryScreen() {
        let onSecond = CGRect(x: 1500, y: 100, width: 300, height: 300)
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(onSecond, Session.fit(onSecond, to: screens))
    }

    func testFitMovesOffscreenFrameToMainScreen() {
        let gone = CGRect(x: 5000, y: 100, width: 300, height: 400)
        let screens = [CGRect(x: 0, y: 25, width: 1000, height: 775)]
        XCTAssertEqual(CGRect(x: 0, y: 400, width: 300, height: 400), Session.fit(gone, to: screens))
    }

    func testFitShrinksFrameLargerThanMainScreen() {
        let huge = CGRect(x: 5000, y: 0, width: 4000, height: 3000)
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(CGRect(x: 0, y: 0, width: 1000, height: 800), Session.fit(huge, to: screens))
    }


    var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testStoreLoadReturnsNilWithoutFile() {
        XCTAssertNil(SessionStore(fileURL: directory.appendingPathComponent("session.json")).load())
    }

    func testStoreSaveThenLoadEquals() throws {
        let store = SessionStore(fileURL: directory.appendingPathComponent("nested").appendingPathComponent("session.json"))
        let original = session([.untitled(text: "a"), .dirty(path: "/a/d.txt", onDisk: stampA, text: "b")], selectedTab: 1)
        try store.save(original)
        XCTAssertEqual(original, store.load())
    }

    func testStoreCreatesDirectoryPrivate() throws {
        let store = SessionStore(fileURL: directory.appendingPathComponent("session.json"))
        try store.save(Session(groups: []))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(0o700, attributes[.posixPermissions] as? Int)
    }

    func testStoreSavingTwiceYieldsIdenticalBytes() throws {
        let url = directory.appendingPathComponent("session.json")
        let store = SessionStore(fileURL: url)
        let original = session([.untitled(text: "a"), .dirty(path: "/a/d.txt", onDisk: stampA, text: "b")])
        try store.save(original)
        let first = try Data(contentsOf: url)
        try store.save(original)
        XCTAssertEqual(first, try Data(contentsOf: url))
    }

    func testStoreQuarantinesGarbage() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let url = directory.appendingPathComponent("session.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(SessionStore(fileURL: url).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(1, names.filter { $0.hasPrefix("session.json.corrupt-") }.count)
    }

    func testStoreQuarantinesInvalidSession() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let url = directory.appendingPathComponent("session.json")
        try "{\"version\":99,\"groups\":[]}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(SessionStore(fileURL: url).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }


    func testProbeReportsMissingAndPresent() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let file = directory.appendingPathComponent("f.txt")
        XCTAssertEqual(.missing, FileSystemProbe().stamp(of: file.path))
        try "12345".write(to: file, atomically: true, encoding: .utf8)
        guard case .present(let size, _) = FileSystemProbe().stamp(of: file.path) else {
            return XCTFail("expected present")
        }
        XCTAssertEqual(5, size)
    }
}
