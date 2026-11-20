import XCTest
@testable import Junior

/// Görevler ekranının saf parçaları: sunucu yanıtını okuma, durum metni, rapor dosya adı. Ağ yok.
final class BackgroundTaskTests: XCTestCase {
    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func raw(_ over: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "id": "a1b2c3d4e5f6", "kind": "research", "goal": "Kış lastiği ne zaman gerekir?", "status": "running",
            "created": 1_800_000_000.0, "start_at": 1_800_000_000.0, "minutes": 10, "steps": 4, "max_steps": 40,
            "stage": "investigate", "result": "", "error": "", "finished": NSNull(), "resume_at": NSNull(),
            "progress": ["Görev kuyruğa alındı.", "Sayfa okundu: Lastik rehberi"], "findings": 2, "sources": 3,
            "questions": ["S1"], "report": false,
        ]
        for (key, value) in over { base[key] = value }
        return base
    }

    func testParsesListAndSingleTask() {
        let list = BackgroundTask.parseList(data(["tasks": [raw(), raw(["id": "x2", "status": "done", "report": true]),
                                                            raw(["id": "", "status": "running"]), raw(["id": "x3", "status": "dancing"])]]))
        XCTAssertEqual(list?.map(\.id), ["a1b2c3d4e5f6", "x2"])
        let first = list?.first
        XCTAssertEqual(first?.status, .running)
        XCTAssertEqual(first?.steps, 4)
        XCTAssertEqual(first?.maxSteps, 40)
        XCTAssertEqual(first?.sources, 3)
        XCTAssertEqual(first?.progress.last, "Sayfa okundu: Lastik rehberi")
        XCTAssertEqual(list?.last?.hasReport, true)
        XCTAssertEqual(BackgroundTask.parseOne(data(["task": raw()]))?.goal, "Kış lastiği ne zaman gerekir?")
        XCTAssertNil(BackgroundTask.parseList(Data("bozuk".utf8)))
        XCTAssertNil(BackgroundTask.parseOne(data(["tasks": []])))
    }

    func testStatusAndDetailTexts() {
        let running = BackgroundTask.parse(raw())!
        XCTAssertTrue(running.isActive)
        XCTAssertEqual(running.statusText, "Çalışıyor")
        XCTAssertEqual(running.detailText, "4/40 adım · 3 kaynak · 2 doğrulanmış bulgu")
        let paused = BackgroundTask.parse(raw(["status": "paused"]))!
        XCTAssertTrue(paused.detailText.contains("kendiliğinden sürecek"))
        let done = BackgroundTask.parse(raw(["status": "done", "result": "Kış lastiği 7 derecenin altında gerekir."]))!
        XCTAssertFalse(done.isActive)
        XCTAssertEqual(done.detailText, "Kış lastiği 7 derecenin altında gerekir.")
        let failed = BackgroundTask.parse(raw(["status": "failed", "error": "Model 6 kez yanıt vermedi."]))!
        XCTAssertEqual(failed.statusText, "Başarısız")
        XCTAssertEqual(failed.detailText, "Model 6 kez yanıt vermedi.")
        let later = BackgroundTask.parse(raw(["status": "queued", "start_at": Date().addingTimeInterval(7200).timeIntervalSince1970]))!
        XCTAssertEqual(later.statusText, "Sırada")
        XCTAssertTrue(later.detailText.hasPrefix("Başlama: "))
    }

    func testReportFileNameIsSafe() {
        let task = BackgroundTask.parse(raw(["goal": "Kış lastiği / zorunlu mu? ../../etc"]))!
        let name = TasksModel.fileName(for: task)
        XCTAssertTrue(name.hasSuffix("-a1b2c3d4e5f6.md"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
        let empty = BackgroundTask.parse(raw(["goal": "???"]))!
        XCTAssertEqual(TasksModel.fileName(for: empty), "rapor-a1b2c3d4e5f6.md")
    }
}
