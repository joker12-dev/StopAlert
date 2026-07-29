import 'dart:io';

/// Gerçek Android cihazda true; Windows/macOS test ortamında false.
/// (Widget testleri host üzerinde koştuğu için native servis yolları atlanır.)
bool get isAndroidDevice => Platform.isAndroid;

/// iOS cihaz mı.
bool get isIosDevice => Platform.isIOS;

/// Mobil cihaz mı (Android ya da iOS) — AdMob gibi mobil-özel yollar için.
bool get isMobileDevice => Platform.isAndroid || Platform.isIOS;
