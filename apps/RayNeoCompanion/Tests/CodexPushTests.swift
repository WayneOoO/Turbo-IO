import XCTest
@testable import RayNeoCompanion

@MainActor final class HermesPushTests: XCTestCase {
    @MainActor final class Fixture {
        var time = 10_000.0
        var packets = 0
        var network = 0
        var ready = true
        var succeeds = true
        var events: [[String: Any]] = []
        let defaults = UserDefaults(suiteName: "HermesPushTests.\(UUID())")!
        lazy var hermes = HermesCompanion(defaults: defaults, key: { _ in "synthetic" }, send: { [unowned self] _, _, _, _ in
            self.network += 1
            return try JSONSerialization.data(withJSONObject: ["protocol":"hermes/1","online":true,"workspace":"synthetic","active":NSNull(),
                "tasks":[["id":"task-a","sessionId":"20261002_064638_8f60b6","text":"synthetic","status":"done","tier":"中",
                    "steps":[["name":"terminal","status":"done","detail":"echo hi","durationMs":57]],
                    "answer":"sample","startedAt":10_000,"finishedAt":10_500,"error":"","tokens":["input":1,"output":2,"total":3]]],
                "sessions":[["sessionId":"20261002_064638_8f60b6","title":"synthetic","updatedAt":10_500]],
                "events":self.events])
        })
        func controller() -> HermesPush {
            HermesPush(hermes: hermes, defaults: defaults, now: { [unowned self] in self.time },
                canDeliver: { [unowned self] in self.ready }, deliver: { [unowned self] _,_ in self.packets += 1; return self.succeeds ? "123" : nil })
        }
        init() { defaults.set("https://synthetic.invalid", forKey:"companion.hermes.v1.endpoint") }
        func event(_ id: String = "event-a", kind: String = "done", at: Double = 10_001) -> [String: Any] {
            ["id":id,"taskId":"task-a","kind":kind,"title":"任务已完成","content":"7392","at":at]
        }
    }
    func testOffDoesNotPollOrSend() async {
        let f = Fixture(); let p = f.controller(); f.events = [f.event()]
        await p.tick(); XCTAssertEqual(f.network,0); XCTAssertEqual(f.packets,0)
    }
    func testOldEventsIgnoredAndNewEventSentOnceAcrossRestart() async {
        let f = Fixture(); let p = f.controller(); p.setEnabled(true); f.time += 10
        f.events = [f.event("old", at: 9999), f.event()]
        await p.tick(); await p.tick(); XCTAssertEqual(f.packets,1)
        let restored = f.controller(); await restored.tick(); XCTAssertEqual(f.packets,1)
    }
    func testBusyDefersWithoutLosingThenDispatches() async {
        let f = Fixture(); let p = f.controller(); p.setEnabled(true); f.time += 10
        f.events = [f.event()]; f.ready = false
        await p.tick(); XCTAssertEqual(p.pendingCount,1); XCTAssertEqual(f.packets,0)
        f.ready = true; await p.tick(); XCTAssertEqual(f.packets,1)
    }
    func testOldAndProcessEventsDoNotNotify() async {
        let f = Fixture(); let p = f.controller(); p.setEnabled(true); f.time += 10
        f.events = [f.event("old", at: 9999), f.event("step", kind: "step"), f.event("tier", kind: "tier")]
        await p.tick(); XCTAssertEqual(f.packets,0)
    }
    func testDoneEventOnlyNotifies() async {
        let f = Fixture(); let p = f.controller(); p.setEnabled(true); f.time += 10
        f.events = [f.event()]
        await p.tick(); XCTAssertEqual(f.packets,1); XCTAssertEqual(f.network,1)
    }
    func testUnknownSendNotRepeated() async {
        let f = Fixture(); let p = f.controller(); p.setEnabled(true); f.time += 10
        f.events=[f.event()]; f.succeeds=false
        await p.tick(); f.time += 10_000; await p.tick(); XCTAssertEqual(f.packets,1)
        XCTAssertTrue(p.status.contains("不自动重发"))
    }
    func testTwoTurnsSameAnswerStillTwoNotificationsSpacedOut() async {
        let f = Fixture(); let p = f.controller(); p.setEnabled(true); f.time += 10
        f.events=[f.event("one"),f.event("two")]
        await p.tick(); await p.tick(); XCTAssertEqual(f.packets,1)
        f.time += 8001; await p.tick(); XCTAssertEqual(f.packets,2)
    }
    func testChangedEndpointDoesNotReplayOldEvents() async {
        let f = Fixture(); let p = f.controller(); p.setEnabled(true); f.time += 10
        f.events=[f.event()]; try? f.hermes.save(endpoint:"https://second.invalid",token:"",voiceTools:false)
        await p.tick(); XCTAssertEqual(f.packets,0)
    }
}
