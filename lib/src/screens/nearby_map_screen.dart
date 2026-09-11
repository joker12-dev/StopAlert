import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../services/bus_data_service.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../state/live_location_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/native_ad_slot.dart';
import '../util/haptics.dart';
import '../util/insets.dart';
import '../util/latlng_guard.dart';
import '../util/map_settle.dart';
import '../util/map_style.dart';
import '../widgets/map_style_sheet.dart';
import 'stop_lines_screen.dart';

/// Yakındaki Duraklar HARİTASI: üstte harita (yakın duraklar işaretli),
/// altta yüksekliği ayarlanabilen panel (en yakından uzağa liste). Bir durağa
/// dokununca harita o durağa zoomlanır ve konumundan durağa YÜRÜME ROTASI
/// (OSRM, yollardan) çizilir — kullanıcı nereden gideceğini görür.
class NearbyMapScreen extends ConsumerStatefulWidget {
  const NearbyMapScreen({
    super.key,
    this.focusStop,
    this.embedded = false,
  });

  /// SEKME İÇİNDE mi gösteriliyor (Duraklar sekmesi)?
  ///
  /// Gömülüyken kendi üst çubuğunu çizmez — arama çubuğunu saran ekran
  /// koyar — ve geri butonu göstermez (sekmeden çıkılacak bir yer yok).
  final bool embedded;

  /// Verilirse harita bu durağa odaklanır ve durak seçili açılır
  /// (durak sayfasındaki "Haritada göster" akışı).
  final Stop? focusStop;

  @override
  ConsumerState<NearbyMapScreen> createState() => _NearbyMapScreenState();
}

class _NearbyMapScreenState extends ConsumerState<NearbyMapScreen> {
  final _map = MapController();
  bool _mapReady = false;

  MapStop? _selected;

  /// Seçili otobüs durağından geçen hatlar (panelde rozet olarak listelenir).

  /// Arama noktası çevresindeki duraklar + yükleme durumu.
  List<MapStop> _visible = const [];
  bool _loadingStops = false;
  Timer? _debounce;

  /// Aynı anda ikinci bir yükleme başlamasın (hızlı harita hareketinde
  /// üst üste binen sorgular durumu bozuyordu).
  bool _reloading = false;

  /// Alt panelin kapladığı yükseklik — turuncu nokta ekranın değil, GÖRÜNEN
  /// harita alanının ortasına konumlanır (panel arkasına düşmesin).
  double _panelHeight = 0;

  /// Anlık yakınlaşma — durak adlarının yazılıp yazılmayacağını belirler.
  double _zoom = 15;

  /// TURUNCU arama noktası: haritanın merkezi. Haritayı gezdirdikçe taşınır ve
  /// çevresindeki [_radius] metre içindeki duraklar listelenir (mavi nokta =
  /// kullanıcının gerçek konumu, o sabittir).
  ///
  /// setState DEĞİL, ayrı bir dinleyici olmasının sebebi: kaydırma sırasında
  /// bu değer her karede değişiyor ve setState ile 200 durak işareti de her
  /// karede yeniden kuruluyordu. Hızlı savurmada Dart yığını tükenip uygulama
  /// "Out of Memory" ile çöküyordu (cihaz logunda kayıtlı). Artık yalnızca
  /// daire ve turuncu nokta yeniden çizilir.
  final _probe = ValueNotifier<LatLng?>(null);

  /// Harita hareket ederken durak işaretleri çizilmez (bkz. [MapSettle]).
  final _settle = MapSettle();

  /// İlk gerçek konuma bir kez ortalandı mı?
  bool _centeredOnUser = false;

  /// Kullanıcı haritayı elle oynattı mı? Oynattıysa kamera altından çekilmez.
  bool _userMovedMap = false;

  /// Arama yarıçapı (metre) — kullanıcı çipten değiştirir.
  double _radius = 250;
  static const _radiusOptions = [250.0, 500.0, 1000.0];

  // Sürüklenebilir panel (Alarm Kur ekranındaki gibi).
  static const _minFraction = 0.28;
  static const _maxFraction = 0.75;
  // VARSAYILAN yükseklik ekranın %60'ı: durak listesi ilk açılışta daha
  // görünür olsun (kullanıcı çoğu zaman haritadan çok listeyle işi var).
  // Kullanıcı tutamaçtan [_minFraction, _maxFraction] arasında değiştirir.
  double _panelFraction = 0.60;
  double _availableHeight = 0;

