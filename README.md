# Junior — iOS uygulaması

Türkçe konuşan kişisel asistanın iPhone uygulaması. Ray-Ban Meta gözlüğüyle
çalışır: "Hey Junior, bu gördüğüm ne" dendiğinde kareyi gözlükten alır ve
yanıtı kulağa okur.

Bu depo yalnız **uygulama kaynağını ve derleme iş akışını** içerir. Yanıtları
üreten sunucu ayrıdır ve burada değildir; uygulama kullanıcının kendi
sunucusuna adres ve token ile bağlanır.

## Derleme

GitHub Actions macOS koşucusunda XcodeGen + xcodebuild ile derlenir. Çıktı
**imzasız** bir `.ipa`'dır; imzalama telefonda SideStore ile yapılır.
