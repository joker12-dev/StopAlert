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

/// Hat kodunu ayraçlardan arındırır: "E-58" ve "E 58" → "e58".
///
/// Kod yazımı kaynağa göre değişiyor (İETT özel halk otobüsleri tireli),
/// kullanıcı ise tireyi yazmıyor. Arama iki tarafı da buradan geçirir.
String compactLineCode(String s) => _compactCode(transitNorm(s));

String _compactCode(String norm) => norm.replaceAll(RegExp(r'[\s\-_.]'), '');

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

  /// ARAMA İÇİN açılan ek şehir veritabanları (şehir kimliği -> bağlantı).
  ///
  /// Aktif şehir tek tutulur ama kullanıcı aramada "Tümü"nü seçtiğinde diğer
  /// şehirlerin indirilmiş paketlerinde de aranabilmeli — Kocaeli'deki biri
  /// İstanbul'daki bir durağa bakmak için ayarlardan şehir değiştirmek
  /// zorunda kalmasın.
  final Map<String, Database> _aux = {};

  /// Aramaya açık ek şehirler.
  Iterable<String> get auxCities => _aux.keys;

  /// AKTİF paketin şehri. Sorgular `cityId` ile çağrıldığında bu değere
  /// bakılır: aktif şehrin veritabanı `_db`'dedir, `_aux`'ta DEĞİL.
  ///
  /// Bilinmiyorsa (eski çağrı) `cityId` verilen sorgular yalnızca `_aux`'a
  /// bakar — Kocaeli aktifken sefer saatleri boş dönüyordu, sebebi buydu.
  String? _activeCityId;

  Future<void> open(String path, {String? cityId}) async {
    if (_db != null) return;
    _db = await openDatabase(path, readOnly: true);
    _activeCityId = cityId;
  }

  /// [cityId] için doğru bağlantı: aktif şehir `_db`, ötekiler `_aux`.
  /// null = aktif şehir. Kapalı bir şehir istenirse null döner (yanlış
  /// şehrin verisini döndürmektense boş dönmek doğru).
  Database? _dbFor(String? cityId) {
    if (cityId == null) return _db;
    if (_activeCityId != null && cityId == _activeCityId) return _db;
    return _aux[cityId];
  }

  /// Ek şehir veritabanını arama için aç (zaten açıksa dokunmaz).
  Future<void> openAux(String cityId, String path) async {
    if (_aux.containsKey(cityId)) return;
    try {
      _aux[cityId] = await openDatabase(path, readOnly: true);
    } catch (_) {
      // Paket bozuk/yok: o şehir aramada görünmez.
    }
  }

  Future<void> closeAux() async {
    final all = _aux.values.toList();
    _aux.clear();
    for (final d in all) {
      try {
        await d.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    final d = _db;
    _db = null;
    _activeCityId = null;
    await d?.close();
    await closeAux();
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

  /// TÜM kurulu şehirlerde görünen alandaki duraklar.
  ///
  /// NEDEN: harita "aktif şehir" ayarına değil, kullanıcının BULUNDUĞU yere
  /// bakmalı. Ayarı İstanbul'da kalmış bir kullanıcı Kocaeli'ye gittiğinde
  /// çevresindeki durakları göremiyordu ve şehri elle değiştirmesi
  /// gerekiyordu — harita zaten nerede olduğunu biliyor.
  Future<List<Stop>> stopsInBoundsAllCities(
    double minLat,
    double maxLat,
    double minLon,
    double maxLon, {
    int limit = 200,
  }) async {
    final out = <Stop>[];
    final seen = <String>{};
    for (final db in [if (_db != null) _db!, ..._aux.values]) {
      try {
        final rows = await db.query('stops',
            where: 'lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?',
            whereArgs: [minLat, maxLat, minLon, maxLon],
            limit: limit);
        for (final r in rows) {
          final stop = _stop(r);
          // Aynı durak iki pakette olabilir (sınır şehirleri): tekilleştir.
          if (!seen.add('${stop.name}|${stop.lat}|${stop.lon}')) continue;
          out.add(stop);
        }
      } catch (_) {
        // Bir paket okunamazsa ötekiler yine listelenir.
      }
    }
    return out;
  }

  /// TÜM kurulu şehirlerde yakın duraklar (kaba kutu; çağıran daireye kırpar).
  Future<List<Stop>> nearbyStopsAllCities(
      double lat, double lon, double radiusMeters,
      {int limit = 120}) async {
    final dLat = radiusMeters / 111000.0;
    final cosLat = math.cos(lat * math.pi / 180).abs();
    final dLon = radiusMeters / (111000.0 * (cosLat < 0.01 ? 0.01 : cosLat));
    return stopsInBoundsAllCities(
        lat - dLat, lat + dLat, lon - dLon, lon + dLon,
        limit: limit);
  }

  /// [cityId] verilirse o şehrin ek veritabanında arar (bkz. [openAux]).
  Future<List<Stop>> searchStops(String query,
      {int limit = 20, String? cityId}) async {
    final db = _dbFor(cityId);
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
      {int limit = 20, String? cityId}) async {
    final db = _dbFor(cityId);
    final q = query.trim();
    if (db == null || q.isEmpty) return const [];
    final n = transitNorm(q);
    // TİRE/BOŞLUK YOK SAYILIR. İETT özel halk otobüslerinin kodu tireli
    // yazılıyor ("E-58", "E-59"); kullanıcı doğal olarak "E58" arıyor ve
    // hiçbir sonuç göremiyordu. Karşılaştırma iki tarafta da sadeleştirilmiş
    // kod üzerinden yapılır. (`lines` yalnızca birkaç bin satır; indekssiz
    // REPLACE taraması ölçülebilir bir gecikme yaratmıyor.)
    final compact = _compactCode(n);
    // Hat NO başına TEK sonuç (İETT gibi: "MK13" tek çıkar; gidiş/dönüş
    // varyantları hat detay sayfasında). Temsili: kodun bir varyantı.
    final rows = await db.rawQuery(
      // `*`: eski sürüm bir DB'de `color`/`operator` sütunları bulunmayabilir;
      // tek tek saymak o durumda SQL hatası verirdi.
      'SELECT * FROM lines '
      "WHERE REPLACE(REPLACE(code, '-', ''), ' ', '') LIKE ? "
      'OR code LIKE ? OR name_norm LIKE ? '
      'GROUP BY code ORDER BY LENGTH(code), code LIMIT ?',
      ['$compact%', '$n%', '%$n%', limit],
    );
    return [for (final r in rows) _brief(r)];
  }

  /// Paket RAY/DENİZ hatlarını da taşıyor mu?
  ///
  /// İstanbul paketi v20260809'dan itibaren metro/Marmaray/tramvay/vapur
  /// hatlarını da içeriyor. İçeriyorsa ayrı `rail_*.json` OKUNMAZ — aksi
  /// halde aynı hat iki kaynaktan gelip listelerde çift görünürdü.
  Future<bool> hasRailLines({String? cityId}) async {
    final db = _dbFor(cityId);
    if (db == null) return false;
    try {
      final r = await db.rawQuery(
        "SELECT 1 FROM lines WHERE type NOT IN ('bus','metrobus') LIMIT 1",
      );
      return r.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Verilen durakların BASKIN hat türü: durak kimliği -> tür adı.
  ///
  /// Durak kaydının kendi türü yok; anlamını ondan geçen hatlar veriyor.
  /// Arama sonucunda "Marmaray" mı "Otobüs" mü olduğunu göstermek için
  /// gerekiyordu. Tek sorgu: sonuç sayfası başına bir kez çağrılır.
  Future<Map<String, String>> stopTypes(List<String> externalStopIds,
      {String? cityId}) async {
    final db = _dbFor(cityId);
    if (db == null || externalStopIds.isEmpty) return const {};
    final raw = <String>[];
    for (final id in externalStopIds) {
      final r = _stripId(id);
      if (r != null) raw.add(r);
    }
    if (raw.isEmpty) return const {};
    final marks = List.filled(raw.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT ls.stop_id AS sid, l.type AS t, COUNT(*) AS c '
      'FROM line_stops ls JOIN lines l ON l.id = ls.line_id '
      'WHERE ls.stop_id IN ($marks) GROUP BY ls.stop_id, l.type',
      raw,
    );
    // Durak başına en çok hattı olan tür kazanır.
    final best = <String, (String, int)>{};
    for (final r in rows) {
      final sid = '$kBusPrefix${r['sid']}';
      final t = (r['t'] as String?) ?? 'bus';
      final c = (r['c'] as num?)?.toInt() ?? 0;
      final cur = best[sid];
      if (cur == null || c > cur.$2) best[sid] = (t, c);
    }
    return {for (final e in best.entries) e.key: e.value.$1};
  }

  /// Bir TÜRÜN bütün hatları (kod başına tek kayıt) — "Otobüs" sayfası.
  ///
  /// Kod başına tek sonuç: kullanıcı listede "10A"yı bir kez görmeli,
  /// gidiş/dönüş varyantları hat sayfasında ayrılıyor. Depar (garaj) seferleri
  /// listelenmez — normal yolcu seferi değiller.
  Future<List<TransitLineBrief>> linesByType(String type,
      {String? cityId}) async {
    final db = _dbFor(cityId);
    if (db == null) return const [];
    final rows = await db.rawQuery(
      'SELECT * FROM lines WHERE type = ? AND depar = 0 GROUP BY code',
      [type],
    );
    return [for (final r in rows) _brief(r)];
  }

  /// Bir hattın PAKETTE GÖMÜLÜ sefer saatleri: (yön varyantı id'si, gün, saat).
  ///
  /// Kocaeli'de kalkış saatleri belediyenin hat sayfasından derleme sırasında
  /// çıkarılıp pakete yazılıyor (bkz. tools/kocaeli/build_kocaeli.py); İETT
  /// gibi çalışan bir servis yok. Tablo bulunmayan (eski) paketlerde boş
  /// döner — çağıran "saat bilgisi yok" gösterir.
  Future<List<(String lineId, String day, String time)>> departuresForCode(
    String code, {
    String? cityId,
    String? type,
  }) async {
    final db = _dbFor(cityId);
    if (db == null) return const [];
    try {
      final rows = await db.rawQuery(
        'SELECT d.line_id AS line_id, d.day AS day, d.time AS time '
        'FROM departures d JOIN lines l ON l.id = d.line_id '
        'WHERE l.code = ?${type == null ? '' : ' AND l.type = ?'} '
        'ORDER BY d.time',
        [code, if (type != null) type],
      );
      return [
        for (final r in rows)
          (
            kBusPrefix + (r['line_id'] as String),
            r['day'] as String? ?? '',
            r['time'] as String? ?? '',
          ),
      ];
    } catch (_) {
      // `departures` tablosu yok: paket bu özellikten önce indirilmiş.
      return const [];
    }
  }

  /// Bir hat NO'suna (ör. "MK13") ait tüm varyantlar — hat detay sayfası
  /// gidiş/dönüş ayrımını buradan kurar. Durak sayısına göre azalan.
  Future<List<LineVariant>> directionsForCode(String code,
      {String? cityId, String? type}) async {
    final db = _dbFor(cityId);
    if (db == null) return const [];
    // TÜR SÜZGECİ ŞART: İETT'de M5, M7, F2 KODLU OTOBÜS hatları var ve artık
    // aynı kodlu METRO hatları da aynı pakette. Tür verilmezse hat sayfası
    // ikisini tek listede karıştırırdı.
    final rows = await db.rawQuery(
      'SELECT id, name, dir, depar, '
      '(SELECT COUNT(*) FROM line_stops WHERE line_id = lines.id) AS n '
      'FROM lines WHERE code = ?${type == null ? '' : ' AND type = ?'} '
      'ORDER BY depar, n DESC',
      [code, if (type != null) type],
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

  /// Tek bir durağı kimliğinden getirir (`bus:12345` ya da `12345`).
  ///
  /// Son aramalar yalnızca durak KİMLİĞİNİ saklıyor; kayıt tekrar açılırken
  /// durağın adı ve konumu buradan çözülür.
  Future<Stop?> stopById(String externalStopId, {String? cityId}) async {
    final db = _dbFor(cityId);
    if (db == null) return null;
    final raw = externalStopId.startsWith(kBusPrefix)
        ? externalStopId.substring(kBusPrefix.length)
        : externalStopId;
    final id = int.tryParse(raw);
    if (id == null) return null;
    try {
      final rows = await db.rawQuery(
        'SELECT id, name, lat, lon, dir FROM stops WHERE id = ? LIMIT 1',
        [id],
      );
      if (rows.isEmpty) return null;
      final r = rows.first;
      return Stop(
        id: '$kBusPrefix${r['id']}',
        name: (r['name'] as String? ?? '').trim(),
        lat: (r['lat'] as num?)?.toDouble() ?? 0,
        lon: (r['lon'] as num?)?.toDouble() ?? 0,
        direction: (r['dir'] as String? ?? '').trim(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Bir durağın (dış id) geçtiği otobüs hatları — hat NO başına TEK (aynı
  /// numara/depar'lar birleşir). Temsilci: bu durağı içeren, NORMAL (depar=0)
  /// ve en çok duraklı varyant. İETT'deki gibi durakta her numara bir kez çıkar.
  Future<List<TransitLineBrief>> linesForStop(String externalStopId,
      {int limit = 40, String? cityId}) async {
    final db = _dbFor(cityId);
    if (db == null) return const [];
    final raw = _stripId(externalStopId);
    if (raw == null) return const [];
    final rows = await db.rawQuery(
      'SELECT l.*, '
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
  /// [cityId] verilirse o şehrin ek veritabanından kurar — kullanıcı başka
  /// şehirdeki bir hatta bakarken AKTİF şehri değiştirmek zorunda kalmasın.
  Future<TransitLine?> buildLine(String externalLineId,
      {String? cityId}) async {
    final db = _dbFor(cityId);
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
      type: _typeOf(l['type'] as String?),
      color: (l['color'] as String?) ?? '',
      operator: (l['operator'] as String?) ?? '',
      stops: stops,
      segmentSeconds: segs,
    );
  }

  /// Hattı ÖNCE aktif şehirde, bulunamazsa açık diğer şehirlerde arar.
  ///
  /// Favoriler ve geçmiş yalnızca hat kimliği saklıyor. Kullanıcı Kocaeli'de
  /// favori ekleyip İstanbul'a geçtiğinde aktif veritabanında o hat yok ve
  /// favori "güncel değil" gibi görünüyordu; oysa paketi duruyor.
  Future<TransitLine?> buildLineAnyCity(String externalLineId) async {
    final direct = await buildLine(externalLineId);
    if (direct != null) return direct;
    for (final cityId in _aux.keys) {
      final line = await buildLine(externalLineId, cityId: cityId);
      if (line != null) return line;
    }
    return null;
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
        // Eski sürüm DB'de `type` bulunmayabilir → otobüs varsayılır.
        type: _typeOf(r['type'] as String?),
        color: (r['color'] as String?) ?? '',
        operator: (r['operator'] as String?) ?? '',
      );

  /// DB'deki tür adını [LineType]'a çevir. Kocaeli paketinde tramvay, vapur
  /// ve teleferik de aynı tabloda geliyor.
  static LineType _typeOf(String? name) => switch (name) {
        'metrobus' => LineType.metrobus,
        'tram' => LineType.tram,
        'ferry' => LineType.ferry,
        'funicular' => LineType.funicular,
        'cableCar' => LineType.cableCar,
        'metro' => LineType.metro,
        'marmaray' => LineType.marmaray,
        _ => LineType.bus,
      };

  String? _stripId(String id) =>
      id.startsWith(kBusPrefix) ? id.substring(kBusPrefix.length) : null;
}

/// Hafif hat özeti (arama/durak-hatları listeleri için — tam durak listesi yok).
class TransitLineBrief {
  const TransitLineBrief({
    required this.id,
    required this.code,
    required this.name,
    this.type = LineType.bus,
    this.color = '',
    this.operator = '',
  });

  final String id;
  final String code;
  final String name;

  /// Hattın RESMİ rengi ("#1EA9BD") — beslemede varsa tür rengi yerine bu
  /// kullanılır. Boşsa çağıran [lineTypeColor]'a düşer.
  final String color;

  /// İşletmeci ("ULAŞIM PARK A.Ş.", "SS. 5 Nolu Şehiriçi Koop.") — belediye
  /// otobüsü ile minibüs kooperatifi kullanıcı için farklı deneyim.
  final String operator;

  /// Otobüs mü metrobüs mü — arama sonuçlarında ayrı gösterilir.
  final LineType type;

  bool get isMetrobus => type == LineType.metrobus;
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
