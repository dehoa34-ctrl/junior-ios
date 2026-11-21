import SwiftUI

/// "Fotoğrafla ekle": fotoğraf küçültülüp sunucuya gider, model yemekleri ve tahmini kaloriyi
/// listeler; kullanıcı düzeltip onaylayınca "tahmini" işaretiyle kaydedilir. Fotoğraf yalnız
/// bu ekranın ömrü boyunca bellekte durur; sunucu da saklamaz.
struct CaloriePhotoSheet: View {
    enum Phase: Equatable {
        case estimating
        case review
        case failed(String)
    }

    @ObservedObject var model: SkillsModel
    let jpeg: Data
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .estimating
    @State private var drafts: [PhotoFoodDraft] = []
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .estimating:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Junior fotoğrafa bakıyor; bu yarım dakikayı bulabilir.")
                        }
                    }
                case .failed(let text):
                    Section {
                        Text(text)
                        Button("Yeniden dene") { Task { await estimate() } }
                    }
                case .review:
                    reviewSections
                }
            }
            .navigationTitle("Fotoğraftan kalori")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }.disabled(saving)
                }
            }
        }
        .task { await estimate() }
    }

    @ViewBuilder
    private var reviewSections: some View {
        Section {
            ForEach($drafts) { $draft in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $draft.include) {
                        TextField("Yemek adı", text: $draft.food)
                    }
                    HStack {
                        TextField("Kalori", text: $draft.kcalText)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 90)
                        Text("kalori").foregroundStyle(.secondary)
                        if !draft.portion.isEmpty {
                            Text(draft.portion).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .opacity(draft.include ? 1 : 0.4)
                }
            }
        } header: {
            Text("Tahmin")
        } footer: {
            Text("Bunlar modelin tahminidir; yanlışsa adı ya da kaloriyi düzelt, yemek değilse işareti kaldır. Kayıtlar “tahmini” diye işaretlenir. Fotoğraf saklanmaz.")
        }
        Section {
            Button {
                Task { await save() }
            } label: {
                SkillButtonLabel(title: "Tahmini olarak kaydet", systemImage: "checkmark.circle.fill", busy: saving)
            }
            .disabled(saving || PhotoFoodDraft.confirmed(drafts).foods.isEmpty)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(JuniorTheme.red)
            }
        }
    }

    private func estimate() async {
        phase = .estimating
        guard let result = await model.estimateCalories(photo: jpeg) else {
            phase = .failed(model.notes[.calories] ?? "Tahmin alınamadı; yeniden dene.")
            return
        }
        if result.worked {
            drafts = PhotoFoodDraft.drafts(from: result)
            phase = .review
        } else {
            phase = .failed(result.reply.isEmpty ? "Fotoğraftan kalori tahmin edilemedi." : result.reply)
        }
    }

    private func save() async {
        let confirmed = PhotoFoodDraft.confirmed(drafts)
        if confirmed.invalid > 0 {
            problem = "İşaretli satırlarda adı boş ya da kalorisi 1–5000 dışında olan var; düzelt ya da işaretini kaldır."
            return
        }
        problem = nil
        saving = true
        let saved = await model.logPhotoFoods(confirmed.foods)
        saving = false
        if saved == confirmed.foods.count {
            dismiss()
        } else {
            // Yarım kaldıysa kaydedilenler listeden çıkar; yeniden denemek kaydı ikilemez.
            let done = Set(drafts.filter { $0.include && $0.validated != nil }.prefix(saved).map(\.id))
            drafts.removeAll { done.contains($0.id) }
            problem = model.notes[.calories] ?? "Kaydedilemedi; yeniden dene."
        }
    }
}
