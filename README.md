# StopAlert

Toplu taşımada ineceğin durağı asla kaçırma. Marmaray, metro, tramvay ve otobüste
yolculuğunu takip eder; durağın yaklaşınca güçlü alarm ile uyandırır — yer altında bile.

- Teknik plan ve mimari: [PLAN.md](PLAN.md)
- Yol haritası / görevler: [YAPILACAKLAR.md](YAPILACAKLAR.md)

## Geliştirme

Flutter (Dart) ile geliştirilmektedir; hedef platformlar iOS ve Android.

```sh
flutter pub get
flutter run -d chrome --web-port=8080                       # yerel ön izleme
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080  # ağ/telefondan erişim
flutter run -d android   # emülatör/cihaz (gerçek GPS + alarm)
flutter test
```

Ağdan erişim: aynı Wi-Fi'daki telefondan `http://<bilgisayar-IP>:8080`.
Not: tarayıcı gerçek GPS'i yalnızca güvenli bağlamda (HTTPS veya localhost) verir;
telefon tarayıcısında http üzerinden konum izni engellenebilir. Gerçek GPS için
native (Android/iOS) derleme gerekir.

Durum: Faz 0 (temel kurulum) — hat/durak seçim akışı örnek veriyle çalışıyor,
GTFS boru hattı ve alarm motoru sırada.
