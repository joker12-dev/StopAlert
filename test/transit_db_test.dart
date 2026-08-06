import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/data/transit_db.dart';

/// TransitDb sorgu katmanı — gerçek şemayla (tools/gtfs/build_db.py) küçük bir
/// test DB'si kurup yakın durak/arama/rota sorgularını doğrular. Cihaz gerekmez
/// (sqflite_common_ffi masaüstünde koşar).
void main() {
  late Directory tmp;
  late String dbPath;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('stopalert_db');
    dbPath = '${tmp.path}/bus.sqlite';
    final db = await databaseFactory.openDatabase(dbPath);
    await db.execute(
        'CREATE TABLE stops(id INTEGER PRIMARY KEY, name TEXT, name_norm TEXT, direction TEXT, lat REAL, lon REAL)');
    await db.execute(
        'CREATE TABLE lines(id TEXT PRIMARY KEY, code TEXT, name TEXT, name_norm TEXT, dir TEXT, depar INTEGER, type TEXT)');
    await db.execute(
        'CREATE TABLE line_stops(line_id TEXT, seq INTEGER, stop_id INTEGER, seconds INTEGER)');
    await db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)');
    final batch = db.batch();
    batch.insert('stops', {'id': 1, 'name': 'KADIKÖY', 'name_norm': transitNorm('KADIKÖY'), 'direction': 'ÜSKÜDAR', 'lat': 40.990, 'lon': 29.020});
    batch.insert('stops', {'id': 2, 'name': 'ÜSKÜDAR', 'name_norm': transitNorm('ÜSKÜDAR'), 'direction': '', 'lat': 41.025, 'lon': 29.015});
    batch.insert('stops', {'id': 3, 'name': 'FİKİRTEPE', 'name_norm': transitNorm('FİKİRTEPE'), 'direction': '', 'lat': 40.992, 'lon': 29.045});
    batch.insert('lines', {'id': 'L1', 'code': '500T', 'name': 'KADIKÖY - ÜSKÜDAR', 'name_norm': transitNorm('KADIKÖY - ÜSKÜDAR'), 'dir': 'G', 'depar': 0, 'type': 'bus'});
    batch.insert('lines', {'id': 'L2', 'code': '500T', 'name': 'ÜSKÜDAR - KADIKÖY', 'name_norm': transitNorm('ÜSKÜDAR - KADIKÖY'), 'dir': 'D', 'depar': 0, 'type': 'bus'});
    batch.insert('line_stops', {'line_id': 'L2', 'seq': 0, 'stop_id': 2, 'seconds': 0});
    batch.insert('line_stops', {'line_id': 'L2', 'seq': 1, 'stop_id': 1, 'seconds': 200});
    batch.insert('line_stops', {'line_id': 'L1', 'seq': 0, 'stop_id': 1, 'seconds': 0});
    batch.insert('line_stops', {'line_id': 'L1', 'seq': 1, 'stop_id': 3, 'seconds': 120});
    batch.insert('line_stops', {'line_id': 'L1', 'seq': 2, 'stop_id': 2, 'seconds': 150});
    // Özel halk otobüsü: kodu TİRELİ yazılıyor (gerçek İETT verisindeki gibi).
    batch.insert('lines', {'id': 'L3', 'code': 'E-58', 'name': 'MECİDİYEKÖY METROBÜS - ESENKENT', 'name_norm': transitNorm('MECİDİYEKÖY METROBÜS - ESENKENT'), 'dir': 'G', 'depar': 0, 'type': 'bus'});
    batch.insert('meta', {'key': 'version', 'value': '20260728'});
    await batch.commit(noResult: true);
    await db.close();
    await TransitDb.instance.open(dbPath);
  });

  tearDownAll(() async {
    await TransitDb.instance.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('meta okunur', () async {
    expect(await TransitDb.instance.meta('version'), '20260728');
  });

  test('nearbyStops bounding-box içindeki durakları döner', () async {
    // Kadıköy çevresi ~600m: yalnızca KADIKÖY.
    final near = await TransitDb.instance.nearbyStops(40.990, 29.020, 600);
    expect(near.map((s) => s.name), contains('KADIKÖY'));
    expect(near.map((s) => s.name), isNot(contains('ÜSKÜDAR')));
    // id bus: önekli
    expect(near.first.id, startsWith(kBusPrefix));
  });

  test('searchStops isimle arar', () async {
    final r = await TransitDb.instance.searchStops('KADI');
    expect(r, hasLength(1));
    expect(r.first.name, 'KADIKÖY');
  });

  test('searchStops Türkçe-duyarsız (kadikoy -> KADIKÖY) + yön döner', () async {
    final r = await TransitDb.instance.searchStops('kadikoy');
    expect(r, hasLength(1));
    expect(r.first.name, 'KADIKÖY');
    expect(r.first.direction, 'ÜSKÜDAR');
  });

  test('searchLines tireli kodu tiresiz aramayla bulur (E58 -> E-58)', () async {
    // Özel halk otobüslerinin kodu tireli ("E-58") ama kullanıcı tireyi
    // yazmıyor; eskiden hiçbir sonuç dönmüyordu ve bu hatlar yok sanılıyordu.
    final tiresiz = await TransitDb.instance.searchLines('E58');
    expect(tiresiz.map((l) => l.code), contains('E-58'));

    // Tireli yazım da çalışmaya devam etmeli.
    final tireli = await TransitDb.instance.searchLines('E-58');
    expect(tireli.map((l) => l.code), contains('E-58'));

    // Boşluklu yazım da aynı hatta düşer.
    final bosluklu = await TransitDb.instance.searchLines('e 58');
    expect(bosluklu.map((l) => l.code), contains('E-58'));
  });

  test('searchLines kod başına TEK sonuç döner (İETT gibi)', () async {
    // L1 + L2 aynı kod (500T, gidiş+dönüş) → aramada tek "500T".
    final r = await TransitDb.instance.searchLines('500');
    expect(r, hasLength(1));
    expect(r.first.code, '500T');
  });

  test('directionsForCode gidiş+dönüş varyantları döner', () async {
    final v = await TransitDb.instance.directionsForCode('500T');
    expect(v, hasLength(2));
    expect(v.any((x) => x.isGidis), isTrue);
    expect(v.any((x) => x.isDonus), isTrue);
    expect(v.every((x) => !x.depar), isTrue);
  });

  test('buildLine sıralı duraklar + segment süreleri kurar', () async {
    final line = await TransitDb.instance.buildLine('${kBusPrefix}L1');
    expect(line, isNotNull);
    expect(line!.type, LineType.bus);
    expect(line.code, '500T');
    // sıra: KADIKÖY(seq0) -> FİKİRTEPE(seq1) -> ÜSKÜDAR(seq2)
    expect(line.stops.map((s) => s.name).toList(),
        ['KADIKÖY', 'FİKİRTEPE', 'ÜSKÜDAR']);
    // segmentSeconds = [120, 150] (seq0'ın 0'ı atlanır)
    expect(line.segmentSeconds, [120, 150]);
    expect(line.stops.first.id, '${kBusPrefix}1');
  });

  test('linesForStop durağın geçtiği hatları döner', () async {
    final r = await TransitDb.instance.linesForStop('${kBusPrefix}3');
    expect(r.map((l) => l.code), contains('500T'));
  });
}
