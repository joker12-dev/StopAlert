import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Otobüs durak/hat kimliklerinin gömülü ray/vapur (lines.json) kimlikleriyle
/// çakışmaması için ön ek. Dışarıya verilen id'ler `bus:<ham>` biçimindedir.
const String kBusPrefix = 'bus:';

bool isBusId(String id) => id.startsWith(kBusPrefix);

/// Aksan/Türkçe-duyarsız arama anahtarı — DB'deki `name_norm` ile birebir aynı
/// olmalı (bkz. tools/gtfs/build_db.py `norm`). İ/ı→i, Ö→o, Ş→s… + küçük harf.
String transitNorm(String s) {
  const map = {
    'İ': 'i', 'I': 'i', 'ı': 'i', 'Ö': 'o', 'ö': 'o', 'Ü': 'u', 'ü': 'u',
    'Ş': 's', 'ş': 's', 'Ç': 'c', 'ç': 'c', 'Ğ': 'g', 'ğ': 'g',
  };
  final b = StringBuffer();
  for (final ch in s.split('')) {
    b.write(map[ch] ?? ch);
  }
  return b.toString().toLowerCase();
}

/// İndirilen İETT SQLite veritabanına salt-okunur erişim (yakın durak, arama,
/// rota). DB yoksa/açık değilse tüm sorgular boş döner (ray/vapur ile devam).
///
/// Şema (bkz. tools/gtfs/build_db.py):
///   stops(id INTEGER, name, lat, lon)
///   lines(id TEXT, code, name, type='bus')
///   line_stops(line_id, seq, stop_id, seconds)
///   meta(key, value)
class TransitDb {
  TransitDb._();
  static final TransitDb instance = TransitDb._();

  Database? _db;
  bool get isReady => _db != null;

  Future<void> open(String path) async {
    if (_db != null) return;
    _db = await openDatabase(path, readOnly: true);
  }

  Future<void> close() async {
    final d = _db;
    _db = null;
    await d?.close();
  }

  Future<String?> meta(String key) async {
    final db = _db;
    if (db == null) return null;
    final r = await db.query('meta',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  /// Bounding-box yakın otobüs durakları (çağıran haversine ile inceler/sıralar).
  Future<List<Stop>> nearbyStops(double lat, double lon, double radiusMeters,
      {int limit = 60}) async {
    final db = _db;
    if (db == null) return const [];
    final dLat = radiusMeters / 111000.0;
    final cosLat = math.cos(lat * math.pi / 180).abs();
    final dLon = radiusMeters / (111000.0 * (cosLat < 0.01 ? 0.01 : cosLat));
    final rows = await db.query('stops',
        where: 'lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?',
        whereArgs: [lat - dLat, lat + dLat, lon - dLon, lon + dLon],
        limit: limit);
    return [for (final r in rows) _stop(r)];
  }

  /// Haritanın GÖRÜNEN alanındaki duraklar (viewport sorgusu). Tüm durakları
  /// belleğe almak yerine yalnızca ekrandaki parça çekilir; harita hareket
  /// ettikçe yeniden çağrılır.
  Future<List<Stop>> stopsInBounds(
    double minLat,
    double maxLat,
    double minLon,
    double maxLon, {
    int limit = 200,
  }) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query('stops',
        where: 'lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?',
        whereArgs: [minLat, maxLat, minLon, maxLon],
        limit: limit);
    return [for (final r in rows) _stop(r)];
  }

  Future<List<Stop>> searchStops(String query, {int limit = 20}) async {
    final db = _db;
    final q = query.trim();
    if (db == null || q.isEmpty) return const [];
    final rows = await db.query('stops',
        where: 'name_norm LIKE ?',
        whereArgs: ['%${transitNorm(q)}%'],
        limit: limit);
    return [for (final r in rows) _stop(r)];
  }

  /// Hafif hat bilgisi (id/code/name) — arama sonuçları için. Tam durak listesi
  /// yalnızca hat seçilince [buildLine] ile yüklenir.
  Future<List<TransitLineBrief>> searchLines(String query,
      {int limit = 20}) async {
    final db = _db;
    final q = query.trim();
    if (db == null || q.isEmpty) return const [];
    final n = transitNorm(q);
    // Hat NO başına TEK sonuç (İETT gibi: "MK13" tek çıkar; gidiş/dönüş
    // varyantları hat detay sayfasında). Temsili: kodun bir varyantı.
    final rows = await db.rawQuery(
      'SELECT id, code, name FROM lines '
      'WHERE code LIKE ? OR name_norm LIKE ? '
      'GROUP BY code ORDER BY LENGTH(code), code LIMIT ?',
      ['$n%', '%$n%', limit],
    );
    return [for (final r in rows) _brief(r)];
  }

  /// Bir hat NO'suna (ör. "MK13") ait tüm varyantlar — hat detay sayfası
  /// gidiş/dönüş ayrımını buradan kurar. Durak sayısına göre azalan.
  Future<List<LineVariant>> directionsForCode(String code) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.rawQuery(
      'SELECT id, name, dir, depar, '
      '(SELECT COUNT(*) FROM line_stops WHERE line_id = lines.id) AS n '
      'FROM lines WHERE code = ? ORDER BY depar, n DESC',
      [code],
    );
    return [
      for (final r in rows)
        LineVariant(
          id: kBusPrefix + (r['id'] as String),
          name: r['name'] as String,
          dir: (r['dir'] as String?) ?? '',
          depar: ((r['depar'] as num?)?.toInt() ?? 0) == 1,
          stopCount: (r['n'] as num).toInt(),
        )
    ];
  }

