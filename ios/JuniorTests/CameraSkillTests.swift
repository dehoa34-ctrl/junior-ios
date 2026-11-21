import CoreGraphics
import XCTest
@testable import Junior

/// Kamera becerilerinin saf parçaları: şınav açısı ve sayacı, fotoğraftan kalori yanıtı ve onay taslağı.
/// Kamera, Vision ve ağ yok.
final class CameraSkillTests: XCTestCase {
    // MARK: - Geometri

    func testAngleOfRightAndStraightArms() throws {
        let right = try XCTUnwrap(PushupGeometry.angle(a: CGPoint(x: 0, y: 1), vertex: .zero, c: CGPoint(x: 1, y: 0)))
        XCTAssertEqual(right, 90, accuracy: 0.001)
        let straight = try XCTUnwrap(PushupGeometry.angle(a: CGPoint(x: -1, y: 0), vertex: .zero, c: CGPoint(x: 2, y: 0)))
        XCTAssertEqual(straight, 180, accuracy: 0.001)
        XCTAssertNil(PushupGeometry.angle(a: .zero, vertex: .zero, c: CGPoint(x: 1, y: 0)), "sıfır uzunluklu kol")
    }

    func testElbowAngleIgnoresLowConfidenceJoints() {
        let shoulder = JointSample(point: CGPoint(x: 0, y: 1), confidence: 0.9)
        let elbow = JointSample(point: .zero, confidence: 0.9)
        let wrist = JointSample(point: CGPoint(x: 1, y: 0), confidence: 0.9)
        XCTAssertNotNil(PushupGeometry.elbowAngle(shoulder: shoulder, elbow: elbow, wrist: wrist))
        var blurry = wrist
        blurry.confidence = 0.1
        XCTAssertNil(PushupGeometry.elbowAngle(shoulder: shoulder, elbow: elbow, wrist: blurry))
    }

    func testCombinedUsesWhicheverArmIsVisible() {
        XCTAssertEqual(PushupGeometry.combined(100, 140), 120)
        XCTAssertEqual(PushupGeometry.combined(100, nil), 100)
        XCTAssertEqual(PushupGeometry.combined(nil, 140), 140)
        XCTAssertNil(PushupGeometry.combined(nil, nil))
    }

    // MARK: - Sayaç

    private func count(_ angles: [Double?], counter: PushupCounter = PushupCounter()) -> Int {
        var counter = counter
        for angle in angles { counter.feed(angle) }
        return counter.count
    }

    private func rep(down: Double = 80, up: Double = 170) -> [Double?] {
        [down, down, down, up, up, up]
    }

    func testOneFullRepIsCounted() {
        XCTAssertEqual(count([170, 170, 170] + rep()), 1)
    }

    func testThreeRepsAreCounted() {
        XCTAssertEqual(count([170, 170, 170] + rep() + rep() + rep()), 3)
    }

    func testStartingAtTheBottomDoesNotCountUntilArmsOpenAndCloseAgain() {
        // Aşağıda başlayıp ilk kez açılmak tekrar değil; ancak bir kez daha inip kalkınca sayılır.
        XCTAssertEqual(count([80, 80, 80, 170, 170, 170]), 0)
        XCTAssertEqual(count([80, 80, 80, 170, 170, 170] + rep()), 1)
    }

    func testJitterInsideTheDeadZoneNeverCounts() {
        var angles: [Double?] = [170, 170, 170]
        for index in 0..<30 { angles.append(index.isMultiple(of: 2) ? 118 : 138) }
        XCTAssertEqual(count(angles), 0)
    }

    func testShallowDipThatNeverReachesDownThresholdIsNotARep() {
        XCTAssertEqual(count([170, 170, 170, 115, 115, 115, 170, 170, 170]), 0)
    }

    func testHysteresisPreventsDoubleCountWhileHoveringNearUpThreshold() {
        // Yukarıda 150° çevresinde titreme: aşağı inmeden ikinci tekrar sayılmaz.
        let angles: [Double?] = [170, 170, 170, 80, 80, 80, 170, 170, 170] + [148, 152, 149, 153, 148, 154, 150, 151]
        XCTAssertEqual(count(angles), 1)
    }

