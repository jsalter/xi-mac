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

/// Proves, against a real xi-core, the core behavior hot exit depends on: text can be put into a view
/// without touching its file, and read back exactly, with every earlier edit already applied.
class SessionRoundTripTests: XCTestCase {

    var directory: URL!
    var client: TestClientImplementation!
    var xiCore: XiCore!
    var dirtyUpdate: XCTestExpectation?

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRoundTripTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        client = TestClientImplementation(updateAction: { [unowned self] _, params in
            if !params.pristine {
                self.dirtyUpdate?.fulfill()
            }
        })
        guard let corePath = Bundle.main.path(forResource: "xi-core", ofType: "")
            else { fatalError("Xi bundle is missing xi-core") }
        let rpcSender = StdoutRPCSender(path: corePath, errorLogDirectory: nil)
        rpcSender.client = client
        xiCore = CoreConnection(rpcSender: rpcSender)
        xiCore.clientStarted(configDir: nil, clientExtrasDir: nil)
    }

    override func tearDown() {
        xiCore = nil
        client = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func newView(path: String?) -> ViewIdentifier {
        let created = expectation(description: "new_view")
        var identifier: ViewIdentifier?
        xiCore.newView(filePath: path) { response in
            if case .ok(let result) = response {
                identifier = result as? ViewIdentifier
            }
            created.fulfill()
        }
        wait(for: [created], timeout: 5)
        return identifier!
    }

    func proxy(for view: ViewIdentifier) -> XiViewProxy {
        func edit(_ method: String, _ params: Any) -> [String: Any] {
            return ["method": method, "params": params, "view_id": view]
        }
        return XiViewConnection(
            asyncRpc: { [xiCore] method, params, callback in
                xiCore!.sendRpcAsync("edit", params: edit(method, params), callback: callback)
            },
            syncRpc: { [xiCore] method, params in
                return xiCore!.sendRpc("edit", params: edit(method, params))
            })
    }

    func replaceContents(of view: ViewIdentifier, with text: String) {
        xiCore.sendRpcAsync("edit", params: ["method": "select_all", "params": [], "view_id": view], callback: nil)
        proxy(for: view).insert(chars: text)
    }

    func testReplacingNamedFileContentsReadsBackAndLeavesFileUntouched() throws {
        let file = directory.appendingPathComponent("named.txt")
        let original = "line one\nline two\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let view = newView(path: file.path)
        XCTAssertEqual(original, xiCore.contents(of: view))

        dirtyUpdate = expectation(description: "update with pristine == false")
        dirtyUpdate?.assertForOverFulfill = false
        replaceContents(of: view, with: "EDITED line one\n")

        XCTAssertEqual("EDITED line one\n", xiCore.contents(of: view))
        wait(for: [dirtyUpdate!], timeout: 5)
        XCTAssertEqual(original, try String(contentsOf: file, encoding: .utf8))
    }

    func testUntitledBufferRoundTripsNonASCII() {
        let view = newView(path: nil)
        let text = "héllo wörld\n日本語 🌍\ttab\n"
        proxy(for: view).insert(chars: text)

        XCTAssertEqual(text, xiCore.contents(of: view))
    }

    func testNonexistentPathYieldsEmptyBufferAndCreatesNoFile() {
        let file = directory.appendingPathComponent("not-yet.txt")
        let view = newView(path: file.path)

        XCTAssertEqual("", xiCore.contents(of: view))
        xiCore.closeView(identifier: view)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testEditingNonexistentPathDoesNotCreateFile() {
        let file = directory.appendingPathComponent("not-yet.txt")
        let view = newView(path: file.path)
        proxy(for: view).insert(chars: "text")

        XCTAssertEqual("text", xiCore.contents(of: view))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
