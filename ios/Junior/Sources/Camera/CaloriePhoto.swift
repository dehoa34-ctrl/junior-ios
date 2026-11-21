import Foundation

/// Fotoğraftan kalori tahmini: sunucu yanıtının çözümü ve kullanıcının onay/düzeltme taslağı.
/// Saf mantık (ağ ve görünüm yok); POST /v1/skills/daily/calories/photo yanıtı
/// mobile_api/calorie_photo.py'de üretilir. Fotoğraf sunucuda saklanmaz, telefonda da kalıcı değildir.
struct CaloriePhotoEstimate: Equatable {
    let outcome: String
    let reply: String
    let foods: [PhotoFood]

    var worked: Bool { outcome == "done" && !foods.isEmpty }

    static func parse(_ data: Data) -> CaloriePhotoEstimate? {
        guard let raw = SkillJSON.object(data), let outcome = raw["outcome"] as? String else { return nil }
        var reply = (raw["reply"] as? String) ?? ""
        if reply.isEmpty, let text = raw["text"] as? String { reply = SkillReply.stripTag(text) }
        var foods: [PhotoFood] = []
        for item in (raw["foods"] as? [[String: Any]]) ?? [] {
            let name = ((item["food"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let kcal = SkillJSON.int(item["kcal"]), PhotoFood.kcalRange.contains(kcal) else { continue }
            foods.append(PhotoFood(food: name, kcal: kcal, portion: (item["portion"] as? String) ?? ""))
        }
        return CaloriePhotoEstimate(outcome: outcome, reply: reply, foods: foods)
    }
}

struct PhotoFood: Equatable {
    static let kcalRange = 1...5000

    var food: String
    var kcal: Int
    var portion: String

    /// Mevcut kalori ucuna giden kayıt gövdesi: fotoğraftan geldiği için hep "tahmini".
    var logBody: [String: Any] {
        var body: [String: Any] = ["action": "log", "food": food, "kcal": kcal, "estimated": true]
        if !portion.isEmpty { body["portion"] = portion }
        return body
    }
}

/// Onay ekranındaki bir satır: kullanıcı adı ve kaloriyi düzeltebilir ya da satırı çıkarabilir.
struct PhotoFoodDraft: Identifiable, Equatable {
    let id: Int
    var include = true
    var food: String
    var kcalText: String
    var portion: String

    init(id: Int, from item: PhotoFood) {
        self.id = id
        food = item.food
        kcalText = String(item.kcal)
        portion = item.portion
    }

    /// Geçerli satır: ad boş değil, kalori 1–5000. Geçersizse nil (kaydedilmez).
    var validated: PhotoFood? {
        let name = food.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = kcalText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let kcal = Int(digits), PhotoFood.kcalRange.contains(kcal) else { return nil }
        return PhotoFood(food: name, kcal: kcal, portion: portion.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func drafts(from estimate: CaloriePhotoEstimate) -> [PhotoFoodDraft] {
        estimate.foods.enumerated().map { PhotoFoodDraft(id: $0.offset, from: $0.element) }
    }

    /// Onaylanacak liste: işaretli ve geçerli satırlar. Biri işaretli ama geçersizse `invalid` sayılır.
    static func confirmed(_ drafts: [PhotoFoodDraft]) -> (foods: [PhotoFood], invalid: Int) {
        var foods: [PhotoFood] = []
        var invalid = 0
        for draft in drafts where draft.include {
            if let food = draft.validated { foods.append(food) } else { invalid += 1 }
        }
        return (foods, invalid)
    }
}

/// Seçilen/çekilen yemek fotoğrafı (küçültülmüş JPEG); onay ekranını `.sheet(item:)` ile açar.
struct PickedMealPhoto: Identifiable {
    let id = UUID()
    let jpeg: Data
}
