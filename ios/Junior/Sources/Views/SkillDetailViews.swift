import SwiftUI

// Beceriler ekranının paket sayfaları. Hepsi aynı SkillsModel'i paylaşır; veriler bilgisayardaki
// Junior sunucusunda durur ve masaüstüyle ortaktır.

struct WeatherSkillView: View {
    @ObservedObject var model: SkillsModel

    var body: some View {
        Form {
            Section {
                TextField("Şehir (boşsa varsayılan şehir)", text: $model.city)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { Task { await model.loadWeather() } }
                Button {
                    Task { await model.loadWeather() }
                } label: {
                    SkillButtonLabel(title: "Hava durumuna bak", systemImage: "cloud.sun.fill", busy: model.working == .weather)
                }
                .disabled(model.working == .weather)
            } footer: {
                Text("Varsayılan şehri bilgisayarda Ayarlar > Eklentiler > Hava durumu'ndan ayarlarsın. Kaynak: Open-Meteo.")
            }

            if let report = model.weather {
                Section {
                    if let temperature = report.temperature {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(temperature)°C").font(.system(size: 40, weight: .bold, design: .rounded))
                            Text(Self.currentDetail(report))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(report.days) { day in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(day.label).font(.body.weight(.medium))
                                Spacer()
                                Text(day.rangeText).monospacedDigit()
                            }
                            Text(Self.dayDetail(day)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(report.place.isEmpty ? "Hava" : report.place)
                }
            }

            SkillNote(text: model.notes[.weather])
        }
        .task {
            await model.loadCity()
            if model.weather == nil, !model.city.isEmpty { await model.loadWeather() }
        }
    }

    static func currentDetail(_ report: WeatherReport) -> String {
        var parts: [String] = []
        if let current = report.current, !current.isEmpty { parts.append(current) }
        if let feels = report.feelsLike { parts.append("hissedilen \(feels)°C") }
        return parts.joined(separator: " · ")
    }

    static func dayDetail(_ day: WeatherDay) -> String {
        var parts = [day.description]
        if let rain = day.precipitation, rain >= 20 { parts.append("yağış olasılığı %\(rain)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct SearchSkillView: View {
    @ObservedObject var model: SkillsModel
    @State private var query = ""
    @State private var mode: SearchMode = .quick

    var body: some View {
        Form {
            Section {
                TextField("Ne arayayım?", text: $query)
                    .submitLabel(.search)
                    .onSubmit { Task { await model.search(query, mode: mode) } }
                Picker("Kip", selection: $mode) {
                    ForEach(SearchMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Button {
                    Task { await model.search(query, mode: mode) }
                } label: {
                    SkillButtonLabel(title: "Ara", systemImage: "magnifyingglass", busy: model.working == .search)
                }
                .disabled(model.working == .search || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("Hızlı: ilk sonuçlar. Derin: ilk sayfalar da okunur (biraz sürer). Haber: son bir haftanın haberleri. "
                     + "Bağlantıya dokununca Safari'de açılır.")
            }

            if !model.hits.isEmpty {
                Section {
                    ForEach(model.hits) { hit in
                        Link(destination: hit.url) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hit.title).font(.body.weight(.medium)).foregroundStyle(JuniorTheme.cyan)
                                Text(hit.host).font(.caption).foregroundStyle(.secondary)
                                if !hit.snippet.isEmpty {
                                    Text(hit.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                                }
                                if let excerpt = hit.excerpt, !excerpt.isEmpty {
                                    Text("Sayfadan: \(excerpt)").font(.footnote).foregroundStyle(.secondary).lineLimit(6)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Sonuçlar")
                }
            }

            SkillNote(text: model.searchNote)
        }
    }
}

struct PomodoroSkillView: View {
    @ObservedObject var model: SkillsModel

    var body: some View {
        Form {
            PackGate(pack: .pomodoro, model: model) {
                if let overview = model.overview {
                    let pomodoro = overview.pomodoro
                    Section {
                        if pomodoro.running, let ends = pomodoro.ends {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(pomodoro.phase == "work" ? "Çalışma" : "Mola").font(.headline)
                                    Text(SkillFormat.countdown(SkillFormat.secondsLeft(until: ends, now: context.date)))
                                        .font(.system(size: 52, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                    ProgressView(value: SkillFormat.phaseProgress(
                                        phase: pomodoro.phase, ends: ends,
                                        workMin: pomodoro.workMin ?? overview.workMin,
                                        breakMin: pomodoro.breakMin ?? overview.breakMin, now: context.date))
                                    .tint(pomodoro.phase == "work" ? JuniorTheme.red : JuniorTheme.green)
                                }
                                .padding(.vertical, 4)
                            }
                            Button(role: .destructive) {
                                Task { await model.pomodoroStop() }
                            } label: {
                                SkillButtonLabel(title: "Durdur", systemImage: "stop.fill", busy: model.working == .pomodoro)
                            }
                            .disabled(model.working == .pomodoro)
                        } else {
                            Button {
                                Task { await model.pomodoroStart() }
                            } label: {
                                SkillButtonLabel(title: "Başlat: \(overview.workMin) dk çalışma, \(overview.breakMin) dk mola",
                                                 systemImage: "play.fill", busy: model.working == .pomodoro)
                            }
                            .disabled(model.working == .pomodoro)
                        }
                        Text("Bugün \(pomodoro.doneToday) pomodoro tamamlandı.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } footer: {
                        Text("Süre bitince telefona bildirim gelir (bildirim izni gerekir); bilgisayardaki Junior da duyurur. "
                             + "Süreleri bilgisayarda Ayarlar > Eklentiler > Pomodoro'dan değiştirirsin.")
                    }
                }
            }
            SkillNote(text: model.notes[.pomodoro])
        }
        .task(id: model.overview?.pomodoro.ends) { await model.waitForPomodoroPhase() }
    }
}

struct WaterSkillView: View {
    @ObservedObject var model: SkillsModel

    var body: some View {
        Form {
            PackGate(pack: .water, model: model) {
                if let overview = model.overview {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(overview.waterML) / \(overview.waterGoal) ml")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            ProgressView(value: SkillFormat.progress(overview.waterML, goal: overview.waterGoal))
                                .tint(JuniorTheme.cyan)
                            Text(verbatim: "Hedefin %\(SkillFormat.percent(overview.waterML, goal: overview.waterGoal))'i")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        Button {
                            Task { await model.logWater() }
                        } label: {
                            SkillButtonLabel(title: "Su içtim (\(overview.glassML) ml)", systemImage: "drop.fill",
                                             busy: model.working == .water)
                        }
                        .disabled(model.working == .water)
                        Button {
                            Task { await model.logWater(ml: 500) }
                        } label: {
                            Label("Büyük şişe (500 ml)", systemImage: "waterbottle.fill")
                        }
                        .disabled(model.working == .water)
                    } footer: {
                        Text("Gün 04:00'te döner. Hatırlatma aralığını ve hedefi bilgisayarda Ayarlar > Eklentiler > Su hatırlatıcısı'ndan ayarlarsın.")
                    }
                }
            }
            SkillNote(text: model.notes[.water])
        }
    }
}

struct CaloriesSkillView: View {
    @ObservedObject var model: SkillsModel
    @State private var food = ""
    @State private var kcalText = ""

    var body: some View {
        Form {
            PackGate(pack: .calories, model: model) {
                if let overview = model.overview {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(overview.kcal) / \(overview.kcalGoal) kalori")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            ProgressView(value: SkillFormat.progress(overview.kcal, goal: overview.kcalGoal))
                                .tint(overview.kcal > overview.kcalGoal ? JuniorTheme.red : JuniorTheme.orange)
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        TextField("Ne yedin? (ör. mercimek çorbası)", text: $food)
                        TextField("Kalori (bilmiyorsan boş bırak)", text: $kcalText)
                            .keyboardType(.numberPad)
                        Button {
                            let name = food
                            let kcal = Int(kcalText.trimmingCharacters(in: .whitespaces))
                            food = ""
                            kcalText = ""
                            Task { await model.logCalories(food: name, kcal: kcal) }
                        } label: {
                            SkillButtonLabel(title: "Kaydet", systemImage: "plus.circle.fill", busy: model.working == .calories)
                        }
                        .disabled(model.working == .calories || food.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("Kayıt ekle")
                    } footer: {
                        Text("Kaloriyi boş bırakırsan Junior tipik bir porsiyona göre tahmin eder; kayıt “tahmini” diye işaretlenir.")
                    }

                    Section {
                        if model.calorieEntries.isEmpty {
                            Text("Bugün kayıt yok.").foregroundStyle(.secondary)
                        }
                        ForEach(model.calorieEntries) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.food)
                                    if !entry.portion.isEmpty {
                                        Text(entry.portion).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if entry.estimated {
                                    Text("tahmini")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(JuniorTheme.orange.opacity(0.2), in: Capsule())
                                        .foregroundStyle(JuniorTheme.orange)
                                }
                                Text("\(entry.kcal)").monospacedDigit()
                            }
                        }
                    } header: {
                        Text("Bugün")
                    }
                }
            }
            SkillNote(text: model.notes[.calories])
        }
        .task(id: model.overview?.enabled(.calories)) { await model.loadCalories() }
    }
}

struct PushupsSkillView: View {
    @ObservedObject var model: SkillsModel
    @State private var count = 10

    var body: some View {
        Form {
            PackGate(pack: .pushups, model: model) {
                if let overview = model.overview {
                    Section {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(overview.pushupsToday)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                                Text("bugün").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(overview.pushupsWeek)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                                Text("bu hafta").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if overview.pushupsGoal > 0 {
                            ProgressView(value: SkillFormat.progress(overview.pushupsToday, goal: overview.pushupsGoal))
                                .tint(JuniorTheme.green)
                            Text("Günlük hedef \(overview.pushupsGoal)").font(.footnote).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Hafta pazartesi başlar.")
                    }

                    Section {
                        Stepper("\(count) şınav", value: $count, in: 1...500)
                        Button {
                            Task { await model.logPushups(count) }
                        } label: {
                            SkillButtonLabel(title: "Ekle", systemImage: "plus.circle.fill", busy: model.working == .pushups)
                        }
                        .disabled(model.working == .pushups)
                    } header: {
                        Text("Kayıt ekle")
                    }
                }
            }
            SkillNote(text: model.notes[.pushups])
        }
    }
}

struct ReviewSkillView: View {
    @ObservedObject var model: SkillsModel
    @State private var front = ""
    @State private var back = ""

    var body: some View {
        Form {
            PackGate(pack: .review, model: model) {
                Section {
                    if let card = model.card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(card.front).font(.title3.weight(.semibold))
                            if let answer = card.back {
                                Divider()
                                Text(answer).font(.body)
                            }
                        }
                        .padding(.vertical, 6)
                        if card.back == nil {
                            Button {
                                Task { await model.reviewFlip() }
                            } label: {
                                SkillButtonLabel(title: "Çevir", systemImage: "arrow.triangle.2.circlepath", busy: model.working == .review)
                            }
                            .disabled(model.working == .review)
                        } else {
                            Button {
                                Task { await model.reviewGrade(knew: true) }
                            } label: {
                                Label("Bildim", systemImage: "checkmark.circle.fill")
                            }
                            .tint(JuniorTheme.green)
                            .disabled(model.working == .review)
                            Button {
                                Task { await model.reviewGrade(knew: false) }
                            } label: {
                                Label("Bilemedim", systemImage: "xmark.circle.fill")
                            }
                            .tint(JuniorTheme.orange)
                            .disabled(model.working == .review)
                        }
                    } else {
                        let due = model.reviewDue ?? model.overview?.reviewDue ?? 0
                        Text(due > 0 ? "Bugün \(due) kart tekrar edilecek." : "Bugün tekrar edilecek kart yok.")
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await model.reviewStart() }
                        } label: {
                            SkillButtonLabel(title: "Tekrara başla", systemImage: "play.fill", busy: model.working == .review)
                        }
                        .disabled(model.working == .review || due == 0)
                    }
                } header: {
                    Text("Bugünkü kartlar")
                } footer: {
                    Text("Önce cevabı düşün, sonra kartı çevir. Bildiklerin giderek seyrek, bilemediklerin yarın yeniden gelir.")
                }

                Section {
                    TextField("Ön yüz (ör. kedi)", text: $front, axis: .vertical)
                    TextField("Arka yüz (ör. cat)", text: $back, axis: .vertical)
                    Button {
                        let f = front, b = back
                        front = ""
                        back = ""
                        Task { await model.addCard(front: f, back: b) }
                    } label: {
                        Label("Kart ekle", systemImage: "plus.circle.fill")
                    }
                    .disabled(model.working == .review
                              || front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Yeni kart")
                } footer: {
                    Text("Sesle de: “Kart ekle: kedi, arkası cat.” Toplam \(model.overview?.reviewCards ?? 0) kart.")
                }
            }
            SkillNote(text: model.card == nil ? model.notes[.review] : nil)
        }
    }
}

struct QuizSkillView: View {
    @ObservedObject var model: SkillsModel
    @State private var topic = ""

    var body: some View {
        Form {
            PackGate(pack: .quiz, model: model) {
                if let question = model.question {
                    Section {
                        Text(question.question).font(.body.weight(.medium))
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            Button {
                                Task { await model.quizAnswer(index) }
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(QuizQuestion.letters[index]).font(.body.weight(.bold)).foregroundStyle(JuniorTheme.cyan)
                                    Text(option).foregroundStyle(.primary)
                                }
                            }
                            .disabled(model.working == .quiz)
                        }
                    } header: {
                        Text("Soru \(question.number) / \(question.total)")
                    } footer: {
                        if let verdict = model.quizVerdict {
                            Text("Önceki soru: \(verdict)")
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            Task { await model.quizStop() }
                        } label: {
                            Label("Sınavı bırak", systemImage: "xmark")
                        }
                        .disabled(model.working == .quiz)
                    }
                } else {
                    if let score = model.quizScore {
                        Section {
                            Text("\(score.correct) / \(score.total) doğru")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            if let verdict = model.quizVerdict {
                                Text("Son soru: \(verdict)").font(.footnote).foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Sınav bitti")
                        }
                    }
                    Section {
                        TextField("Konu (ör. Osmanlı tarihi)", text: $topic)
                        Button {
                            let text = topic
                            Task { await model.quizStart(topic: text) }
                        } label: {
                            SkillButtonLabel(title: model.working == .quiz ? "Sorular hazırlanıyor…" : "Sınav hazırla",
                                             systemImage: "sparkles", busy: model.working == .quiz)
                        }
                        .disabled(model.working == .quiz)
                    } header: {
                        Text("Yeni sınav")
                    } footer: {
                        Text("Konu boşsa sorular hafızandaki notlardan hazırlanır. Soruları bilgisayardaki model yazar; "
                             + "yarım dakikayı bulabilir. Sesle de: “Osmanlı tarihi hakkında sınav yap.”")
                    }
                    if model.quizScore == nil, let last = model.overview?.lastScore {
                        Section {
                            Text("\(last.topic): \(last.correct) / \(last.total) doğru")
                        } header: {
                            Text("Son sınav")
                        }
                    }
                }
            }
            SkillNote(text: model.question == nil && model.quizScore == nil ? model.notes[.quiz] : nil)
        }
        .task(id: model.overview?.quizActive) { await model.quizResume() }
    }
}