  /// Kullanıcının ANLIK konumu — canlı GPS akışından (mavi nokta bunu izler).
  ///
  /// Eskiden tek seferlik [currentLocationProvider] okunuyordu ve nokta
  /// açılışta donup kalıyordu; yürürken hareket etmiyordu.
  LatLng? get _userLoc => ref.read(liveLocationProvider).valueOrNull;

  @override
  void dispose() {
    _debounce?.cancel();
    _probe.dispose();
    _settle.dispose();
    super.dispose();
  }

  /// TURUNCU noktanın coğrafi konumu: ekranın tam ortası DEĞİL, alt panelin
  /// üstünde kalan GÖRÜNEN harita alanının ortası. Böylece nokta panelin
  /// arkasına gizlenmez ve kullanıcı neyi aradığını görür.
  LatLng _probeLatLng() {
    final cam = _map.camera;
    final size = cam.nonRotatedSize;
    if (_panelHeight <= 0 || size.height <= 0) return cam.center;
    // Görünen alanın ortası, ekran merkezinden panelin yarısı kadar yukarıda.
    final y = (size.height - _panelHeight) / 2;
    try {
      final p = cam.screenOffsetToLatLng(Offset(size.width / 2, y));
      // SONLULUK ŞART: çok parmaklı jest sırasında bu dönüşüm NaN
      // üretebiliyor ve NaN'lı bir marker flutter_map'i her karede
      // hataya düşürüp uygulamayı ANR'a kilitliyordu.
      return p.isUsable ? p : cam.center;
    } catch (_) {
      return cam.center;
    }
  }

  /// Durak işareti + (yakınlaşınca) adı.
  ///
  /// Adlar eskiden yalnızca dokununca görünüyordu; kullanıcı hangi durağın
  /// hangisi olduğunu tek tek dokunarak bulmak zorunda kalıyordu. Uzak
  /// zoom'da yazılmaz — 200 durak etiketi haritayı okunmaz yapar.
  Marker? _stopMarker(MapStop m) {
    final point = safeLatLng(m.stop.lat, m.stop.lon);
    if (point == null) return null;   // bozuk koordinat: çizme
    final selected = _isSelected(m);
    // ETİKET KURALI: bir durak seçiliyse YALNIZCA onun adı yazılır, ötekiler
    // sade kırmızı çember kalır — seçtiğin durağı kalabalıkta kaybetmeyesin.
    // Seçim yokken adlar ancak epey yakınlaşınca çıkar; daha uzakta 200
    // etiket üst üste binip haritayı okunmaz yapıyordu.
    final showLabel =
        _selected != null ? selected : _zoom >= _labelZoom;
    final dotBox = selected ? 38.0 : 20.0;
    final height = showLabel ? dotBox + 34 : dotBox;
    return Marker(
      point: point,
      width: showLabel ? 128 : dotBox,
      height: height,
      // Yuvarlağın MERKEZİ koordinata otursun (etiket kutuyu uzatıyor).
      alignment: showLabel
          ? Alignment(0, dotBox / height - 1)
          : Alignment.center,
      child: GestureDetector(
        onTap: () => _selectStop(m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: dotBox,
              height: dotBox,
              child: _StopMarker(selected: selected, isBus: m.isBus),
            ),
            if (showLabel)
              Flexible(
                child: Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: selected
                        ? VigilantColors.primary
                        : Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    m.stop.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9.5,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Durak adlarının yazıldığı yakınlaşma eşiği.
  ///
  /// 15.0'da bir mahalledeki bütün duraklar aynı anda etiketleniyor ve
  /// karmaşa oluyordu; 16.2'de ancak birkaç sokak görünür.
  static const _labelZoom = 16.2;

  /// [point]'i ekranın değil, GÖRÜNEN harita alanının (panelin üstünde kalan
  /// kısım) ortasına getirir.
  ///
  /// Düz `move` kullanınca nokta ekran ortasına geliyor ama alt panel ekranın
  /// ~%42'sini kapattığı için kullanıcının mavi noktası panelin dibinde
  /// kalıyordu. Kamerayı panelin yarısı kadar yukarı kaydırmak gerekiyor.
  void _centerOnVisible(LatLng point, double zoom) {
    _map.move(point, zoom);
    if (_panelHeight <= 0) return;
    try {
      final cam = _map.camera;
      final size = cam.nonRotatedSize;
      if (size.height <= 0) return;
      // Görünen alanın ortasındaki koordinat...
      final visibleCenter = cam.screenOffsetToLatLng(
          Offset(size.width / 2, (size.height - _panelHeight) / 2));
      if (!visibleCenter.isUsable) return;
      // ...noktaya eşit olacak şekilde kamerayı ötele.
      final target = LatLng(
        cam.center.latitude + (point.latitude - visibleCenter.latitude),
        cam.center.longitude + (point.longitude - visibleCenter.longitude),
      );
      if (target.isUsable) _map.move(target, zoom);
    } catch (_) {
      // Kamera henüz ölçülmediyse düz ortalama yeterli.
    }
  }

  /// Harita OYNARKEN turuncu noktayı anında taşı (veri yükleme bekler).
  void _updateProbeLive() {
    if (!_mapReady || !mounted) return;
    try {
      final p = _probeLatLng();
      final cur = _probe.value;
      // EŞİK ŞART: `==` karşılaştırması yetmiyordu. Ekran koordinatından
      // üretilen değer her hesapta epsilon kadar oynuyor, guard hiç tutmuyor
      // ve her layout geçişinde katmanlar yeniden kuruluyordu.
      if (cur != null && const Distance().as(LengthUnit.Meter, cur, p) < 1) {
        return;
      }
      // LAYOUT SIRASINDA BİLDİRME: flutter_map bu geri çağrıyı kendi layout
      // aşamasında tetikliyor; burada dinleyicileri uyandırmak aynı karede
      // yeniden çizim başlatıp layout'u tekrar çalıştırıyor ve döngü
      // kapanmıyordu (profilde MarkerLayer.build 28.000 kez görüldü, ANR).
      _pendingProbe = p;
      _flushProbeAfterFrame();
    } catch (_) {
      // kamera henüz hazır değil
    }
  }

  LatLng? _pendingProbe;
  bool _probeFlushScheduled = false;

  /// Bekleyen sonda konumunu KARE BİTTİKTEN sonra yayınla.
  void _flushProbeAfterFrame() {
    if (_probeFlushScheduled) return;
    _probeFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeFlushScheduled = false;
      if (!mounted) return;
      final p = _pendingProbe;
      if (p != null) _probe.value = p;
    });
  }

  /// Veri yüklemesi yalnızca hareket durunca yapılır (sorgu israfı olmasın).
  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _reloadVisible);
  }

