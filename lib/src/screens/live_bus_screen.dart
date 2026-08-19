import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import '../data/timetable.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../engine/scheduled_vehicles.dart';
import '../services/iett_service.dart';
import '../services/live_bus_service.dart';
import '../services/routing_service.dart';
import '../services/timetable_service.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../state/live_location_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/offline_banner.dart';
import '../util/haptics.dart';
import '../util/latlng_guard.dart';
import '../util/map_settle.dart';
import '../util/map_style.dart';
import 'alarm_setup_screen.dart';
import 'stop_lines_screen.dart';

/// "Otobüsüm nerede" — bir hattın canlı araç konumları harita üzerinde.
///
/// Yenileme YALNIZCA kullanıcı isteğiyle olur (otomatik zamanlayıcı yok):
/// İETT konumu ~60 saniyede bir toplu yayınlıyor, arka planda sürekli
/// yoklamak ne veriyi tazeler ne pili korur. Kullanıcı ne zaman baktığını
/// kendi bilir.
class LiveBusScreen extends ConsumerStatefulWidget {
  const LiveBusScreen({
    super.key,
    required this.line,
    this.city,
    this.focusPlate,
    this.highlightStopId,
  });

  /// Haritada AYRICA vurgulanacak durak.
  ///
  /// Durak sayfasından "canlı konum" ile gelindiğinde kullanıcının derdi
  /// aracın nerede olduğu değil, KENDİ DURAĞINA ne kadar kaldığı. İkisini
  /// birlikte görmeden bu soru cevaplanmıyordu.
  final String? highlightStopId;

  /// Verilirse haritada YALNIZCA bu kapı numaralı araç gösterilir.
  ///
  /// Durak sayfasındaki "yaklaşan otobüsler" listesinden gelindiğinde
  /// kullanıcı belirli bir otobüsü merak ediyor; hattın tüm araçlarını
  /// göstermek onu kalabalıkta kaybettirirdi.
  final String? focusPlate;

  /// Konumları gösterilecek hat (güzergâh çizgisi + duraklar buradan).
  final TransitLine line;

  /// Hat BAŞKA şehrin paketindeyse o şehir. Null = aktif şehir.
  /// Yön varyantları bu şehrin veritabanından okunur; taşınmazsa sorgu
  /// yanlış pakete gidip "bu hattın tek yönü var" hatası veriyordu.
  final TransitCity? city;

  @override
  ConsumerState<LiveBusScreen> createState() => _LiveBusScreenState();
}

class _LiveBusScreenState extends ConsumerState<LiveBusScreen> {
  final _map = MapController();

  /// Hattın kendi şehri (yoksa aktif şehir) — duraksız/koordinatsız durumda
  /// haritanın açılacağı yer. Sabit İstanbul koordinatı gömülüydü.
  TransitCity get _fallbackCity => widget.city ?? ref.read(activeCityProvider);
  bool _mapReady = false;

  /// Harita hareket ederken yoğun katmanlar çizilmez (bkz. [MapSettle]).
  final _settle = MapSettle();

  /// Gösterilen yön varyantı — "yön değiştir" ile gidiş/dönüş arasında geçilir.
  late TransitLine _line;

  List<BusVehicle> _vehicles = const [];
  bool _loading = true;
  bool _switchingDirection = false;
  DateTime? _updatedAt;

  /// Güzergâhın YOLLARA oturmuş hali (OSRM). Boşsa duraklar arası düz çizgi.
  List<LatLng> _road = const [];

  /// Haritada seçilen araç — alt kartta detayı gösterilir.
  BusVehicle? _selected;

  /// Haritada seçilen durak — alt kartta "Alarm kur" çıkar.
  Stop? _selectedStop;

  /// Durak adlarını yazmak için yakınlaşma eşiği. Daha uzakta 50+ etiket
  /// üst üste biner, harita okunmaz olur.
  static const _labelZoom = 14.5;
  double _zoom = 13;

  /// Yön oklarının aralığı (metre) — yakınlaştıkça sıklaşır.
  double get _arrowSpacing => _zoom >= 15.5
      ? 300
      : _zoom >= 14
          ? 600
          : 1200;

  // Oklar güzergâh + aralık değişmedikçe yeniden hesaplanmaz: OSRM çizgisi
  // binlerce noktadan oluşabiliyor, her karede taramak israf olurdu.
  List<Marker> _arrows = const [];
  double? _arrowsFor;
  int _arrowsRouteLen = -1;

