import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/favorite_route.dart';
import '../data/journey_record.dart';
import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/sample_lines.dart';
import '../data/transit_db.dart';
import '../services/bus_data_service.dart';
import 'city_provider.dart';
import '../data/transit_city.dart';
import '../services/journey_repository.dart';
import '../services/profile_repository.dart';
import '../services/location_service.dart';

/// Uygulamadaki hat listesi.
///
/// İBB GTFS'inden üretilmiş gömülü assets/data/lines.json'dan yüklenir
/// (tool/gtfs_to_assets.dart). Asset okunamazsa örnek veriye düşer ki
/// uygulama hiçbir koşulda boş kalmasın.
final linesProvider = FutureProvider<List<TransitLine>>((ref) async {
  try {
    // ÖNCE indirilen paket: metro/tramvay hatları uzadıkça mağaza güncellemesi
    // beklemeden tazelenebilsin. Yoksa APK'daki gömülü kopyaya düşülür — ilk
    // açılışta ağ olmasa da uygulama ray/vapurla çalışmak zorunda.
    final city = ref.watch(activeCityProvider);
    // PAKET RAY HATLARINI TAŞIYORSA ayrı dosya hiç okunmaz: aynı hat iki
    // kaynaktan gelince arama, hat listesi ve yakın duraklar ÇİFT gösteriyordu.
    // (İstanbul paketi v20260809'dan itibaren metro/Marmaray/tramvay/vapur
    // hatlarını, duraklarını ve SEFER SAATLERİNİ de içeriyor.)
    if (await TransitDb.instance.hasRailLines()) return const <TransitLine>[];

    String? raw;
    final path = await BusDataService.instance.railPath(city);
    if (path != null) {
      try {
        raw = await File(path).readAsString();
      } catch (_) {
        raw = null;                       // bozuk dosya: gömülüye düş
      }
    }
    raw ??= await rootBundle.loadString('assets/data/lines.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final lines = [
      for (final l in json['lines'] as List)
        TransitLine.fromJson(l as Map<String, dynamic>),
    ];
    if (lines.isEmpty) return sampleLines;
    return lines;
  } catch (_) {
    return sampleLines;
  }
});

/// Aktif Firebase kullanıcısının uid'i (anonim ya da bağlı hesap).
final authUidProvider = StreamProvider<String?>(
  (ref) => FirebaseAuth.instance.authStateChanges().map((u) => u?.uid),
);

/// Profil (ayarlar + son aramalar) bulut deposu.
final profileRepositoryProvider = Provider((ref) => const ProfileRepository());

/// Yolculuk geçmişi deposu.
final journeyRepositoryProvider = Provider(
  (ref) => JourneyRepository(FirebaseFirestore.instance, FirebaseAuth.instance),
);

/// Kullanıcının yolculuk geçmişi (Firestore canlı akışı, en yeni önce).
final journeysStreamProvider = StreamProvider<List<JourneyRecord>>((ref) {
  final uid = ref.watch(authUidProvider).valueOrNull;
  if (uid == null) return Stream.value(const []);
  return ref.watch(journeyRepositoryProvider).watch(uid);
});

/// Favori rota deposu.
final favoritesRepositoryProvider = Provider(
  (ref) =>
      FavoritesRepository(FirebaseFirestore.instance, FirebaseAuth.instance),
);

/// Kullanıcının favori rotaları (Firestore canlı akışı).
final favoritesStreamProvider = StreamProvider<List<FavoriteRoute>>((ref) {
  final uid = ref.watch(authUidProvider).valueOrNull;
  if (uid == null) return Stream.value(const []);
  return ref.watch(favoritesRepositoryProvider).watch(uid);
});

/// Kullanıcının mevcut konumu + okunabilir semt adı.
class UserLocation {
  const UserLocation({this.point, this.name});
  final LatLng? point;
  final String? name;
}

/// Konumu alır ve semt adına çevirir. İzin yoksa boş UserLocation döner
/// (uygulama yine çalışır; konum kritik akış değil).
final currentLocationProvider = FutureProvider<UserLocation>((ref) async {
  final service = LocationService();
  final point = await service.currentLocation();
  if (point == null) return const UserLocation();
  final name = await service.reverseGeocode(point);
  return UserLocation(point: point, name: name);
});

