import XCTest
@testable import RayNeoCompanion

@MainActor final class HermesTests: XCTestCase {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "HermesTests.\(UUID())")! }
    func testEndpointRejectsCredentialLeakAndDevicePlaintext() throws {
        for bad in ["http://192.168.1.5:8787", "https://user:pass@test.invalid", "https://test.invalid/?token=secret", "https://test.invalid/#key", "https://test.invalid/path"] {
            XCTAssertThrowsError(try HermesEndpoint.normalize(bad))
        }
        XCTAssertEqual(try HermesEndpoint.normalize("https://Bridge.invalid/"), "https://bridge.invalid")
        XCTAssertThrowsError(try HermesEndpoint.normalize("http://127.0.0.1:8787"))
        XCTAssertEqual(try HermesEndpoint.normalize("http://127.0.0.1:8787", allowLoopback: true), "http://127.0.0.1:8787")
    }
    func testNoKeysNoNetworkAndNoTools() async {
        var calls = 0
        let c = HermesCompanion(defaults: defaults(), key: { _ in nil }, send: { _, _, _, _ in calls += 1; return Data() })
        await c.refresh(); XCTAssertEqual(calls, 0); XCTAssertTrue(c.toolDefinitions.isEmpty)
    }
    func testEnabledToolsExposeOnlyAskStatusStop() {
        let d = defaults(); d.set("https://test.invalid", forKey: "companion.hermes.v1.endpoint"); d.set(true, forKey: "companion.hermes.v1.voiceTools")
        let c = HermesCompanion(defaults: d, key: { _ in "synthetic" })
        let names = c.toolDefinitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["hermes_ask", "hermes_status", "hermes_stop"])
    }
    func testToolFragmentsAndUTF8AreReassembled() throws {
        var a = VoiceToolCallAccumulator()
        try a.append([["index": 0, "type": "function", "function": ["name": "hermes_ask", "arguments": "{\"text\":\"检查"]]])
        try a.append([["index": 0, "function": ["arguments": "断连\"}"]]])
        let (name, args) = try a.validated(allowed: ["hermes_ask"], finishReason: "tool_calls")
        XCTAssertEqual(name, "hermes_ask"); XCTAssertEqual(args, "{\"text\":\"检查断连\"}")
    }
    func testCatalogueMatchesModelDefinitionsAndSchemas() throws {
        let d = defaults()
        d.set("https://test.invalid", forKey: "companion.hermes.v1.endpoint")
        d.set(true, forKey: "companion.hermes.v1.voiceTools")
        let c = HermesCompanion(defaults: d, key: { _ in "synthetic" })
        XCTAssertEqual(c.toolDefinitions.count, HermesToolDescriptor.all.count)
        for (descriptor, definition) in zip(HermesToolDescriptor.all, c.toolDefinitions) {
            let json = try XCTUnwrap(descriptor.schemaJSON.data(using: .utf8))
            let displayed = try JSONSerialization.jsonObject(with: json) as! NSDictionary
            XCTAssertEqual(displayed, definition as NSDictionary)
            let function = definition["function"] as! [String: Any]
            let parameters = function["parameters"] as! [String: Any]
            XCTAssertEqual(parameters["required"] as? [String], descriptor.requiresText ? ["text"] : [])
            XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
            XCTAssertFalse(descriptor.example.isEmpty)
        }
        XCTAssertEqual(Set(HermesToolDescriptor.all.map(\.id)).count, 3)
    }
    func testCatalogueVisibleWithoutEnablingOrExecutingTools() async {
        for enabled in [false, true] {
            let d = defaults()
            d.set("https://test.invalid", forKey: "companion.hermes.v1.endpoint")
            d.set(enabled, forKey: "companion.hermes.v1.voiceTools")
            var calls = 0
            let c = HermesCompanion(defaults: d, key: { _ in nil }, send: { _, _, _, _ in calls += 1; return Data() })
            XCTAssertEqual(HermesToolDescriptor.all.count, 3)
            XCTAssertTrue(c.toolDefinitions.isEmpty)
            XCTAssertNil(c.state)
            XCTAssertEqual(calls, 0)
        }
        let d = defaults(); d.set("https://test.invalid", forKey: "companion.hermes.v1.endpoint")
        let disabled = HermesCompanion(defaults: d, key: { _ in "synthetic" })
        XCTAssertTrue(disabled.configured); XCTAssertTrue(disabled.toolDefinitions.isEmpty)
    }
    func testMultipleToolsUnknownNamesExtraArgumentsAndTruncationRefused() throws {
        var a = VoiceToolCallAccumulator()
        XCTAssertThrowsError(try a.append([["index": 1]]))
        try a.append([["index": 0, "function": ["name": "hermes_decide", "arguments": "{}"]]])
        XCTAssertThrowsError(try a.validated(allowed: ["hermes_ask"], finishReason: "tool_calls"))
        a = VoiceToolCallAccumulator()
        try a.append([["index": 0, "function": ["name": "hermes_stop", "arguments": "{\"command\":\"bad\"}"]]])
        XCTAssertThrowsError(try a.validated(allowed: ["hermes_stop"], finishReason: "tool_calls"))
        XCTAssertThrowsError(try a.validated(allowed: ["hermes_stop"], finishReason: "length"))
    }
    func testUnknownDeliveryPersistsAndRetryUsesSameID() async throws {
        let d = defaults(); d.set("https://test.invalid", forKey: "companion.hermes.v1.endpoint")
        var ids: [String] = []
        let c = HermesCompanion(defaults: d, key: { _ in "synthetic" }, send: { _, _, _, body in
            let object = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            ids.append(object["requestId"] as! String); throw HermesBridgeError.offline
        })
        do { _ = try await c.ask(text: "synthetic") } catch {}
        XCTAssertTrue(c.hasUnknownDelivery)
        do { _ = try await c.ask(text: "do not duplicate") } catch {}
        XCTAssertEqual(ids.count, 1); await c.retryPending(); XCTAssertEqual(ids.count, 2); XCTAssertEqual(ids[0], ids[1])
        let restored = HermesCompanion(defaults: d, key: { _ in nil }); XCTAssertTrue(restored.hasUnknownDelivery)
    }
    func testUnknownToolDoesNotSend() async {
        let d = defaults(); d.set("https://test.invalid", forKey: "companion.hermes.v1.endpoint"); d.set(true, forKey: "companion.hermes.v1.voiceTools")
        var calls = 0
        let c = HermesCompanion(defaults: d, key: { _ in "synthetic" }, send: { _, _, _, _ in calls += 1; return Data() })
        let result = await c.executeTool(name: "hermes_decide", arguments: "{}", requestID: UUID())
        XCTAssertEqual(calls, 0); XCTAssertTrue(result.contains("未执行"))
    }
}