  String get _code => _line.code;

  @override
  void initState() {
    super.initState();
    _line = widget.line;
    // Durak sayfasından gelindiyse o durak SEÇİLİ açılır: haritada işaretli
    // durur, adı yazar ve alt kartta "alarm kur" kısayolu çıkar.
    final hid = widget.highlightStopId;
    if (hid != null) {
      for (final st in _line.stops) {
        if (st.id == hid) {
          _selectedStop = st;
          break;
        }
      }
    }
    _rebuildGeometry();
    _load();
    _loadRoad();
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// Güzergâhı gerçek yollara oturt (OSRM). Ağ yoksa düz çizgiye düşülür.
  ///
  /// YALNIZCA lastikli hatlarda: metro/Marmaray/tramvay kendi rayında, vapur
  /// denizde gider. OSRM onları karayoluna oturtunca Marmaray sahil yolundan,
  /// vapur da karadan geçiyor gibi çiziliyordu.
  Future<void> _loadRoad() async {
    if (_scheduledOnly) return;
    final pts = _routePoints;
    if (pts.length < 2) return;
    final road = await RoutingService.instance.route(pts);
    if (mounted && road.length >= 2) {
      setState(() {
        _road = road;
        _rebuildGeometry();
      });
    }
  }

  /// Bu hattın konumu CANLI mı, tarifeden mi üretiliyor.
  ///
  /// Canlı filo yayını yalnızca lastikli hatlar için var; metro, Marmaray,
  /// tramvay ve vapurun anlık konumu hiçbir açık kaynakta yok.
  bool get _scheduledOnly =>
      _line.type != LineType.bus && _line.type != LineType.metrobus;

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final list = _scheduledOnly
        ? await _fromTimetable()
        : await LiveBusService.instance.vehicles(
            _code,
            city: _fallbackCity,
            lineId: _line.id,
          );
    if (!mounted) return;
    setState(() {
      _vehicles = list;
      _loading = false;
      _updatedAt = DateTime.now();
    });
  }

  /// Tarifeden ŞU AN yolda olması gereken seferleri konumlandır.
  Future<List<BusVehicle>> _fromTimetable() async {
    try {
      final city = widget.city ?? ref.read(activeCityProvider);
      final table = await TimetableService.instance
          .forLine(_code, city: city, type: _line.type);
      if (table.isEmpty) return const [];
      final rows = table.forDay(DayType.forDate(DateTime.now()),
          outbound: _line.id.contains('_G'));
      if (rows.isEmpty) return const [];
      return ScheduledVehicles.forLine(line: _line, departures: rows);
    } catch (_) {
      return const [];
    }
  }

  /// Gidiş ↔ dönüş. Öteki varyantın DURAKLARI ve güzergâhı da değişir, yalnızca
  /// süzgeç değil — dönüş yolu çoğu hatta farklı sokaklardan geçer.
  Future<void> _switchDirection() async {
    if (_switchingDirection) return;
    Haptics.selection();
    setState(() => _switchingDirection = true);
    final variants = await TransitDb.instance
        .directionsForCode(_code, cityId: widget.city?.id);
    // Depar (garaj) seferleri hariç: kullanıcı normal gidiş/dönüş bekliyor.
    LineVariant? other;
    for (final v in variants) {
      if (v.depar || v.id == _line.id) continue; // depar = garaj seferi
      other = v;
      break;
    }
    if (other == null) {
      if (mounted) {
        setState(() => _switchingDirection = false);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bu hattın tek yönü var')));
      }
      return;
    }
    final line =
        await TransitDb.instance.buildLine(other.id, cityId: widget.city?.id);
    if (!mounted) return;
    setState(() {
      _switchingDirection = false;
      if (line == null) return;
      _line = line;
      _road = const [];
      _selected = null;
      _selectedStop = null;
      _rebuildGeometry();
    });
    if (line != null) {
      _fit();
      await Future.wait([_load(), _loadRoad()]);
    }
  }