    func testMissingFramesAreSkippedWithoutBreakingARep() {
        XCTAssertEqual(count([170, 170, 170, nil, 80, nil, 80, 80, nil, 170, 170, 170]), 1)
    }

    func testResetStartsOver() {
        var counter = PushupCounter()
        for angle in [170, 170, 170] + rep() { counter.feed(angle) }
        XCTAssertEqual(counter.count, 1)
        counter.reset()
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.phase, .unknown)
    }

    func testFeedReportsTheCompletedRep() {
        var counter = PushupCounter(smoothing: 1)
        XCTAssertFalse(counter.feed(170))
        XCTAssertFalse(counter.feed(80))
        XCTAssertTrue(counter.feed(170))
        XCTAssertEqual(counter.hint, "Aşağı in")
    }

    func testBadThresholdsFallBackToDefaults() {
        let counter = PushupCounter(downThreshold: 160, upThreshold: 90)
        XCTAssertEqual(counter.downThreshold, 100)
        XCTAssertEqual(counter.upThreshold, 150)
    }

    // MARK: - Fotoğraftan kalori

    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    func testPhotoEstimateParsesFoodsAndDropsBadItems() throws {
        let estimate = try XCTUnwrap(CaloriePhotoEstimate.parse(data([
            "outcome": "done",
            "reply": "Fotoğraftan tahminim: ...",
            "estimated": true,
            "foods": [
                ["food": "mercimek çorbası", "kcal": 180, "portion": "1 kase"],
                ["food": "", "kcal": 50],
                ["food": "bozuk", "kcal": 99999],
                ["food": "ekmek", "kcal": 80],
            ],
        ])))
        XCTAssertTrue(estimate.worked)
        XCTAssertEqual(estimate.foods.map(\.food), ["mercimek çorbası", "ekmek"])
        XCTAssertEqual(estimate.foods.map(\.kcal), [180, 80])
    }

    func testFailedEstimateHasNoFoodsAndKeepsTheServerSentence() throws {
        let estimate = try XCTUnwrap(CaloriePhotoEstimate.parse(data([
            "outcome": "failed", "text": "[failed] Fotoğraftan kalori tahmin edilemedi.", "foods": [],
        ])))
        XCTAssertFalse(estimate.worked)
        XCTAssertEqual(estimate.reply, "Fotoğraftan kalori tahmin edilemedi.")
        XCTAssertNil(CaloriePhotoEstimate.parse(Data("html".utf8)))
    }

    func testLogBodyAlwaysMarksTheEntryEstimated() {
        let body = PhotoFood(food: "ekmek", kcal: 80, portion: "1 dilim").logBody
        XCTAssertEqual(body["action"] as? String, "log")
        XCTAssertEqual(body["estimated"] as? Bool, true)
        XCTAssertEqual(body["kcal"] as? Int, 80)
        XCTAssertEqual(body["portion"] as? String, "1 dilim")
        XCTAssertNil(PhotoFood(food: "su", kcal: 1, portion: "").logBody["portion"])
    }

    func testDraftsAcceptCorrectionsAndRejectInvalidRows() {
        let estimate = CaloriePhotoEstimate(outcome: "done", reply: "", foods: [
            PhotoFood(food: "pilav", kcal: 300, portion: ""),
            PhotoFood(food: "salata", kcal: 60, portion: ""),
            PhotoFood(food: "ayran", kcal: 90, portion: ""),
        ])
        var drafts = PhotoFoodDraft.drafts(from: estimate)
        drafts[0].kcalText = " 250 "          // düzeltme
        drafts[1].include = false              // yemek değil
        drafts[2].kcalText = "çok"             // geçersiz
        let confirmed = PhotoFoodDraft.confirmed(drafts)
        XCTAssertEqual(confirmed.foods, [PhotoFood(food: "pilav", kcal: 250, portion: "")])
        XCTAssertEqual(confirmed.invalid, 1)
        drafts[2].kcalText = "0"
        XCTAssertNil(drafts[2].validated)
        drafts[2].kcalText = "5001"
        XCTAssertNil(drafts[2].validated)
        drafts[2].food = "   "
        drafts[2].kcalText = "90"
        XCTAssertNil(drafts[2].validated)
    }
}