/// Kullanıcıya en yakın durak (tüm hatlardan; aynı adlı durak tekilleştirilir).
class NearbyStopHit {
  const NearbyStopHit({
    required this.stop,
    required this.meters,
    this.line,
  });

  /// Ray/vapur durağıysa ait olduğu hat (doğrudan alarm kurulabilir).
  /// Otobüs durağında NULL: hangi hatla gidileceği kullanıcıya sorulur.
  final TransitLine? line;
  final Stop stop;
  final double meters;

  bool get isBus => line == null;
}

/// Konuma göre en yakın duraklar — ana sayfa ve arama önerileri için.
/// Konum yoksa boş liste döner (ekranlar bilgilendirici boş durum gösterir).
final nearbyStopsProvider = FutureProvider<List<NearbyStopHit>>((ref) async {
  final lines = await ref.watch(linesProvider.future);
  final loc = (await ref.watch(currentLocationProvider.future)).point;
  if (loc == null) return const [];
  const distance = Distance();
  final best = <String, NearbyStopHit>{};

  // Ray/vapur — APK'da gömülü hatlar.
  for (final line in lines) {
    for (final stop in line.stops) {
      if (stop.lat == 0 && stop.lon == 0) continue;
      final d = distance.as(LengthUnit.Meter, loc, LatLng(stop.lat, stop.lon));
      final key = stop.name.toLowerCase();
      final cur = best[key];
      if (cur == null || d < cur.meters) {
        best[key] = NearbyStopHit(line: line, stop: stop, meters: d);
      }
    }
  }

  // OTOBÜS — indirilen veri paketinden. Bu katman eksikti: ev/iş çevresinde
  // otobüs durağı 100 m ötedeyken 2 km uzaktaki Marmaray "en yakın durak"
  // olarak listeleniyordu.
  if (TransitDb.instance.isReady) {
    // TÜM kurulu şehirlerde: aktif şehir ayarı kullanıcının bulunduğu yeri
    // değiştirmiyor; çevresindeki duraklar her hâlükârda görünmeli.
    final busStops = await TransitDb.instance
        .nearbyStopsAllCities(loc.latitude, loc.longitude, 900, limit: 120);
    for (final stop in busStops) {
      final d = distance.as(LengthUnit.Meter, loc, LatLng(stop.lat, stop.lon));
      // Aynı adlı durağın yön varyantları tek satıra iner.
      final key = stop.name.toLowerCase();
      final cur = best[key];
      if (cur == null || d < cur.meters) {
        best[key] = NearbyStopHit(stop: stop, meters: d);
      }
    }
  }

  final list = best.values.toList()
    ..sort((a, b) => a.meters.compareTo(b.meters));
  return list.take(6).toList();
});

/// Yakındaki duraklar haritası için tek durak (ray/vapur veya otobüs).
class MapStop {
  const MapStop({required this.stop, required this.meters, this.line});
  final Stop stop;
  final double meters;

  /// Ray/vapur ise hat (doğrudan alarm); otobüs ise null (durak → hat seçimi).
  final TransitLine? line;
  bool get isBus => line == null;
}