  /// Bu hattın (seçili yön varyantının) bu durağına alarm kur.
  ///
  /// Kullanıcı canlı otobüs ekranından geldiği için hat ZATEN belli: alarm
  /// ekranında yeniden hat seçtirmek gereksiz bir adım olurdu.
  void _setAlarm(Stop stop) {
    Haptics.light();
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(_line)
      ..selectTargetStop(stop.id);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AlarmSetupScreen(stopName: stop.name, lineLabel: _code),
    ));
  }

  /// Durak künyesi: bu duraktan geçen hatlar + yaklaşan araçlar.
  Future<void> _openStopInfo(Stop stop) async {
    Haptics.light();
    List<TransitLineBrief> lines = const [];
    try {
      if (isBusId(stop.id)) {
        lines = await TransitDb.instance
            .linesForStop(stop.id, cityId: widget.city?.id);
      }
    } catch (_) {
      // Hat listesi çözülemedi: künye yine açılır.
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          StopLinesScreen(stop: stop, lines: lines, city: widget.city),
    ));
  }

  /// Yalnızca GÖSTERİLEN yöndeki araçlar.
  ///
  /// İETT hattın bütün araçlarını tek listede veriyor; yönü `guzergahkodu`
  /// içindeki `_G_`/`_D_` ayırıyor. Süzgeç olmadan gidişteki 3 ve dönüşteki 2
  /// otobüs her iki yönde de görünüyordu.
  ///
  /// Yön anlaşılamayan araç (depar/garaj seferi, boş güzergâh kodu) GİZLENMEZ:
  /// otobüsün orada olduğu gerçek, yönünü bilmemek onu yok saymayı gerektirmez.
  List<BusVehicle> get _shown {
    final focus = widget.focusPlate?.trim();
    if (focus != null && focus.isNotEmpty) {
      // Tek araç odağı: yön süzgeci uygulanmaz — kullanıcı zaten
      // belirli bir otobüsü seçti.
      return [
        for (final v in _vehicles)
          if (v.plate.trim() == focus) v,
      ];
    }
    return [
      for (final v in _vehicles)
        if (v.routeCode.isEmpty ||
            (!v.routeCode.contains('_G_') && !v.routeCode.contains('_D_')) ||
            v.isGidis == _isGidisLine)
          v,
    ];
  }

  /// Aracın GİDİŞ YÖNÜ (radyan, kuzeyden saat yönünde) — güzergâhtan hesaplanır.
  ///
  /// İETT/e-komobil araç pusulası vermiyor; ama araç hattın SIRALI durakları
  /// boyunca ilerlediği için, konumuna en yakın güzergâh parçasının yönü
  /// gidiş yönüdür. `null` = güzergâh yok/kısa (ok çizilmez).
  double? _headingFor(BusVehicle v) {
    final route = _drawRoute.length >= 2 ? _drawRoute : _routePoints;
    if (route.length < 2) return null;
    final p = safeLatLng(v.lat, v.lon);
    if (p == null) return null;
    // En yakın güzergâh köşesini bul.
    var bestI = 0;
    var bestD = double.infinity;
    for (var i = 0; i < route.length; i++) {
      final dLat = route[i].latitude - p.latitude;
      final dLon = route[i].longitude - p.longitude;
      final d = dLat * dLat + dLon * dLon;
      if (d < bestD) {
        bestD = d;
        bestI = i;
      }
    }
    // Yön: o köşeden BİR SONRAKİNE (son köşedeyse öncekinden ona).
    final a = bestI + 1 < route.length ? route[bestI] : route[bestI - 1];
    final b = bestI + 1 < route.length ? route[bestI + 1] : route[bestI];
    if (a == b) return null;
    final deg = const Distance().bearing(a, b);
    return deg * math.pi / 180.0;
  }

  /// Gösterilen varyant gidiş mi — hat id'si `bus:147_G` biçiminde.
  bool get _isGidisLine => _line.id.endsWith('_G');

  // Temizlenmiş veri ÖNBELLEKTE — getter'da hesaplanmaz. build jest boyunca
  // her karede çalışıyor ve bu listeler binlerce nokta içerebiliyor; her
  // erişimde yeniden üretmek ana iş parçacığını malloc/free'de kilitliyordu.
  List<Stop> _stopsCache = const [];
  List<LatLng> _routePointsCache = const [];
  List<LatLng> _drawRouteCache = const [];

  List<Stop> get _stops => _stopsCache;
  List<LatLng> get _routePoints => _routePointsCache;

  /// Çizilen güzergâh: OSRM varsa yollara oturmuş hali, yoksa düz çizgi.
  List<LatLng> get _drawRoute => _drawRouteCache;

  /// Hat ya da yol geometrisi değiştiğinde çağrılır.
  void _rebuildGeometry() {
    _stopsCache = [
      for (final s in _line.stops)
        if ((s.lat != 0 || s.lon != 0) && safeLatLng(s.lat, s.lon) != null) s,
    ];
    _routePointsCache = [for (final s in _stopsCache) LatLng(s.lat, s.lon)];
    _drawRouteCache = onlyUsable(_road.length >= 2 ? _road : _routePointsCache);
    _arrowsRouteLen = -1;
    _markersKey = null;
    _terminalsBuilt = false;
  }

  /// Durak işaretleri ÖNBELLEKTE.
  ///
  /// `MarkerLayer.build`, kamera her değiştiğinde (jest boyunca HER KAREDE)
  /// çalışır. İşaret listesi orada üretilirse 200 durağın widget ağacı da her
  /// karede yeniden kurulur — profilde ölçülen %93'lük CPU payının kaynağı bu.
  ///
  /// Kırpmayı flutter_map kendisi yapıyor (`getPositioned`, görünen alan
  /// dışındaki işaret için `Positioned` bile kurmadan null döner).
  List<Marker> _stopMarkers = const [];
  (bool, String?)? _markersKey;
  List<Marker> _terminals = const [];
  String? _terminalsFor;
  bool _terminalsBuilt = false;

  List<Marker> _buildStopMarkers({required bool showLabels}) {
    final key = (showLabels, _selectedStop?.id);
    if (_markersKey == key) return _stopMarkers;
    final stops = _stopsCache;
    _stopMarkers = [
      for (var i = 1; i < stops.length - 1; i++)
        _stopMarker(stops[i], showLabels: showLabels),
    ];
    _markersKey = key;
    return _stopMarkers;
  }

  List<Marker> _terminalMarkers() {
    if (_terminalsBuilt && _terminalsFor == _selectedStop?.id) {
      return _terminals;
    }
    final stops = _stopsCache;
    _terminals = [
      if (stops.isNotEmpty) _terminalMarker(stops.first, isStart: true),
      if (stops.length > 1) _terminalMarker(stops.last, isStart: false),
    ];
    _terminalsFor = _selectedStop?.id;
    _terminalsBuilt = true;
    return _terminals;
  }

  void _fit() {
    // TEK ARACA ODAKLANILDIYSA kamera ARACA gider — ama YAKINLAŞMADAN.
    //
    // Araç ile durağı birlikte çerçevelemek kamerayı durağa kadar geriyordu;
    // kullanıcı ise dokunduğu otobüsü görmek istiyor. Durak işaretli kalır,
    // görüş alanına girerse görünür; kamera onun için esnetilmez.
    final focus = widget.focusPlate?.trim();
    if (focus != null && focus.isNotEmpty) {
      final pts = onlyUsable([for (final v in _shown) LatLng(v.lat, v.lon)]);
      if (_mapReady && pts.isNotEmpty) {
        // Geniş açı (13.5): araç noktası ortada, çevresi ve güzergâh görünür.
        _map.move(pts.first, 13.5);
        return;
      }
    }
    final pts = onlyUsable([
      ..._routePoints,
      for (final v in _shown) LatLng(v.lat, v.lon),
    ]);
    if (!_mapReady || pts.isEmpty) return;
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(pts),
      padding: const EdgeInsets.fromLTRB(40, 100, 40, 200),
    ));
  }

  /// Güzergâh çizgisi üzerine, aralıklarla gidiş yönü okları.
  ///
  /// Hangi uçtan hangi uca gidildiği çizgiye bakınca anlaşılmıyordu; oklar
  /// bunu tek bakışta veriyor. Uzak zoom'da seyrekleşir ki çizgiyi boğmasın.
  List<Marker> _directionArrows() {
    final pts = _drawRoute;
    if (pts.length < 2) return const [];
    final spacing = _arrowSpacing;
    if (_arrowsFor == spacing && _arrowsRouteLen == pts.length) return _arrows;
    const geo = Distance();
    final out = <Marker>[];
    var acc = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final len = geo.as(LengthUnit.Meter, a, b);
      if (len <= 0) continue;
      acc += len;
      if (acc < spacing) continue;
      acc = 0;
      final mid = safeLatLng(
          (a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2);
      if (mid == null) continue;
      final dLon =
          (b.longitude - a.longitude) * math.cos(a.latitude * math.pi / 180);
      final bearing = math.atan2(dLon, b.latitude - a.latitude);
      out.add(Marker(
        point: mid,
        width: 18,
        height: 18,
        child: IgnorePointer(
          child: Transform.rotate(
            angle: bearing,
            child: const Icon(Icons.navigation_rounded,
                size: 14, color: Colors.white),
          ),
        ),
      ));
    }
    _arrows = out;
    _arrowsFor = spacing;
    _arrowsRouteLen = pts.length;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final stops = _stops;
    final drawRoute = _drawRoute;
    final showLabels = _zoom >= _labelZoom;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: stops.isNotEmpty
                    ? LatLng(stops.first.lat, stops.first.lon)
                    : LatLng(_fallbackCity.centerLat, _fallbackCity.centerLon),
                initialZoom: _zoom,
                minZoom: AppMapStyle.minZoom,
                maxZoom: AppMapStyle.maxZoom,
                backgroundColor: VigilantColors.surfaceContainerLowest,
                // Yakınlaşma jestleri yumuşatılmış (bkz. AppMapStyle).
                interactionOptions:
                    AppMapStyle.interaction(flags: InteractiveFlag.all),
                onMapReady: () {
                  _mapReady = true;
                  _fit();
                },
                onPositionChanged: (cam, _) {
                  // Jest sürerken durak işaretleri ve oklar çizilmesin.
                  _settle.touch();
                  // Etiket ve ok yoğunluğu yakınlaşmaya bağlı. Yalnızca bir
                  // EŞİK geçilince yeniden çizilir — kaydırmanın her karesinde
                  // değil.
                  final before = (_zoom >= _labelZoom, _arrowSpacing);
                  _zoom = cam.zoom;
                  // setState LAYOUT SIRASINDA çağrılmamalı: flutter_map bu
                  // geri çağrıyı kendi layout aşamasında tetikliyor.
                  if (mounted &&
                      before != (_zoom >= _labelZoom, _arrowSpacing)) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() {});
                    });
                  }
                },
                onTap: (_, __) {
                  if (_selected != null || _selectedStop != null) {
                    setState(() {
                      _selected = null;
                      _selectedStop = null;
                    });
                  }
                },
              ),
              children: [
                TileLayer(
                  keepBuffer: AppMapStyle.keepBuffer,
                  panBuffer: AppMapStyle.panBuffer,
                  urlTemplate: AppMapStyle.urlTemplate,
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
                  ),
                // Hat güzergâhı — OSRM ile yollara oturmuş hali (varsa).
                if (drawRoute.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: drawRoute,
                      strokeWidth: 5,
                      color: VigilantColors.primary.withValues(alpha: 0.8),
                      borderStrokeWidth: 1,
                      borderColor: Colors.white.withValues(alpha: 0.25),
                    ),
                  ]),
                // Yön okları + ara duraklar: YOĞUN katmanlar, harita DURUNCA
                // çizilir (bkz. MapSettle).
                ValueListenableBuilder<bool>(
                  valueListenable: _settle,
                  builder: (_, settled, __) => settled
                      ? MarkerLayer(markers: [
                          ..._directionArrows(),
                          ..._buildStopMarkers(showLabels: showLabels),
                        ])
                      : const SizedBox.shrink(),
                ),
                // Başlangıç ve bitiş — hareket sırasında da görünür kalır.
                MarkerLayer(markers: _terminalMarkers()),
                // CANLI otobüsler
                MarkerLayer(markers: [
                  for (final v in shown)
                    if (safeLatLng(v.lat, v.lon) case final vp?)
                      Marker(
                        point: vp,
                        width: 54,
                        height: 54,
                        child: GestureDetector(
                          onTap: () {
                            Haptics.light();
                            setState(() {
                              _selectedStop = null;
                              _selected =
                                  _selected?.plate == v.plate ? null : v;
                            });
                          },
                          child: _BusMarker(
                            vehicle: v,
                            selected: _selected?.plate == v.plate,
                            type: _line.type,
                            heading: _headingFor(v),
                          ),
                        ),
                      ),
                ]),
                // Kullanıcının CANLI konumu — en üstte çizilir.
                MarkerLayer(markers: [
                  if (ref.watch(liveLocationProvider).valueOrNull case final me?
                      when me.isUsable)
                    Marker(
                      point: me,
                      width: 24,
                      height: 24,
                      child: const _UserDot(),
                    ),
                ]),
              ],
            ),
          ),
          _topBar(context),
          // ÇEVRİMDIŞI ŞERİDİ — yalnızca CANLI (ağ gerektiren) konumda.
          // Tarifeden üretilen ray konumu internetsiz de çalışır; orada
          // göstermek yanlış olurdu.
          if (!_scheduledOnly)
            Positioned(
              left: 12,
              right: 12,
              top: MediaQuery.viewPaddingOf(context).top + 64,
              child: const OfflineBanner(
                message: 'Bağlantı yok — canlı konum güncellenemiyor.',
                margin: EdgeInsets.zero,
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            // Sistem gezinme çubuğunun payı (sabit 20 px yetmiyordu).
            bottom: 20 + MediaQuery.viewPaddingOf(context).bottom,
            child: _InfoCard(
              count: shown.length,
              loading: _loading,
              switchingDirection: _switchingDirection,
              updatedAt: _updatedAt,
              scheduled: _scheduledOnly,
              selected: _selected,
              selectedStop: _selectedStop,
              directionLabel: _line.stops.isEmpty ? '' : _line.stops.last.name,
              onClearSelection: () => setState(() {
                _selected = null;
                _selectedStop = null;
              }),
              onSwitchDirection: _switchDirection,
              onSetAlarm: () {
                final s = _selectedStop;
                if (s != null) _setAlarm(s);
              },
              onStopInfo: () {
                final s = _selectedStop;
                if (s != null) _openStopInfo(s);
              },
              onRefresh: () {
                Haptics.light();
                _load();
              },
            ),
          ),
        ],
      ),
    );
  }

  /// İşaretin NOKTASI (üstteki yuvarlak) tam durak koordinatına otursun diye
  /// hizalama. Varsayılan `Alignment.center` kutunun ortasını, `topCenter` ise
  /// üst kenarını koordinata koyar; ikisinde de etiket kutuyu uzattığı için
  /// yuvarlak yoldan aşağı kayıyordu. Doğrusu: yuvarlağın MERKEZİNİ koordinata
  /// getiren oran.
  static Alignment _dotAlignment(double dotBox, double totalHeight) =>
      Alignment(0, dotBox / totalHeight - 1);

  /// Ara durak: küçük nokta + (yakınsa) adı. Dokununca alarm kartı açılır.
  Marker _stopMarker(Stop s, {required bool showLabels}) {
    final selected = _selectedStop?.id == s.id;
    const dotBox = 24.0;
    final height = showLabels ? 58.0 : dotBox;
    return Marker(
      point: LatLng(s.lat, s.lon),
      width: showLabels ? 132 : dotBox,
      height: height,
      alignment: showLabels ? _dotAlignment(dotBox, height) : Alignment.center,
      child: GestureDetector(
        onTap: () {
          Haptics.light();
          setState(() {
            _selected = null;
            _selectedStop = selected ? null : s;
          });
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: dotBox,
              height: dotBox,
              child: Center(child: _StopDot(selected: selected)),
            ),
            if (showLabels)
              Flexible(
                child: _MapLabel(text: s.name, highlight: selected),
              ),
          ],
        ),
      ),
    );
  }

  /// Hattın ilk/son durağı — başlangıç ve bitiş işareti.
  Marker _terminalMarker(Stop s, {required bool isStart}) {
    final selected = _selectedStop?.id == s.id;
    const dotBox = 30.0;
    const height = 66.0;
    return Marker(
      point: LatLng(s.lat, s.lon),
      width: 140,
      height: height,
      alignment: _dotAlignment(dotBox, height),
      child: GestureDetector(
        onTap: () {
          Haptics.light();
          setState(() {
            _selected = null;
            _selectedStop = selected ? null : s;
          });
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: dotBox,
              height: dotBox,
              child: Center(
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: isStart
                        ? VigilantColors.secondary
                        : VigilantColors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 6,
                          offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Icon(
                      isStart ? Icons.trip_origin_rounded : Icons.flag_rounded,
                      size: 14,
                      color: Colors.white),
                ),
              ),
            ),
            Flexible(
              child: _MapLabel(text: s.name, highlight: selected, strong: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Positioned(
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
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color:
                        VigilantColors.surfaceContainer.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.directions_bus_filled_rounded,
                          size: 16, color: VigilantColors.primary),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text('$_code · canlı',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelLarge
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              _RoundBtn(
                icon: Icons.center_focus_strong_rounded,
                onTap: () {
                  Haptics.light();
                  _fit();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Harita üzerindeki durak adı etiketi (koyu zemin, okunur kalsın).
class _MapLabel extends StatelessWidget {
  const _MapLabel({
    required this.text,
    this.highlight = false,
    this.strong = false,
  });

  final String text;
  final bool highlight;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlight
            ? VigilantColors.primary
            : Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontSize: strong ? 10.5 : 9.5,
          height: 1.15,
          fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
    );
  }
}

class _StopDot extends StatelessWidget {
  const _StopDot({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: selected ? 18 : 12,
      height: selected ? 18 : 12,
      decoration: BoxDecoration(
        color: selected ? VigilantColors.primary : VigilantColors.background,
        shape: BoxShape.circle,
        border: Border.all(
            color: selected
                ? Colors.white
                : VigilantColors.primary.withValues(alpha: 0.85),
            width: 2.5),
      ),
    );
  }
}

class _BusMarker extends StatelessWidget {
  const _BusMarker({
    required this.vehicle,
    this.selected = false,
    this.type = LineType.bus,
    this.heading,
  });

  final BusVehicle vehicle;
  final bool selected;

  /// Hattın türü — işaretin simgesini belirler. Metro konumuna otobüs
  /// simgesi koymak, konumun nereden geldiği konusunda da yanıltıcıydı.
  final LineType type;

  /// Gidiş yönü (radyan, kuzeyden saat yönünde). null ise ok çizilmez.
  final double? heading;

  @override
  Widget build(BuildContext context) {
    final fill = selected
        ? Colors.white
        : VigilantColors.primary
            .withValues(alpha: vehicle.scheduled ? 0.72 : 1);
    final circle = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: selected ? 34 : 30,
      height: selected ? 34 : 30,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(
            color: selected ? VigilantColors.primary : Colors.white,
            width: selected ? 3 : 2.5),
        boxShadow: [
          BoxShadow(
              color: VigilantColors.primary
                  .withValues(alpha: selected ? 0.75 : 0.55),
              blurRadius: selected ? 18 : 12),
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 5,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Icon(lineTypeIcon(type),
          color: selected ? VigilantColors.primary : Colors.white,
          size: selected ? 20 : 18),
    );
    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // YÖN OKU: dairenin dışına çıkan, gidiş yönüne bakan üçgen. Merkez
          // etrafında döndürülür; ok tabanı dairenin kenarına oturur.
          if (heading case final h?)
            Transform.rotate(
              angle: h,
              child: CustomPaint(
                size: const Size(54, 54),
                painter: _HeadingArrow(color: fill),
              ),
            ),
          circle,
        ],
      ),
    );
  }
}

/// Otobüs göstergesinin gidiş yönünü işaret eden üçgen ok.
///
/// 54x54 tuvalin üst-ortasına, ucu YUKARI (kuzey) bakan bir üçgen çizer;
/// [_BusMarker] bunu gidiş açısıyla döndürür.
class _HeadingArrow extends CustomPainter {
  const _HeadingArrow({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    // Üçgen: uç yukarıda (y=2), taban daire kenarında (~y=18). Daire yarıçapı
    // 15 olduğundan taban dairenin hemen dışında başlar.
    final path = ui.Path()
      ..moveTo(cx, 1)
      ..lineTo(cx - 7, 17)
      ..lineTo(cx + 7, 17)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    // Beyaz ince kenar: haritanın koyu/açık her yerinde okunsun.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_HeadingArrow old) => old.color != color;
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.count,
    required this.loading,
    required this.switchingDirection,
    required this.updatedAt,
    required this.scheduled,
    required this.directionLabel,
    required this.onSwitchDirection,
    required this.onRefresh,
    required this.onSetAlarm,
    required this.onStopInfo,
    this.selected,
    this.selectedStop,
    this.onClearSelection,
  });

  final int count;
  final bool loading;
  final bool switchingDirection;
  final DateTime? updatedAt;

  /// Konumlar tarifeden üretildiyse ARAYÜZ BUNU SÖYLER
  /// (bkz. `ScheduledVehicles`).
  final bool scheduled;

  /// Hattın gittiği son durak — "→ Kadıköy" biçiminde yön göstergesi.
  final String directionLabel;
  final VoidCallback onSwitchDirection;
  final VoidCallback onRefresh;
  final VoidCallback onSetAlarm;

  /// Seçili durağın künyesini aç (duraktan geçen hatlar + yaklaşanlar).
  final VoidCallback onStopInfo;

  /// Haritadan seçilen araç — varsa güzergâh detayı gösterilir.
  final BusVehicle? selected;

  /// Haritadan seçilen durak — varsa "Alarm kur" düğmesi gösterilir.
  final Stop? selectedStop;
  final VoidCallback? onClearSelection;

  Widget _row(TextTheme text, IconData icon, String label) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Icon(icon, size: 14, color: VigilantColors.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant)),
            ),
          ],
        ),
      );

  String get _ago {
    final t = updatedAt;
    if (t == null) return '';
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 5) return 'az önce';
    if (s < 60) return '$s sn önce';
    return '${(s / 60).floor()} dk önce';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: VigilantColors.surfaceVariant.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 20),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Seçili DURAK: buraya alarm kurma kısayolu.
          if (selectedStop case final s?) ...[
            _SelectionBox(
              icon: Icons.location_on_rounded,
              title: s.name,
              onClose: onClearSelection,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.contextLabel.isNotEmpty)
                    _row(text, Icons.place_outlined, s.contextLabel),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: onSetAlarm,
                          icon: const Icon(Icons.alarm_add_rounded, size: 18),
                          label: const Text('Alarm kur'),
                          style: FilledButton.styleFrom(
                            backgroundColor: VigilantColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // DURAK BİLGİSİ: bu duraktan geçen hatlar + yaklaşan
                      // araçlar. Kullanıcı canlı haritada bir durağa dokununca
                      // yalnızca alarm değil, durağın künyesine de ulaşabilmeli.
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onStopInfo,
                          icon: const Icon(Icons.info_outline_rounded, size: 18),
                          label: const Text('Durak bilgisi'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: VigilantColors.onSurface,
                            side: BorderSide(
                                color: VigilantColors.surfaceVariant
                                    .withValues(alpha: 0.7)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          // Seçili ARAÇ: hangi güzergâhta, nereye gidiyor, ne zaman görüldü.
          if (selected case final v?) ...[
            _SelectionBox(
              icon: Icons.directions_bus_filled_rounded,
              title: v.plate,
              onClose: onClearSelection,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row(text, Icons.trending_flat_rounded,
                      '${v.headingTo} yönünde'),
                  if (v.routeCode.isNotEmpty)
                    _row(text, Icons.alt_route_rounded,
                        'Güzergâh: ${v.routeCode}'),
                  if (v.lastSeen.isNotEmpty)
                    _row(text, Icons.schedule_rounded,
                        'Son konum: ${v.lastSeen}'),
                ],
              ),
            ),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  count > 0
                      ? (scheduled
                          ? 'Yolda $count sefer'
                          : 'Hatta $count otobüs')
                      : (loading ? 'Yükleniyor…' : 'Şu an sefer görünmüyor'),
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (directionLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('→ $directionLabel yönü',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              scheduled
                  // AÇIKÇA SÖYLE: kullanıcı canlı konum sanıp kapıda
                  // beklememeli — bu, tarifenin okunmuş hâli.
                  ? 'Tarifeye göre tahmini konum'
                  : updatedAt == null
                      ? 'İETT canlı filo verisi'
                      : 'Güncellendi: $_ago',
              style: text.labelSmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 12),
          // Kullanıcı eylemleri: yenileme OTOMATİK DEĞİL, bilerek elle.
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.refresh_rounded,
                  label: 'Yenile',
                  busy: loading,
                  filled: true,
                  onTap: onRefresh,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  icon: Icons.swap_horiz_rounded,
                  label: 'Yön değiştir',
                  busy: switchingDirection,
                  filled: false,
                  onTap: onSwitchDirection,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Seçili araç/durak kutusu — başlık, kapatma düğmesi ve içerik.
class _SelectionBox extends StatelessWidget {
  const _SelectionBox({
    required this.icon,
    required this.title,
    required this.child,
    this.onClose,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VigilantColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: VigilantColors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: VigilantColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        text.bodyMedium?.copyWith(fontWeight: FontWeight.w800)),
              ),
              GestureDetector(
                onTap: onClose,
                behavior: HitTestBehavior.opaque,
                child: const Icon(Icons.close_rounded,
                    size: 18, color: VigilantColors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.filled,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : VigilantColors.onSurface;
    return Material(
      color:
          filled ? VigilantColors.primary : VigilantColors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              else
                Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: fg, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kullanıcının canlı konumu — mavi nokta.
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
              color: VigilantColors.accentBlue.withValues(alpha: 0.5),
              blurRadius: 12),
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
      color: VigilantColors.surfaceContainer.withValues(alpha: 0.92),
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
