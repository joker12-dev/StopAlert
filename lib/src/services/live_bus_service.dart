import 'package:cloud_firestore/cloud_firestore.dart';

import '../data/transit_city.dart';
import 'ekomobil_service.dart';
import 'iett_service.dart';

/// e-Komobil canlı otobüs çağrısı YALNIZCA bu bayrak açıkken yapılır.
///
/// Varsayılan KAPALI ve bilerek öyle. e-komobil'in ucu, istemci kodundan
/// çıkarılmış gizli anahtarla üretilen `X-Security-Token` gerektiriyor; bu
/// bir erişim kontrolü ve onu taklit etmek onu aşmak oluyor. Kod yerinde
/// duruyor ki UlaşımPark/Kocaeli Büyükşehir'den veri yeniden-kullanım izni
/// alındığında (o zaman kendi erişim yöntemleri verilir) hızlıca
/// bağlanabilsin. İzin gelene kadar açılmamalı:
///
///     flutter build ... --dart-define=EKOMOBIL=true
const bool kEkomobilEnabled = bool.fromEnvironment('EKOMOBIL');

/// Canlı otobüs konumları için PAYLAŞIMLI önbellek (kota koruması).
///
/// İETT filo servisi **saatte 100 istek** ile sınırlı. Her cihaz doğrudan
/// çağırsaydı birkaç kullanıcıda kota dolar ve servis herkese kapanırdı.
/// Bu yüzden istekler Firestore üzerinden koordine edilir:
///
///   1. Önce `live_bus/{hatKodu}` okunur.
///   2. Kayıt [_freshFor] süresinden yeniyse İETT'ye HİÇ gidilmez.
///   3. Eskiyse yalnızca o an isteyen istemci İETT'yi çağırır ve sonucu
///      Firestore'a yazar; aynı hattı izleyen diğer herkes onu okur.
///
/// Sonuç: bir hattı kaç kişi izlerse izlesin, İETT'ye dakikada en fazla
/// ~2 istek gider. (Cloud Functions gerektirmez — Firebase Spark planında
/// çalışır; sunucu tarafı proxy'ye geçilirse bu sınıf tek noktadan değişir.)
class LiveBusService {
  LiveBusService._();
  static final LiveBusService instance = LiveBusService._();

  /// Önbellek bu süre boyunca taze sayılır (İETT'ye yeni istek yok).
  ///
  /// 45 sn SEÇİLDİ ÇÜNKÜ: servis saatte 100 istek kabul ediyor. 30 sn'de bir
  /// tazeleme 120 istek/saat yapar ve TEK kullanıcı bile ekranı bir saat açık
  /// tutarsa kotayı aşardı. 45 sn ⇒ en fazla 80 istek/saat (güvenli marj).
  static const refreshInterval = Duration(seconds: 45);
  static const _freshFor = refreshInterval;

  /// Firestore bile okunmadan aynı istemciye anında dönülen süre.
  static const _localFor = Duration(seconds: 15);

  final Map<String, _Local> _local = {};

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('live_bus');

  /// Hattın canlı araçları. Hata/ağ yoksa boş liste (ekran bunu boş durum
  /// olarak gösterir; alarm akışına asla dokunmaz).
  Future<List<BusVehicle>> vehicles(
    String lineCode, {
    TransitCity? city,
    String? lineId,
  }) async {
    final code = lineCode.trim().toUpperCase();
    if (code.isEmpty) return const [];
    final targetCity = city ?? TransitCities.istanbul;
    final direction = targetCity.id == TransitCities.kocaeli.id
        ? _directionForLineId(lineId)
        : null;
    final cacheKey = _cacheKey(targetCity, code, direction);

    // 1) Aynı istemci çok sık istiyorsa yerel kopyayı ver.
    final l = _local[cacheKey];
    if (l != null && DateTime.now().difference(l.at) < _localFor) {
      return l.vehicles;
    }

    // 2) Paylaşımlı önbellek (Firestore).
    try {
      final snap = await _col.doc(cacheKey).get();
      final data = snap.data();
      if (data != null) {
        final ts = (data['updatedAt'] as Timestamp?)?.toDate();
        if (ts != null && DateTime.now().difference(ts) < _freshFor) {
          final list = (data['vehicles'] as List? ?? const [])
              .map((e) =>
                  BusVehicle.fromMap(Map<String, dynamic>.from(e as Map)))
              .toList();
          _local[cacheKey] = _Local(list, DateTime.now());
          return list;
        }
      }
    } catch (_) {
      // Firestore okunamadı: doğrudan servise düşülür.
    }

    // 3) Önbellek bayat: kaynaktan çek ve paylaşımlı önbelleği tazele.
    final List<BusVehicle> fresh;
    if (targetCity.id == TransitCities.kocaeli.id) {
      // İZİN GELENE KADAR KAPALI (bkz. kEkomobilEnabled). Kapalıyken canlı
      // araç yok; ekran boş durumu gösterir, tarife tabanlı yaklaşan araçlar
      // yine çalışır.
      fresh = kEkomobilEnabled
          ? await EkomobilService.instance
              .vehiclePositions(code, direction: direction ?? 0)
          : const [];
    } else {
      fresh = await IettService.instance.vehiclePositions(code);
    }
    _local[cacheKey] = _Local(fresh, DateTime.now());
    if (fresh.isNotEmpty) {
      try {
        await _col.doc(cacheKey).set({
          'cityId': targetCity.id,
          'lineCode': code,
          if (direction != null) 'direction': direction,
          'updatedAt': FieldValue.serverTimestamp(),
          'vehicles': [for (final v in fresh) v.toMap()],
        });
      } catch (_) {
        // Yazamadıysak sorun değil; sonuç yine kullanıcıya döner.
      }
    }
    return fresh;
  }

  static int _directionForLineId(String? lineId) {
    final raw = (lineId ?? '').split(':').last.toUpperCase();
    final suffix = raw.contains('_') ? raw.split('_').last : raw;
    return suffix.startsWith('D') ? 1 : 0;
  }

  static String _cacheKey(TransitCity city, String code, int? direction) {
    final key = direction == null
        ? '${city.id}_$code'
        : '${city.id}_${code}_$direction';
    return key.replaceAll('/', '_');
  }
}

class _Local {
  const _Local(this.vehicles, this.at);
  final List<BusVehicle> vehicles;
  final DateTime at;
}
