// GTFS -> gömülü uygulama verisi dönüştürücüsü.
//
// İBB Açık Veri "Public Transport GTFS Data" setinden raylı sistem + vapur +
// füniküler hatlarını süzer; her hattın yön-0 temsilci seferinden sıralı durak
// listesini ve durak arası seyahat sürelerini çıkarıp
// assets/data/lines.json dosyasını üretir.
//
// Kullanım:
//   dart run tool/gtfs_to_assets.dart <gtfs_klasörü>
//
// Beklenen dosyalar: routes.csv, trips.csv, stops.csv, stop_times.csv
// Bu script tekrar çalıştırılabilir: İBB veriyi güncelledikçe yeniden koşulur
// (PLAN.md - Veri Kaynağı: sessiz güncelleme boru hattının üretici ucu).
import 'dart:convert';
import 'dart:io';

// GTFS route_type -> uygulama hat türü (models.dart LineType adları).
// 9/10 (minibüs/dolmuş) ve İETT otobüsleri bilinçli olarak dışarıda: Faz 2'de
// SQLite tabanlı büyük veri katmanıyla eklenecekler.
const typeMap = {
  '0': 'tram',
  '1': 'metro',
  '4': 'ferry',
  '6': 'cableCar',
  '7': 'funicular',
};

// GTFS'te yeraltı bilgisi yok. İstanbul gerçeğine uyan kaba kural:
// metro durakları yeraltı, Marmaray'ın yalnızca tünel istasyonları yeraltı.
const marmarayUnderground = {'Üsküdar', 'Sirkeci', 'Yenikapı'};

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Kullanım: dart run tool/gtfs_to_assets.dart <gtfs_dizini>');
    exit(64);
  }
  final dir = args.first;

  final routes = readCsv('$dir/routes.csv');
  final trips = readCsv('$dir/trips.csv');
  final stops = readCsv('$dir/stops.csv');
  final stopTimes = readCsv('$dir/stop_times.csv');

  final stopById = {for (final s in stops) s['stop_id']!: s};

  // Süzülen hatlar
  final wantedRoutes = <String, Map<String, String>>{};
  for (final r in routes) {
    final t = typeMap[r['route_type']];
    if (t != null) wantedRoutes[r['route_id']!] = r;
  }

  // route_id -> yön 0 trip_id listesi
  final tripsByRoute = <String, List<String>>{};
  for (final t in trips) {
    final routeId = t['route_id'];
    if (!wantedRoutes.containsKey(routeId)) continue;
    if ((t['direction_id'] ?? '0') != '0') continue;
    tripsByRoute.putIfAbsent(routeId!, () => []).add(t['trip_id']!);
  }

  // trip_id -> [(seq, stopId, arrivalSeconds)]
  final neededTrips = tripsByRoute.values.expand((x) => x).toSet();
  final stopTimesByTrip = <String, List<(int, String, int)>>{};
  for (final st in stopTimes) {
    final tripId = st['trip_id'];
    if (tripId == null || !neededTrips.contains(tripId)) continue;
    final seq = int.tryParse(st['stop_sequence'] ?? '');
    final arr = parseGtfsTime(st['arrival_time'] ?? '');
    final stopId = st['stop_id'];
    if (seq == null || arr == null || stopId == null) continue;
    stopTimesByTrip.putIfAbsent(tripId, () => []).add((seq, stopId, arr));
  }

  final lines = <Map<String, Object>>[];
  for (final entry in wantedRoutes.entries) {
    final route = entry.value;
    // En çok durağı olan sefer = hattın tam güzergâhı.
    List<(int, String, int)>? best;
    for (final tripId in tripsByRoute[entry.key] ?? const <String>[]) {
      final st = stopTimesByTrip[tripId];
      if (st != null && (best == null || st.length > best.length)) best = st;
    }
    if (best == null || best.length < 2) continue;
    best.sort((a, b) => a.$1.compareTo(b.$1));

    var code = (route['route_short_name'] ?? '').trim();
    final longName = titleCaseTr((route['route_long_name'] ?? '').trim());
    if (code.isEmpty) code = longName.split(' ').first;
    var type = typeMap[route['route_type']]!;
    if (code.toLowerCase().startsWith('marmaray')) type = 'marmaray';

    final lineStops = <Map<String, Object>>[];
    final segmentSeconds = <int>[];
    int? prevArr;
    for (final (_, stopId, arr) in best) {
      final s = stopById[stopId];
      if (s == null) continue;
      final name = titleCaseTr((s['stop_name'] ?? '').trim());
      final underground = type == 'metro' ||
          (type == 'marmaray' && marmarayUnderground.contains(name));
      lineStops.add({
        'id': '${route['route_id']}:$stopId',
        'name': name,
        'lat': double.tryParse(s['stop_lat'] ?? '') ?? 0,
        'lon': double.tryParse(s['stop_lon'] ?? '') ?? 0,
        'underground': underground,
      });
      if (prevArr != null) {
        // Aynı dakikaya yuvarlanmış veride 0 çıkabilir; alt sınır 30 sn.
        segmentSeconds.add((arr - prevArr).clamp(30, 3600));
      }
      prevArr = arr;
    }
    if (lineStops.length < 2) continue;

    lines.add({
      'id': route['route_id']!,
      'code': code,
      'name': longName,
      'type': type,
      'stops': lineStops,
      'segmentSeconds': segmentSeconds,
    });
  }

  // Deterministik çıktı: tür + kod sırasına göre.
  const typeOrder = ['marmaray', 'metro', 'tram', 'funicular', 'cableCar', 'ferry'];
  lines.sort((a, b) {
    final t = typeOrder
        .indexOf(a['type'] as String)
        .compareTo(typeOrder.indexOf(b['type'] as String));
    if (t != 0) return t;
    return (a['code'] as String).compareTo(b['code'] as String);
  });

  final outFile = File('assets/data/lines.json');
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(
    const JsonEncoder.withIndent(null).convert({
      'generatedAt': DateTime.now().toIso8601String(),
      'source': 'İBB Açık Veri - Public Transport GTFS',
      'lines': lines,
    }),
  );

  final byType = <String, int>{};
  for (final l in lines) {
    byType.update(l['type'] as String, (v) => v + 1, ifAbsent: () => 1);
  }
  stdout.writeln('Üretildi: ${outFile.path}');
  stdout.writeln('Hat sayısı: ${lines.length} -> $byType');
}

