import AppIntents
import Foundation

// Dynamic Island / kilit ekranındaki Onayla ve Reddet düğmeleri (iOS 17 etkileşimli Live Activity).
//
// Bu dosya hem uygulamaya hem widget eklentisine girer (düğme eklentide çizilir). Live Activity
// niyetini sistem UYGULAMANIN sürecinde çalıştırır; kararı gönderen kod yalnız uygulamada
// derlenir (`JUNIOR_APP`, project.yml). Eklentideki kopya hiçbir şey yapmaz.

/// Onay: kilitliyken verilmesin diye uygulamayı açar (kilitliyse iOS önce Face ID / kod ister).
struct JuniorApproveConfirmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Bilgisayardaki işlemi onayla"
    static var description = IntentDescription("Junior'ın bilgisayarda yapmak için onay istediği işlemi onaylar.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Onay kimliği")
    var confirmID: String

    init() {}

    init(confirmID: String) {
        self.confirmID = confirmID
    }

    func perform() async throws -> some IntentResult {
        #if JUNIOR_APP
        await RemoteConfirmCenter.decideFromSystem(id: confirmID, approve: true)
        #endif
        return .result()
    }
}

/// Ret: güvenli yön; uygulamayı açmadan, kilitliyken de verilebilir.
struct JuniorDenyConfirmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Bilgisayardaki işlemi reddet"
    static var description = IntentDescription("Junior'ın bilgisayarda yapmak için onay istediği işlemi reddeder.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Onay kimliği")
    var confirmID: String

    init() {}

    init(confirmID: String) {
        self.confirmID = confirmID
    }

    func perform() async throws -> some IntentResult {
        #if JUNIOR_APP
        await RemoteConfirmCenter.decideFromSystem(id: confirmID, approve: false)
        #endif
        return .result()
    }
}