/// Konum çevresindeki duraklar (ray/vapur + otobüs), en yakından uzağa.
/// Yakındaki-duraklar HARİTASI ekranı bunu kullanır.
///
/// Sabit yarıçap YOK: kullanıcı veri kapsamının dışındaysa (ör. Kocaeli —
/// İETT yalnızca İstanbul) ekran boş kalmasın diye otobüs araması kademeli
/// genişler ve ray/vapur her hâlükârda en yakınlardan doldurulur. Ekran
/// mesafeyi zaten gösterir; uzaklık kararını kullanıcı verir.
final nearbyMapProvider = FutureProvider<List<MapStop>>((ref) async {
  final loc = (await ref.watch(currentLocationProvider.future)).point;
  if (loc == null) return const [];
  const distance = Distance();
  final out = <MapStop>[];

  // Ray/vapur (bellekteki hatlar) — aynı adlı durağı tekilleştir, sınır yok.
  final lines = await ref.watch(linesProvider.future);
  final bestRail = <String, MapStop>{};
  for (final line in lines) {
    for (final stop in line.stops) {
      if (stop.lat == 0 && stop.lon == 0) continue;
      final d = distance.as(LengthUnit.Meter, loc, LatLng(stop.lat, stop.lon));
      final key = stop.name.toLowerCase();
      final cur = bestRail[key];
      if (cur == null || d < cur.meters) {
        bestRail[key] = MapStop(stop: stop, meters: d, line: line);
      }
    }
  }
  final rail = bestRail.values.toList()
    ..sort((a, b) => a.meters.compareTo(b.meters));
  out.addAll(rail.take(20));

  // Otobüs (yerel SQLite bbox) — yakında yoksa yarıçapı kademeli genişlet.
  if (TransitDb.instance.isReady) {
    var busStops = const <Stop>[];
    for (final radius in [1500.0, 5000.0, 20000.0, 60000.0]) {
      busStops = await TransitDb.instance
          .nearbyStops(loc.latitude, loc.longitude, radius, limit: 120);
      if (busStops.isNotEmpty) break;
    }
    final bestBus = <String, MapStop>{};
    for (final s in busStops) {
      final d = distance.as(LengthUnit.Meter, loc, LatLng(s.lat, s.lon));
      final key = '${s.name.toLowerCase()}|${s.direction.toLowerCase()}';
      final cur = bestBus[key];
      if (cur == null || d < cur.meters) {
        bestBus[key] = MapStop(stop: s, meters: d, line: null);
      }
    }
    final bus = bestBus.values.toList()
      ..sort((a, b) => a.meters.compareTo(b.meters));
    out.addAll(bus.take(40));
  }

  out.sort((a, b) => a.meters.compareTo(b.meters));
  return out.take(60).toList();
});

/// Otobüs (İETT SQLite) arama sonuçları: eşleşen hatlar + duraklar. DB henüz
/// inmemişse/açılmamışsa boş döner (ray/vapur sonuçları yine görünür).
class BusSearchResults {
  const BusSearchResults({this.lines = const [], this.stops = const []});

  /// Sonuçlar hangi şehirden geldiğini TAŞIR: arama bütün kurulu paketlerde
  /// yapılıyor ve "İZMİT" ile İstanbul'daki "İZMİT CADDESİ" aynı listede
  /// çıkabiliyor. Şehir etiketi olmadan ayırt edilemezdi.
  final List<CityLine> lines;
  final List<CityStop> stops;
  bool get isEmpty => lines.isEmpty && stops.isEmpty;
}

/// Şehir etiketli hat sonucu.
typedef CityLine = ({TransitLineBrief line, TransitCity city});

/// Şehir etiketli durak sonucu.
typedef CityStop = ({Stop stop, TransitCity city});

/// Sorguya göre otobüs hat/durak araması (yerel SQLite'tan, hızlı). En az 2
/// karakterden sonra çalışır; her sorgu Riverpod tarafından tekil önbelleklenir.
final busSearchProvider =
    FutureProvider.autoDispose.family<BusSearchResults, String>(
  (ref, query) async {
    final q = query.trim();
    if (q.length < 2) return const BusSearchResults();
    final db = TransitDb.instance;
    if (!db.isReady) return const BusSearchResults();
    final active = ref.watch(activeCityProvider);

    final lines = <CityLine>[];
    final stops = <CityStop>[];

    // 1) Aktif şehir — açık olan ana veritabanı.
    for (final l in await db.searchLines(q, limit: 12)) {
      lines.add((line: l, city: active));
    }
    for (final st in await db.searchStops(q, limit: 20)) {
      stops.add((stop: st, city: active));
    }

    // 2) İNDİRİLMİŞ DİĞER ŞEHİRLER. Filtre yok: kullanıcı hangi şehirde
    //    olduğunu düşünmeden arasın. Kocaeli'deki biri İstanbul'daki bir
    //    durağa bakmak için ayar değiştirmek zorunda kalmamalı.
    for (final c in TransitCities.all) {
      if (c.id == active.id) continue;
      final path = await BusDataService.instance.localPath(c);
      if (path == null) continue;              // paketi yok: aramaya girmez
      await db.openAux(c.id, path);
      for (final l in await db.searchLines(q, limit: 8, cityId: c.id)) {
        lines.add((line: l, city: c));
      }
      for (final st in await db.searchStops(q, limit: 12, cityId: c.id)) {
        stops.add((stop: st, city: c));
      }
    }

    return BusSearchResults(lines: lines, stops: stops);
  },
);