/// "HH:MM:SS" -> saniye (GTFS'te 24'ü aşan saatler olabilir).
int? parseGtfsTime(String t) {
  final parts = t.split(':');
  if (parts.length != 3) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final s = int.tryParse(parts[2]);
  if (h == null || m == null || s == null) return null;
  return h * 3600 + m * 60 + s;
}

/// GTFS'teki TAMAMI BÜYÜK adları Türkçe kurallarıyla başlık düzenine çevirir.
String titleCaseTr(String input) {
  return input.split(' ').map((word) {
    if (word.isEmpty) return word;
    // Kısaltmaları koru (M4, T1, F1, ŞH., AVM ...)
    if (word.length <= 3 && word.toUpperCase() == word && !word.contains('.')) {
      return word;
    }
    final lower = trLower(word);
    return trUpperFirst(lower);
  }).join(' ');
}

String trLower(String s) =>
    s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();

String trUpperFirst(String s) {
  if (s.isEmpty) return s;
  final first = s[0] == 'i' ? 'İ' : (s[0] == 'ı' ? 'I' : s[0].toUpperCase());
  return first + s.substring(1);
}

/// İBB GTFS dosyaları Windows-1254 (ISO 8859-9, Türkçe) kodlamasındadır.
/// latin1'den tek farkı üst bölgedeki Türkçe harflerdir; onları elle eşleriz.
const _win1254Overrides = {
  0xD0: 'Ğ', 0xDD: 'İ', 0xDE: 'Ş',
  0xF0: 'ğ', 0xFD: 'ı', 0xFE: 'ş',
  0xDC: 'Ü', 0xFC: 'ü', 0xD6: 'Ö', 0xF6: 'ö', 0xC7: 'Ç', 0xE7: 'ç',
};

String _decodeWin1254(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.writeCharCode(_win1254Overrides[b]?.codeUnitAt(0) ?? b);
  }
  return sb.toString();
}

/// Tırnaklı alanları da doğru işleyen küçük CSV okuyucu.
List<Map<String, String>> readCsv(String path) {
  final bytes = File(path).readAsBytesSync();
  // UTF-8 dene; başarısızsa Windows-1254 varsay.
  String content;
  try {
    content = utf8.decode(bytes);
  } catch (_) {
    content = _decodeWin1254(bytes);
  }
  final rows = <List<String>>[];
  var field = StringBuffer();
  var row = <String>[];
  var inQuotes = false;
  for (var i = 0; i < content.length; i++) {
    final c = content[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < content.length && content[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      row.add(field.toString());
      field = StringBuffer();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < content.length && content[i + 1] == '\n') i++;
      row.add(field.toString());
      field = StringBuffer();
      if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  if (rows.isEmpty) return const [];
  // BOM temizle
  final header =
      rows.first.map((h) => h.replaceFirst('﻿', '').trim()).toList();
  return [
    for (final r in rows.skip(1))
      {
        for (var i = 0; i < header.length && i < r.length; i++) header[i]: r[i],
      },
  ];
}