  /// TURUNCU arama noktasının (harita merkezi) [_radius] metre çevresindeki
  /// durakları yükle. Tüm şehri belleğe almak yerine yalnızca bu daireyi
  /// sorgular (otobüs = indeksli SQLite bbox + daire filtresi).
  Future<void> _reloadVisible() async {
    if (!_mapReady || !mounted || _reloading) return;
    // Kamera yalnızca harita çizildikten sonra okunabilir; hızlı hareket/çıkış
    // sırasında erişim hata verebiliyor.
    final LatLng probe;
    try {
      probe = _probeLatLng();
    } catch (_) {
      return;
    }
    _reloading = true;
    _probe.value = probe;
    setState(() => _loadingStops = true);

    const distance = Distance();
    final r = _radius;
    final out = <MapStop>[];

    // Ray/vapur — bellekteki hatlar; daire içi, aynı adlı durak tekilleştirilir.
    final lines = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    final rail = <String, MapStop>{};
    for (final line in lines) {
      for (final s in line.stops) {
        if (s.lat == 0 && s.lon == 0) continue;
        final d = distance.as(LengthUnit.Meter, probe, LatLng(s.lat, s.lon));
        if (d > r) continue;
        final key = s.name.toLowerCase();
        final cur = rail[key];
        if (cur == null || d < cur.meters) {
          rail[key] = MapStop(stop: s, meters: d, line: line);
        }
      }
    }
    out.addAll(rail.values);

    // Otobüs — daireyi çevreleyen dikdörtgeni sorgula, sonra daireye kırp.
    if (TransitDb.instance.isReady) {
      final dLat = r / 111000.0;
      final cosLat = math.cos(probe.latitude * math.pi / 180).abs();
      final dLon = r / (111000.0 * (cosLat < 0.01 ? 0.01 : cosLat));
      // TÜM kurulu şehirlerde: kullanıcı ayarı İstanbul'da kalmışken
      // Kocaeli'ye gittiğinde çevresini görebilsin.
      final busStops = await TransitDb.instance.stopsInBoundsAllCities(
        probe.latitude - dLat,
        probe.latitude + dLat,
        probe.longitude - dLon,
        probe.longitude + dLon,
        limit: 300,
      );
      final bus = <String, MapStop>{};
      for (final s in busStops) {
        final d = distance.as(LengthUnit.Meter, probe, LatLng(s.lat, s.lon));
        if (d > r) continue;
        final key = '${s.name.toLowerCase()}|${s.direction.toLowerCase()}';
        final cur = bus[key];
        if (cur == null || d < cur.meters) {
          bus[key] = MapStop(stop: s, meters: d, line: null);
        }
      }
      out.addAll(bus.values);
    }

    out.sort((a, b) => a.meters.compareTo(b.meters));
    _reloading = false;
    if (!mounted) return;
    setState(() {
      _visible = out.take(200).toList();
      _loadingStops = false;
    });
  }

