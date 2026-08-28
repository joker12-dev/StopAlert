import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import '../data/models.dart';
import '../data/transit_db.dart';
import '../engine/arrival_estimator.dart';
import 'iett_service.dart' show BusVehicle;

/// ESHOT (İzmir) "durağa yaklaşan otobüsler" canlı servisi.
///
/// Uç: `openapi.izmir.bel.tr/api/iztek/duragayaklasanotobusler/{durakId}` —
/// durak KİMLİĞİNE göre yaklaşan otobüsleri döndürür. Alanlar: HatNumarasi,
/// HatAdi, HattinYonu, **KalanDurakSayisi** (bu durağa kaç durak kaldı),
/// KoorX=enlem/KoorY=boylam (ONDALIK VİRGÜLLÜ), OtobusId. Lisans CC BY 4.0.
///
/// KRİTİK: GTFS `stop_id` == canlı `durakId` (İzmir paketi böyle kuruldu), o
/// yüzden eşleştirme doğrudan. ETA, İETT gibi izdüşümle DEĞİL, paketteki gerçek
/// segment sürelerinden hesaplanır (KalanDurakSayisi kadar segment toplanır).
///
/// RATE LIMIT var → İETT'deki gibi Firestore'da PAYLAŞIMLI önbellek
/// (`live_izmir/{durakId}`): bir durağı kaç kişi izlerse izlesin ESHOT'a
/// dakikada ~1-2 istek gider.
class IzmirApproach {
  const IzmirApproach({
    required this.code,
    required this.name,
    required this.direction,
    required this.stopsAway,
    required this.busId,
    required this.lat,
    required this.lon,
  });

  final String code; // HatNumarasi
  final String name; // HatAdi
  final int direction; // HattinYonu (0/1)
  final int stopsAway; // KalanDurakSayisi
  final String busId; // OtobusId
  final double lat;
  final double lon;

  Map<String, dynamic> toMap() => {
        'code': code,
        'name': name,
        'direction': direction,
        'stopsAway': stopsAway,
        'busId': busId,
        'lat': lat,
        'lon': lon,
      };

  factory IzmirApproach.fromMap(Map<String, dynamic> m) => IzmirApproach(
        code: m['code'] as String? ?? '',
        name: m['name'] as String? ?? '',
        direction: (m['direction'] as num?)?.toInt() ?? 0,
        stopsAway: (m['stopsAway'] as num?)?.toInt() ?? 0,
        busId: m['busId'] as String? ?? '',
        lat: (m['lat'] as num?)?.toDouble() ?? 0,
        lon: (m['lon'] as num?)?.toDouble() ?? 0,
      );
}

/// Bir hattın bu durağa yaklaşan tek aracı için hazır varış (UI'nin beklediği
/// [TransitLine] + [ArrivalEstimate] çifti).
class IzmirArrival {
  const IzmirArrival({required this.line, required this.estimate});
  final TransitLine line;
  final ArrivalEstimate estimate;
}

abstract final class IzmirLiveService {
  static const _base =
      'https://openapi.izmir.bel.tr/api/iztek/duragayaklasanotobusler';

  static const _freshFor = Duration(seconds: 45);
  static const _localFor = Duration(seconds: 15);

  static final Map<int, _Local> _local = {};

  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('live_izmir');

  static double? _num(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
    return null;
  }