  /// Bir durağın (dış id) geçtiği otobüs hatları — hat NO başına TEK (aynı
  /// numara/depar'lar birleşir). Temsilci: bu durağı içeren, NORMAL (depar=0)
  /// ve en çok duraklı varyant. İETT'deki gibi durakta her numara bir kez çıkar.
  Future<List<TransitLineBrief>> linesForStop(String externalStopId,
      {int limit = 40}) async {
    final db = _db;
    if (db == null) return const [];
    final raw = _stripId(externalStopId);
    if (raw == null) return const [];
    final rows = await db.rawQuery(
      'SELECT l.code AS code, l.id AS id, l.name AS name, '
      'MIN(l.depar * 1000000 - '
      '(SELECT COUNT(*) FROM line_stops WHERE line_id = l.id)) AS k '
      'FROM line_stops ls JOIN lines l ON l.id = ls.line_id '
      'WHERE ls.stop_id = ? '
      'GROUP BY l.code ORDER BY LENGTH(l.code), l.code LIMIT ?',
      [raw, limit],
    );
    return [for (final r in rows) _brief(r)];
  }

  /// Tam [TransitLine] (sıralı duraklar + segment süreleri). Bus prefix'li id.
  Future<TransitLine?> buildLine(String externalLineId) async {
    final db = _db;
    if (db == null) return null;
    final raw = _stripId(externalLineId);
    if (raw == null) return null;
    final line =
        await db.query('lines', where: 'id = ?', whereArgs: [raw], limit: 1);
    if (line.isEmpty) return null;
    // s.* kullanılır: eski sürüm bir DB'de `district` sütunu bulunmayabilir;
    // sütunu tek tek saymak o durumda SQL hatası verirdi.
    final rows = await db.rawQuery(
      'SELECT ls.seconds AS seconds, s.* '
      'FROM line_stops ls JOIN stops s ON s.id = ls.stop_id '
      'WHERE ls.line_id = ? ORDER BY ls.seq',
      [raw],
    );
    if (rows.length < 2) return null;
    final stops = <Stop>[];
    final segs = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      stops.add(Stop(
        id: kBusPrefix + r['id'].toString(),
        name: r['name'] as String,
        lat: (r['lat'] as num).toDouble(),
        lon: (r['lon'] as num).toDouble(),
        direction: (r['direction'] as String?) ?? '',
        district: (r['district'] as String?) ?? '',
      ));
      if (i > 0) segs.add((r['seconds'] as num?)?.toInt() ?? 90);
    }
    final l = line.first;
    return TransitLine(
      id: kBusPrefix + (l['id'] as String),
      code: l['code'] as String,
      name: l['name'] as String,
      type: LineType.bus,
      stops: stops,
      segmentSeconds: segs,
    );
  }

  Stop _stop(Map<String, Object?> r) => Stop(
        id: kBusPrefix + r['id'].toString(),
        name: r['name'] as String,
        lat: (r['lat'] as num).toDouble(),
        lon: (r['lon'] as num).toDouble(),
        direction: (r['direction'] as String?) ?? '',
        district: (r['district'] as String?) ?? '',
      );

  TransitLineBrief _brief(Map<String, Object?> r) => TransitLineBrief(
        id: kBusPrefix + (r['id'] as String),
        code: r['code'] as String,
        name: r['name'] as String,
      );

  String? _stripId(String id) =>
      id.startsWith(kBusPrefix) ? id.substring(kBusPrefix.length) : null;
}

/// Hafif hat özeti (arama/durak-hatları listeleri için — tam durak listesi yok).
class TransitLineBrief {
  const TransitLineBrief(
      {required this.id, required this.code, required this.name});

  final String id;
  final String code;
  final String name;
}

/// Bir hat NO'sunun tek yön varyantı (hat detay sayfası gidiş/dönüş ayrımı için).
class LineVariant {
  const LineVariant({
    required this.id,
    required this.name,
    required this.dir,
    required this.depar,
    required this.stopCount,
  });

  final String id;
  final String name;

  /// 'G' = gidiş, 'D' = dönüş, '' = belirsiz.
  final String dir;

  /// Depar (garaj/özel sefer) güzergâhı mı — normal gidiş/dönüşten ayrı gösterilir.
  final bool depar;
  final int stopCount;

  bool get isGidis => dir == 'G';
  bool get isDonus => dir == 'D';
}