  /// Harita görünümü seçici — ortak sayfa (bkz. widgets/map_style_sheet.dart).
  Future<void> _pickMapStyle() async {
    if (await pickMapStyle(context, ref) && mounted) setState(() {});
  }

  void _setRadius(double r) {
    if (_radius == r) return;
    Haptics.selection();
    setState(() => _radius = r);
    _reloadVisible();
  }

  /// Kullanıcının konumu kapsam dışındaysa (ör. Kocaeli) en yakın durağa git.
  /// Kamerayı kullanıcının konumuna götür.
  void _centerOnMe() {
    final user = _userLoc;
    if (user == null || !user.isUsable) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Konum alınamadı — konum iznini kontrol et.')));
      return;
    }
    Haptics.light();
    // Elle konuma dönmek "haritayı ben yönetiyorum" demek değil: sonraki
    // otomatik ortalama yine susmalı, o yüzden bayrağa dokunulmuyor.
    _centerOnVisible(user, 16);
  }

  Future<void> _goToNearest() async {
    final nearest = ref.read(nearbyMapProvider).valueOrNull;
    if (nearest == null || nearest.isEmpty || !_mapReady) return;
    Haptics.light();
    final s = nearest.first.stop;
    _centerOnVisible(LatLng(s.lat, s.lon), 15);
    await _reloadVisible();
  }

  /// Durağa dokunulunca: haritayı O DURAĞA yakınlaştır ve panelde durak
  /// bilgilerini + o duraktan geçen hatları göster.
  ///
  /// Yürüme rotası ARTIK OTOMATİK ÇİZİLMEZ — kullanıcı istemediği hâlde
  /// konumundan rota oluşuyordu; artık panelden "Yol tarifi" ile istenir.
  Future<void> _selectStop(MapStop m) async {
    Haptics.light();
    setState(() {
      _selected = m;
      _selectedLines = const [];
    });
    unawaited(_loadSelectedLines(m.stop));
    if (_mapReady) {
      try {
        _centerOnVisible(LatLng(m.stop.lat, m.stop.lon), 16.5);
      } catch (_) {
        // Kamera hesabı başarısızsa haritayı bozma; seçim yine de geçerli.
      }
    }
    // YOL TARİFİ ÇİZİLMEZ. Çizildiğinde iki sorun oluyordu: harita kullanıcı
    // ile durağı birlikte sığdırmak için geri çekiliyor ("konuma git" seçili
    // durağa gitmiyor gibi görünüyordu) ve kimsenin istemediği bir mavi
    // çizgi haritayı dolduruyordu. Mesafe/yürüme süresi panelde zaten yazıyor.
  }

  /// Seçimi temizle: harita işaretleri ve panel eski hâline döner.
  void _clearSelection() {
    Haptics.light();
    setState(() {
      _selected = null;
      _selectedLines = const [];
    });
  }

  String _walkMinutes(double meters) {
    final dk = (meters / 80).ceil();
    return '~${dk < 1 ? 1 : dk} dk yürüme';
  }

  String _fmt(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
      : '${m.round()} m';

  bool _isSelected(MapStop m) => _selected?.stop.id == m.stop.id;

  /// Seçili duraktan geçen hatlar — panele gömülü durak sayfasına verilir.
  List<TransitLineBrief> _selectedLines = const [];

  /// Otobüs durakları indirilen pakette, ray/vapur ayrı listede — ikisine de
  /// bakılır, yoksa metro duraklarında liste boş kalırdı.
  Future<void> _loadSelectedLines(Stop stop) async {
    List<TransitLineBrief> found = const [];
    if (isBusId(stop.id)) {
      try {
        // KURULU PAKETLERİ AÇ VE HEPSİNDE ARA: harita bütün illerin
        // duraklarını gösteriyor; İstanbul seçiliyken Kocaeli'deki bir durağa
        // dokunulduğunda sorgu aktif pakete gidip boş dönüyordu.
        await BusDataService.instance.openAllForLookup();
        found = await TransitDb.instance.linesForStopAnyCity(stop.id);
        final cityId = await TransitDb.instance.cityOfStop(stop.id);
        if (mounted && cityId != null && cityId != _selectedCityId) {
          setState(() => _selectedCityId = cityId);
        }
      } catch (_) {
        found = const [];
      }
    } else {
      final rail = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
      found = [
        for (final l in rail)
          if (l.stops.any((x) => x.id == stop.id))
            TransitLineBrief(
                id: l.id, code: l.code, name: l.name, type: l.type),
      ];
    }
    if (!mounted || _selected?.stop.id != stop.id) return;
    setState(() => _selectedLines = found);
  }

  /// Seçili durağın ait olduğu şehir (aktif şehirden farklı olabilir).
  String? _selectedCityId;

  /// Çizilecek işaretler: görünen alandakiler + (listede yoksa) seçili durak.
  List<MapStop> _markerStops(List<MapStop> visible) {
    final sel = _selected;
    if (sel == null || visible.any((m) => m.stop.id == sel.stop.id)) {
      return visible;
    }
    return [...visible, sel];
  }

  /// İşaretler ÖNBELLEKTE — kamera her karesinde yeniden kurulmaz.
  ///
  /// `MarkerLayer.build` jest boyunca her karede çalışır; işaret listesi orada
  /// üretilirse yüzlerce durağın widget ağacı da her karede yeniden kurulur.
  /// Profilde ölçülen %93'lük CPU payının kaynağı buydu.
  ///
  /// Anahtar üç şeyden oluşuyor: görünen durak listesi (yeniden yükleme yeni
  /// bir liste ÖRNEĞİ üretir, kimlik karşılaştırması yeter), seçili durak ve
  /// etiketlerin açık olup olmadığı. Üçü de kare başına değil, olay başına
  /// değişir.
  List<Marker> _markerCache = const [];
  (List<MapStop>, String?, bool)? _markerCacheKey;

  List<Marker> _buildMarkers(List<MapStop> visible) {
    final key = (visible, _selected?.stop.id, _zoom >= _labelZoom);
    if (_markerCacheKey == key) return _markerCache;
    _markerCache = [
      for (final m in _markerStops(visible))
        if (_stopMarker(m) case final mk?) mk,
    ];
    _markerCacheKey = key;
    return _markerCache;
  }

  @override
  Widget build(BuildContext context) {
    // Akışı İZLE: her yeni konumda mavi nokta yeniden çizilsin.
    ref.watch(liveLocationProvider);
    final text = Theme.of(context).textTheme;
    // Panel + markerlar GÖRÜNEN alandan gelir (viewport/chunk yükleme).
    final stops = _visible;
    // Yakın duraklar yalnızca "en yakına git" kısayolu için okunur.
    final nearest = ref.watch(nearbyMapProvider).valueOrNull ?? const <MapStop>[];
    final user = _userLoc;
    // Konum HENÜZ gelmediyse AKTİF ŞEHRİN merkezi. Sabit İstanbul koordinatı
    // gömülüydü: Kocaeli'ndeki kullanıcıya harita Beyoğlu'nda açılıyordu.
    final city = ref.watch(activeCityProvider);
    final center = user ??
        (nearest.isNotEmpty
            ? LatLng(nearest.first.stop.lat, nearest.first.stop.lon)
            : LatLng(city.centerLat, city.centerLon));

    // `initialCenter` yalnızca harita KURULURKEN okunur. Konum akışı birkaç
    // saniye sonra geldiğinde kamera şehir merkezinde kalıyordu; ilk gerçek
    // konumda bir kez kullanıcıya taşınır (kullanıcı haritayı kendisi
    // oynattıysa dokunulmaz).
    // BELİRLİ BİR DURAĞA odaklanarak açıldıysak kamerayı kullanıcının
    // konumuna taşıma: "Konuma git" ile gelen kişi o durağı görmek
    // istiyor, kendi mahallesini değil.
    if (widget.focusStop == null &&
        !_centeredOnUser &&
        user != null &&
        _mapReady &&
        !_userMovedMap) {
      _centeredOnUser = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _centerOnVisible(user, 16);
      });
    }

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          _availableHeight = constraints.maxHeight;
          final panelH = _availableHeight * _panelFraction;
          _panelHeight = panelH; // turuncu noktanın hizası buna göre
          return Stack(
            children: [
              // Harita
              Positioned.fill(
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 15,
                    minZoom: AppMapStyle.minZoomLocal,
                    maxZoom: AppMapStyle.maxZoom,
                    backgroundColor: VigilantColors.surfaceContainerLowest,
                    // Yakınlaşma jestleri yumuşatılmış (bkz. AppMapStyle).
                    interactionOptions:
                        AppMapStyle.interaction(flags: InteractiveFlag.all),
                    onMapReady: () {
                      _mapReady = true;
                      final focus = widget.focusStop;
                      if (focus != null) {
                        // Durak sayfasından gelindi: o durağa odaklan + seç.
                        final target = LatLng(focus.lat, focus.lon);
                        _centerOnVisible(target, 16);
                        final m = user == null
                            ? 0.0
                            : const Distance()
                                .as(LengthUnit.Meter, user, target);
                        _selectStop(MapStop(stop: focus, meters: m));
                      } else if (user != null && user.isUsable) {
                        _centerOnVisible(user, 15);
                      }
                      _reloadVisible(); // ilk parçayı yükle
                    },
                    // Kaydırma SIRASINDA turuncu nokta anında taşınır; ağır
                    // durak sorgusu ise hareket durunca (debounce) yapılır.
                    onPositionChanged: (cam, hasGesture) {
                      // Jest sürerken durak işaretleri çizilmesin.
                      _settle.touch();
                      if (hasGesture) _userMovedMap = true;
                      _updateProbeLive();
                      _scheduleReload();
                      // Etiket eşiği geçildiyse yeniden çiz (her karede değil).
                      final was = _zoom >= _labelZoom;
                      _zoom = cam.zoom;
                      // setState'i layout sırasında ÇAĞIRMA (yukarıdaki
                      // açıklama): kareyi bitir, sonra yeniden çiz.
                      if (mounted && was != (_zoom >= _labelZoom)) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) setState(() {});
                        });
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      keepBuffer: AppMapStyle.keepBuffer,
                      panBuffer: AppMapStyle.panBuffer,
                      urlTemplate: AppMapStyle.urlTemplate,
                      tileDimension: AppMapStyle.tileDimension,
                      zoomOffset: AppMapStyle.zoomOffset,
                      subdomains: AppMapStyle.subdomains,
                      userAgentPackageName: 'com.originstudios.stopalert',
                      retinaMode: AppMapStyle.supportsRetina &&
                          RetinaMode.isHighDensity(context),
                    ),
                    if (AppMapStyle.needsLabelOverlay)
                      TileLayer(
                        keepBuffer: AppMapStyle.keepBuffer,
                        panBuffer: AppMapStyle.panBuffer,
                        urlTemplate: AppMapStyle.labelOverlayUrl,
                        subdomains: AppMapStyle.labelSubdomains,
                        userAgentPackageName: 'com.originstudios.stopalert',
                        retinaMode: AppMapStyle.supportsRetina &&
                            RetinaMode.isHighDensity(context),
                      ),
                    // TURUNCU arama dairesi (haritayı gezdirdikçe taşınır)
                    ValueListenableBuilder<LatLng?>(
                      valueListenable: _probe,
                      builder: (context, p, _) => CircleLayer(circles: [
                        if (p != null && p.isUsable)
                        CircleMarker(
                          point: p,
                          radius: _radius,
                          useRadiusInMeter: true,
                          color: VigilantColors.tertiaryContainer
                              .withValues(alpha: 0.12),
                          borderColor: VigilantColors.tertiaryContainer
                              .withValues(alpha: 0.8),
                          borderStrokeWidth: 2,
                        ),
                      ]),
                    ),
                    // Durak işaretleri (yalnızca görünen alandakiler). Seçili
                    // durak listede olmasa da (kaydırıldıysa) işaretli kalır.
                    // Liste hazır kurulmuş gelir — bkz. _buildMarkers.
                    // YOĞUN katman: harita DURUNCA çizilir (MapSettle).
                    ValueListenableBuilder<bool>(
                      valueListenable: _settle,
                      builder: (_, settled, __) => settled
                          ? MarkerLayer(markers: _buildMarkers(stops))
                          : const SizedBox.shrink(),
                    ),
                    if (user != null && user.isUsable)
                      MarkerLayer(markers: [
                        Marker(
                          point: user,
                          width: 26,
                          height: 26,
                          child: const _UserDot(),
                        ),
                      ]),
                    // Turuncu arama noktası (dairenin merkezi) — en üstte
                    ValueListenableBuilder<LatLng?>(
                      valueListenable: _probe,
                      builder: (context, p, _) => MarkerLayer(markers: [
                        if (p != null && p.isUsable)
                          Marker(
                            point: p,
                            width: 22,
                            height: 22,
                            child: const _ProbeDot(),
                          ),
                      ]),
                    ),
                  ],
                ),
              ),
              // Harita eylemleri — SAĞ KENARDA, her iki modda.
              //
              // Gömülü modda üst çubuk çizilmediği için katman düğmesi
              // kaybolmuştu; konuma dönme düğmesi ise hiç yoktu.
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _RoundBtn(
                          icon: Icons.layers_rounded, onTap: _pickMapStyle),
                      const SizedBox(height: 10),
                      _RoundBtn(
                          icon: Icons.my_location_rounded,
                          onTap: _centerOnMe),
                    ],
                  ),
                ),
              ),
              // Üst çubuk — Positioned (Stack'in tüm çocukları konumlanmalı ki
              // Stack tüm ekranı doldursun; aksi halde SafeArea'ya küçülür).
              if (!widget.embedded)
                Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        _RoundBtn(
                            icon: Icons.arrow_back,
                            onTap: () => Navigator.of(context).pop()),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: VigilantColors.surfaceContainer
                                .withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('Yakındaki Duraklar',
                              style: text.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ),
              // Alt panel
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: panelH,
                child: _panel(text, stops, nearest.isNotEmpty),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _panel(TextTheme text, List<MapStop> stops, bool hasNearest) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 28,
              offset: const Offset(0, -6)),
        ],
      ),
      child: Column(
        children: [
          // Sürükleme tutamağı
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              if (_availableHeight == 0) return;
              setState(() {
                _panelFraction =
                    (_panelFraction - d.delta.dy / _availableHeight)
                        .clamp(_minFraction, _maxFraction);
              });
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: VigilantColors.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          // Bir durak seçiliyse panel TAMAMEN durak sayfasına döner.
          //
          // Ayrı bir "mini detay" tasarımı sürdürmek yerine GERÇEK durak
          // sayfası gömülüyor: yaklaşan otobüsler, sefer saatleri, geçen
          // hatlar — kullanıcı iki farklı durak görünümü öğrenmek zorunda
          // kalmıyor.
          if (_selected case final sel?) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _clearSelection,
                    icon: const Icon(Icons.arrow_back,
                        color: VigilantColors.onSurfaceVariant),
                  ),
                  Expanded(
                    child: Text('Yakındaki duraklara dön',
                        style: text.labelMedium?.copyWith(
                            color: VigilantColors.onSurfaceVariant)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StopLinesScreen(
                key: ValueKey(sel.stop.id),
                stop: sel.stop,
                lines: _selectedLines,
                // Durak BAŞKA ŞEHİRDEYSE taşınır: yaklaşan araç ve sefer
                // saati sorguları doğru pakete gitsin.
                city: _selectedCityId == null ||
                        _selectedCityId == ref.read(activeCityProvider).id
                    ? null
                    : TransitCities.byId(_selectedCityId!),
                embedded: true,
              ),
            ),
          ] else ...[
          // Arama noktası özeti + yarıçap seçimi
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: VigilantColors.tertiaryContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Bu noktanın çevresinde ${stops.length} durak',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ),
                if (_loadingStops)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: VigilantColors.primary),
                  ),
              ],
            ),
          ),
          // Yarıçap çipleri
          //
          // KAYDIRILABİLİR: üç çip + "haritayı gezdir" ipucu 390 px'lik bir
          // ekranda yan yana sığmıyor ve satır taşıyordu (93 px). İpucu
          // çiplerin altına alındı, çipler kendi şeridinde kaydırılıyor.
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              children: [
                for (final r in _radiusOptions) ...[
                  _RadiusChip(
                    label: r >= 1000
                        ? '${(r / 1000).toStringAsFixed(0)} km'
                        : '${r.round()} m',
                    selected: _radius == r,
                    onTap: () => _setRadius(r),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
            child: Text('Listeyi değiştirmek için haritayı gezdir',
                style: text.labelSmall
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ),
          // Yarıçap çiplerinin altında yerel reklam (küçük). Yüklenmezse hiç
          // yer kaplamaz; panel listesi hemen başlar.
          const NativeAdSlot(
            key: ValueKey('nearby-native-ad'),
            margin: EdgeInsets.fromLTRB(14, 0, 14, 8),
            template: TemplateType.small,
          ),
          Expanded(
            child: _loadingStops && stops.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(
                        color: VigilantColors.primary))
                : stops.isEmpty
                    ? _empty(text, hasNearest)
                    : ListView.separated(
                        // ALT MENÜ PAYI: panel ekranın altına yapışık ve
                        // menü onun üstünde duruyor; sabit 24 px ile son
                        // durak menünün altında kalıyordu.
                        padding: EdgeInsets.fromLTRB(
                            16,
                            4,
                            16,
                            widget.embedded
                                ? AppInsets.navBarHeight +
                                    24 +
                                    MediaQuery.viewPaddingOf(context)
                                        .bottom
                                : 24),
                        itemCount: stops.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final m = stops[i];
                          return _StopTile(
                            m: m,
                            distanceText: _fmt(m.meters),
                            walkText: _walkMinutes(m.meters),
                            selected: _isSelected(m),
                            onTap: () => _selectStop(m),
                          );
                        },
                      ),
          ),
          ],
        ],
      ),
    );
  }

  /// Seçili durağın detay paneli: geri butonu, durak bilgileri, o duraktan
  /// geçen hatlar ve eylemler (alarm kur / yol tarifi).
  Widget _empty(TextTheme text, bool hasNearest) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_off_rounded,
                size: 34, color: VigilantColors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Turuncu noktanın çevresinde durak yok. Haritayı gezdir, '
              'yarıçapı büyüt ya da en yakın durağa git.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
            if (hasNearest) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: VigilantColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _goToNearest,
                icon: const Icon(Icons.near_me_rounded, size: 18),
                label: const Text('En yakın durağa git'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StopTile extends StatelessWidget {
  const _StopTile({
    required this.m,
    required this.distanceText,
    required this.walkText,
    required this.selected,
    required this.onTap,
  });

  final MapStop m;
  final String distanceText;

  /// "~4 dk" — yürüme süresi. Mesafeyi dakikaya çevirmek kullanıcının
  /// kafasında yaptığı işi ona bırakmamak demek.
  final String walkText;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sub = m.isBus
        ? (m.stop.contextLabel.isNotEmpty
            ? 'Otobüs · ${m.stop.contextLabel}'
            : 'Otobüs durağı')
        : '${m.line!.code} · ${m.line!.type.label}';
    return Material(
      color: selected
          ? VigilantColors.primary.withValues(alpha: 0.12)
          : VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (m.isBus
                          ? VigilantColors.primary
                          : lineTypeColor(m.line!.type))
                      .withValues(alpha: 0.15),
                ),
                child: Icon(
                    m.isBus
                        ? Icons.directions_bus_filled_rounded
                        : lineTypeIcon(m.line!.type),
                    size: 20,
                    color: m.isBus
                        ? VigilantColors.primary
                        : lineTypeColor(m.line!.type)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.stop.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium?.copyWith(
                            color: VigilantColors.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(distanceText,
                      style: text.labelLarge?.copyWith(
                          color: VigilantColors.primary,
                          fontWeight: FontWeight.w700)),
                  Text(walkText,
                      style: text.labelSmall?.copyWith(
                          color: VigilantColors.onSurfaceVariant)),
                  const Icon(Icons.chevron_right,
                      size: 18, color: VigilantColors.onSurfaceVariant),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StopMarker extends StatelessWidget {
  const _StopMarker({required this.selected, required this.isBus});

  final bool selected;
  final bool isBus;

  @override
  Widget build(BuildContext context) {
    final color = isBus ? VigilantColors.primary : VigilantColors.secondary;
    if (selected) {
      return Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 14),
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 6,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Icon(
            isBus
                ? Icons.directions_bus_filled_rounded
                : Icons.location_on,
            color: Colors.white,
            size: 20),
      );
    }
    // Seçili olmayan durak: beyaz halkalı renkli nokta + hafif gölge —
    // uydu/renkli döşemelerde de net okunur.
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 4,
              offset: const Offset(0, 1)),
        ],
      ),
    );
  }
}

/// Arama yarıçapı çipi (250 m / 500 m / 1 km).
class _RadiusChip extends StatelessWidget {
  const _RadiusChip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? VigilantColors.tertiaryContainer.withValues(alpha: 0.18)
              : VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? VigilantColors.tertiaryContainer
                : VigilantColors.surfaceVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Text(label,
            style: text.labelMedium?.copyWith(
              color: selected
                  ? VigilantColors.tertiaryContainer
                  : VigilantColors.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            )),
      ),
    );
  }
}

/// Turuncu arama noktası — haritanın merkezinde durur, harita gezdirildikçe
/// taşınır; çevresindeki daire içindeki duraklar listelenir.
class _ProbeDot extends StatelessWidget {
  const _ProbeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.tertiaryContainer,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
              color: VigilantColors.tertiaryContainer.withValues(alpha: 0.7),
              blurRadius: 10),
        ],
      ),
    );
  }
}

class _UserDot extends StatelessWidget {
  const _UserDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.accentBlue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
              color: VigilantColors.accentBlue.withValues(alpha: 0.7),
              blurRadius: 10),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VigilantColors.surfaceContainer.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: VigilantColors.onSurface, size: 20),
        ),
      ),
    );
  }
}