  /// Durağa yaklaşan otobüsler (ham). Ağ/hata yoksa boş liste.
  static Future<List<IzmirApproach>> forStop(int durakId) async {
    // 1) Yerel kopya.
    final l = _local[durakId];
    if (l != null && DateTime.now().difference(l.at) < _localFor) {
      return l.items;
    }
    // 2) Paylaşımlı önbellek (Firestore).
    final key = 'izmir_$durakId';
    try {
      final snap = await _col.doc(key).get();
      final data = snap.data();
      final ts = (data?['updatedAt'] as Timestamp?)?.toDate();
      if (data != null && ts != null &&
          DateTime.now().difference(ts) < _freshFor) {
        final list = (data['items'] as List? ?? const [])
            .map((e) => IzmirApproach.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList();
        _local[durakId] = _Local(list, DateTime.now());
        return list;
      }
    } catch (_) {
      // Firestore yoksa doğrudan servise düş.
    }
    // 3) Kaynaktan çek + önbelleği tazele.
    List<IzmirApproach> fresh = const [];
    try {
      final res = await http
          .get(Uri.parse('$_base/$durakId'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is List) {
          fresh = [
            for (final e in decoded)
              if (e is Map)
                IzmirApproach(
                  code: '${e['HatNumarasi'] ?? ''}',
                  name: (e['HatAdi'] as String? ?? '').trim(),
                  direction: (e['HattinYonu'] as num?)?.toInt() ?? 0,
                  stopsAway: (e['KalanDurakSayisi'] as num?)?.toInt() ?? 0,
                  busId: '${e['OtobusId'] ?? ''}',
                  lat: _num(e['KoorX']) ?? 0,
                  lon: _num(e['KoorY']) ?? 0,
                ),
          ];
        }
      }
    } catch (_) {
      return _local[durakId]?.items ?? const [];
    }
    _local[durakId] = _Local(fresh, DateTime.now());
    if (fresh.isNotEmpty) {
      try {
        await _col.doc(key).set({
          'durakId': durakId,
          'updatedAt': FieldValue.serverTimestamp(),
          'items': [for (final a in fresh) a.toMap()],
        });
      } catch (_) {}
    }
    return fresh;
  }

  /// Yaklaşan otobüsleri, paketten çözülen hat + gerçek segment süresiyle
  /// hazır varışlara çevirir. En erken (az durak) önce.
  static Future<List<IzmirArrival>> arrivalsForStop(Stop stop) async {
    final raw = stop.id.startsWith(kBusPrefix)
        ? stop.id.substring(kBusPrefix.length)
        : stop.id;
    final durakId = int.tryParse(raw);
    if (durakId == null) return const [];

    final approaches = await forStop(durakId);
    if (approaches.isEmpty) return const [];

    // Aynı hat+yön için en yakın aracı tut (kart kalabalıklaşmasın).
    final byLine = <String, IzmirApproach>{};
    for (final a in approaches) {
      if (a.code.isEmpty || a.stopsAway <= 0) continue;
      final k = '${a.code}_${a.direction}';
      final cur = byLine[k];
      if (cur == null || a.stopsAway < cur.stopsAway) byLine[k] = a;
    }

    final out = <IzmirArrival>[];
    final lineCache = <String, TransitLine?>{};

    Future<TransitLine?> resolve(String lineId) async {
      if (lineCache.containsKey(lineId)) return lineCache[lineId];
      final l = await TransitDb.instance.buildLine(lineId, cityId: 'izmir');
      lineCache[lineId] = l;
      return l;
    }

    for (final a in byLine.values) {
      // HattinYonu 0/1 → G/D varsayımı; tutmazsa öteki yön denenir.
      final primary = a.direction == 0 ? 'G' : 'D';
      final other = a.direction == 0 ? 'D' : 'G';
      TransitLine? line;
      var idx = -1;
      for (final yon in [primary, other]) {
        final l = await resolve('$kBusPrefix${a.code}_$yon');
        if (l == null) continue;
        final i = l.indexOfStop(stop.id);
        if (i >= a.stopsAway && i > 0) {
          line = l;
          idx = i;
          break;
        }
      }
      if (line == null || idx < a.stopsAway) continue;

      final segs = ArrivalEstimator.segmentSecondsFor(line);
      var eta = 0;
      for (var s = idx - a.stopsAway; s < idx && s < segs.length; s++) {
        eta += segs[s];
      }
      out.add(IzmirArrival(
        line: line,
        estimate: ArrivalEstimate(
          vehicle: BusVehicle(
            plate: a.busId,
            lat: a.lat,
            lon: a.lon,
            headingTo: line.name.split(' - ').last,
            routeCode: '${a.code}_${primary}_',
            lastSeen: '',
            nearestStopCode: '',
          ),
          stopsAway: a.stopsAway,
          seconds: eta,
          // Kaynak "kalan durak" verdiği için belirsizlik dar tutulur.
          spreadSeconds: 60,
          quality: ArrivalQuality.schedule,
        ),
      ));
    }
    out.sort((x, y) => x.estimate.seconds.compareTo(y.estimate.seconds));
    return out;
  }
}

class _Local {
  const _Local(this.items, this.at);
  final List<IzmirApproach> items;
  final DateTime at;
}