/// Paketi CİHAZDA olan şehirler (Veri Paketleri ekranı ve arama için).
final installedCitiesProvider = FutureProvider<List<TransitCity>>((ref) async {
  final out = <TransitCity>[];
  for (final c in TransitCities.all) {
    if (await BusDataService.instance.hasLocal(c)) out.add(c);
  }
  return out;
});

/// Son aramalar (cihazda kalıcı; en yeni önce, en fazla 5 kayıt).
final recentSearchesProvider =
    AsyncNotifierProvider<RecentSearchesNotifier, List<RecentSearch>>(
  RecentSearchesNotifier.new,
);

class RecentSearchesNotifier extends AsyncNotifier<List<RecentSearch>> {
  static const _prefsKey = 'recent_searches';

  @override
  Future<List<RecentSearch>> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list) RecentSearch.fromMap(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Bir durak veya hat seçildiğinde çağrılır: kaydı başa alır, sınırlar.
  ///
  /// Tekilleştirme HAT + DURAK ikilisine göre yapılır. Yalnızca `stopId`'ye
  /// bakmak hatalıydı: hat kayıtlarında (durak seçilmeden açılan hat sayfası)
  /// `stopId` boş olduğu için her yeni hat araması bir öncekini siliyordu ve
  /// listede tek bir hat kalabiliyordu.
  Future<void> add(RecentSearch entry) async {
    final current = state.valueOrNull ?? const <RecentSearch>[];
    final next = [
      entry,
      ...current.where(
          (e) => !(e.lineId == entry.lineId && e.stopId == entry.stopId)),
    ].take(8).toList();
    state = AsyncData(next);
    await _persist(next);
  }

  Future<void> _persist(List<RecentSearch> next) async {
    final prefs = await SharedPreferences.getInstance();
    final maps = [for (final e in next) e.toMap()];
    await prefs.setString(_prefsKey, jsonEncode(maps));
    // Buluta da yaz: kullanıcı başka telefondan hesabına girdiğinde son
    // aramaları da gelsin (favoriler zaten geliyordu).
    await ref.read(profileRepositoryProvider).saveRecents(maps);
  }

  /// Buluttan gelen kayıtları YEREL LİSTENİN ÜSTÜNE koyar (giriş sonrası).
  ///
  /// Yerel kayıtlar silinmez: kullanıcı bu cihazda yaptığı aramaları da
  /// kaybetmemeli. Aynı hat+durak ikilisi tekilleşir.
  Future<void> mergeFromCloud(List<Map<String, dynamic>> maps) async {
    if (maps.isEmpty) return;
    final incoming = [for (final m in maps) RecentSearch.fromMap(m)];
    final current = state.valueOrNull ?? const <RecentSearch>[];
    final seen = <String>{};
    final merged = <RecentSearch>[];
    for (final e in [...incoming, ...current]) {
      if (!seen.add('${e.lineId}|${e.stopId}')) continue;
      merged.add(e);
    }
    final next = merged.take(8).toList();
    state = AsyncData(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([for (final e in next) e.toMap()]),
    );
  }

  /// Geçmişi tamamen sil (son aramalar sayfasındaki "Temizle").
  Future<void> clear() async {
    state = const AsyncData([]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}

/// Kurulmakta olan yolculuk taslağı.
final journeyDraftProvider =
    NotifierProvider<JourneyDraftNotifier, JourneyDraft>(
  JourneyDraftNotifier.new,
);

class JourneyDraftNotifier extends Notifier<JourneyDraft> {
  @override
  JourneyDraft build() => const JourneyDraft();

  void selectLine(TransitLine line) => state = state.copyWith(line: line);

  void selectBoardingStop(String stopId) =>
      state = state.copyWith(boardingStopId: stopId);

  void selectTargetStop(String stopId) =>
      state = state.copyWith(targetStopId: stopId);

  void reset() => state = const JourneyDraft();
}

/// Duraklar sekmesinden Hatlar sekmesine TAŞINAN arama sorgusu.
///
/// Kullanıcı Duraklar'da "147" arayıp ipucuna dokunduğunda, Hatlar sekmesi
/// aramayı hazır dolu açsın diye. Okuyan taraf tüketip null'a çeker.
final pendingLineQueryProvider = StateProvider<String?>((ref) => null);
