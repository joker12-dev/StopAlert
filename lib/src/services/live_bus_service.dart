import 'package:cloud_firestore/cloud_firestore.dart';

import 'iett_service.dart';

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
  Future<List<BusVehicle>> vehicles(String lineCode) async {
    final code = lineCode.trim().toUpperCase();
    if (code.isEmpty) return const [];

    // 1) Aynı istemci çok sık istiyorsa yerel kopyayı ver.
    final l = _local[code];
    if (l != null && DateTime.now().difference(l.at) < _localFor) {
      return l.vehicles;
    }

    // 2) Paylaşımlı önbellek (Firestore).
    try {
      final snap = await _col.doc(code).get();
      final data = snap.data();
      if (data != null) {
        final ts = (data['updatedAt'] as Timestamp?)?.toDate();
        if (ts != null && DateTime.now().difference(ts) < _freshFor) {
          final list = (data['vehicles'] as List? ?? const [])
              .map((e) => BusVehicle.fromMap(
                  Map<String, dynamic>.from(e as Map)))
              .toList();
          _local[code] = _Local(list, DateTime.now());
          return list;
        }
      }
    } catch (_) {
      // Firestore okunamadı: doğrudan servise düşülür.
    }

    // 3) Önbellek bayat: İETT'den çek ve paylaşımlı önbelleği tazele.
    final fresh = await IettService.instance.vehiclePositions(code);
    _local[code] = _Local(fresh, DateTime.now());
    if (fresh.isNotEmpty) {
      try {
        await _col.doc(code).set({
          'updatedAt': FieldValue.serverTimestamp(),
          'vehicles': [for (final v in fresh) v.toMap()],
        });
      } catch (_) {
        // Yazamadıysak sorun değil; sonuç yine kullanıcıya döner.
      }
    }
    return fresh;
  }
}

class _Local {
  const _Local(this.vehicles, this.at);
  final List<BusVehicle> vehicles;
  final DateTime at;
}
