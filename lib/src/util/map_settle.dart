import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Harita DURDU MU? Yoğun işaret katmanları buna bakarak çizilir.
///
/// NEDEN: `MarkerLayer.build`, kamera her değiştiğinde — yani bir yakınlaştırma
/// ya da kaydırma jesti boyunca HER KAREDE — çalışır ve görünen her işaret için
/// yeniden `Positioned` kurar. 200 duraklı bir hatta bu, jest başına on binlerce
/// widget demek; cihaz profilinde `_MarkerLayerState.build` toplam CPU'nun
/// %93'ünü yiyordu ve ana iş parçacığı dokunuşa yanıt veremeyip ANR'a giriyordu.
///
/// Çözüm: jest sürerken işaretleri hiç çizme, kamera durunca çiz. Kullanıcı
/// zaten hareket hâlindeki işaretleri okuyamıyor; parmağını kaldırdığında
/// hepsi yerli yerinde beliriyor.
///
/// Rota ÇİZGİSİ ve uç işaretleri gizlenmez — harita hareket ederken boş
/// görünmesin diye (bkz. kullanan ekranlar).
class MapSettle extends ValueNotifier<bool> {
  MapSettle({this.delay = const Duration(milliseconds: 160)}) : super(true);

  /// Son kamera hareketinden sonra "durdu" sayılana kadar geçen süre.
  /// Çok kısa olursa jestin ortasında işaretler yanıp sönüyor, çok uzun
  /// olursa parmağı kaldırdıktan sonra gecikmeli beliriyor.
  final Duration delay;

  Timer? _timer;
  bool _disposed = false;

  /// Kamera kıpırdadı. Jest bitene kadar işaretler beklesin.
  void touch() {
    // Atılmış bir ValueNotifier'a değer yazmak fırlatır. `onPositionChanged`
    // ekran kapanırken de tetiklenebiliyor (fling animasyonu sürerken geri
    // tuşu) — o yol çökmeye açıktı.
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(delay, _settle);
    if (!value) return;                       // zaten gizli

    // LAYOUT SIRASINDA BİLDİRME: flutter_map `onPositionChanged`'i kendi
    // layout aşamasında (persistentCallbacks) tetikliyor. Dinleyicileri orada
    // uyandırmak "build sırasında setState" hatası verir ve aynı karede
    // yeniden çizim başlatıp layout'u döngüye sokar — kareyi bitir, sonra
    // gizle.
    //
    // Kare DIŞINDAYSAK doğrudan bildirilir: `addPostFrameCallback` yalnızca
    // zaten planlanmış bir kare varsa çalışır, boşta çağrılırsa gizleme
    // süresiz askıda kalırdı.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.persistentCallbacks &&
        phase != SchedulerPhase.midFrameMicrotasks) {
      value = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && _timer != null) value = false;
    });
  }

  void _settle() {
    _timer = null;
    // Zamanlayıcı geri çağrısı build/layout dışında çalışır — burada bildirmek
    // güvenli.
    if (!_disposed) value = true;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
