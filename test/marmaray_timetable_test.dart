import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/data/timetable.dart';
import 'package:stopalert/src/data/transit_city.dart';
import 'package:stopalert/src/data/transit_db.dart';
import 'package:stopalert/src/services/timetable_service.dart';

/// YAYINLANAN paketin şemasıyla Marmaray sefer saati yolunu uçtan uca dener.
///
/// "Sefer saati alınamadı" hatası veriye değil koda aitti; bu test aradaki
/// bütün halkaları (tür süzgeci, yön ayrımı, gün tipi) tek seferde kapsıyor.
void main() {
  late Directory tmp;
  late String dbPath;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('stopalert_tt');
    dbPath = '${tmp.path}/bus.sqlite';
    final db = await databaseFactory.openDatabase(dbPath);
    await db.execute(
        'CREATE TABLE stops(id INTEGER PRIMARY KEY, name TEXT, name_norm TEXT, direction TEXT, lat REAL, lon REAL)');
    await db.execute(
        'CREATE TABLE lines(id TEXT PRIMARY KEY, code TEXT, name TEXT, name_norm TEXT, dir TEXT, depar INTEGER, type TEXT)');
    await db.execute(
        'CREATE TABLE line_stops(line_id TEXT, seq INTEGER, stop_id INTEGER, seconds INTEGER)');
    await db.execute(
        'CREATE TABLE departures(line_id TEXT, day TEXT, time TEXT)');
    await db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)');

    final b = db.batch();
    // Metro M5 ile OTOBÜS M5 aynı pakette: tür süzgeci olmazsa karışırlar.
    b.insert('lines', {
      'id': 'R:Marmaray_G', 'code': 'Marmaray', 'name': 'Gebze - Halkalı',
      'name_norm': 'gebze halkali', 'dir': 'G', 'depar': 0, 'type': 'marmaray',
    });
    b.insert('lines', {
      'id': 'R:Marmaray_D', 'code': 'Marmaray', 'name': 'Halkalı - Gebze',
      'name_norm': 'halkali gebze', 'dir': 'D', 'depar': 0, 'type': 'marmaray',
    });
    b.insert('lines', {
      'id': 'M5_G', 'code': 'M5', 'name': 'Otobüs M5',
      'name_norm': 'otobus m5', 'dir': 'G', 'depar': 0, 'type': 'bus',
    });
    for (var i = 0; i < 3; i++) {
      b.insert('stops', {
        'id': 90000000 + i, 'name': 'D$i', 'name_norm': 'd$i',
        'direction': '', 'lat': 41.0 + i * 0.01, 'lon': 29.0,
      });
      b.insert('line_stops', {
        'line_id': 'R:Marmaray_G', 'seq': i,
        'stop_id': 90000000 + i, 'seconds': i == 0 ? 0 : 600,
      });
    }
    for (final t in ['05:58', '23:28', '24:28', '25:28']) {
      b.insert('departures',
          {'line_id': 'R:Marmaray_G', 'day': 'I', 'time': t});
      b.insert('departures',
          {'line_id': 'R:Marmaray_D', 'day': 'I', 'time': t});
    }
    await b.commit(noResult: true);
    await db.close();

    await TransitDb.instance.open(dbPath, cityId: TransitCities.istanbul.id);
  });

  tearDownAll(() async {
    await TransitDb.instance.close();
    await tmp.delete(recursive: true);
  });

  test('paketten Marmaray kalkışları okunur (tür süzgeciyle)', () async {
    final rows = await TransitDb.instance.departuresForCode('Marmaray',
        cityId: TransitCities.istanbul.id, type: 'marmaray');
    expect(rows, isNotEmpty, reason: 'kalkışlar pakette duruyor');
    expect(rows.length, 8);
  });

  test('TimetableService İstanbul RAY hattını PAKETTEN okur', () async {
    // Kritik: İstanbul'da otobüs saatleri İETT servisinden geliyor. Ray hattı
    // yanlışlıkla o servise giderse boş döner ve ekran "alınamadı" der.
    final table = await TimetableService.instance.forLine(
      'Marmaray',
      city: TransitCities.istanbul,
      type: LineType.marmaray,
    );
    expect(table.isEmpty, isFalse, reason: 'ağ değil, paket okunmalı');

    final gidis = table.forDay(DayType.weekday, outbound: true);
    expect(gidis, hasLength(4));
    expect([for (final d in gidis) d.time],
        ['05:58', '23:28', '24:28', '25:28']);

    final donus = table.forDay(DayType.weekday, outbound: false);
    expect(donus, hasLength(4), reason: 'dönüş yönü de gelmeli');
  });

  test('otobüs M5 ile metro/ray kodları karışmaz', () async {
    final busRows = await TransitDb.instance
        .departuresForCode('M5', cityId: TransitCities.istanbul.id, type: 'bus');
    expect(busRows, isEmpty, reason: 'otobüs M5 için kalkış yazılmadı');
  });
}
