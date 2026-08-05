import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../services/iett_service.dart';
import '../services/live_bus_service.dart';
import '../services/routing_service.dart';
import '../state/journey_provider.dart';
import '../state/live_location_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/latlng_guard.dart';
import '../util/map_style.dart';
import '../util/marker_cull.dart';
import 'alarm_setup_screen.dart';

/// "Otobüsüm nerede" — bir hattın canlı araç konumları harita üzerinde.
///
/// Yenileme YALNIZCA kullanıcı isteğiyle olur (otomatik zamanlayıcı yok):
/// İETT konumu ~60 saniyede bir toplu yayınlıyor, arka planda sürekli
/// yoklamak ne veriyi tazeler ne pili korur. Kullanıcı ne zaman baktığını
/// kendi bilir.
class LiveBusScreen extends ConsumerStatefulWidget {
  const LiveBusScreen({super.key, required this.line, this.city});

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
  bool _mapReady = false;

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
    _rebuildGeometry();
    _load();
    _loadRoad();
  }

  /// Güzergâhı gerçek yollara oturt (OSRM). Ağ yoksa düz çizgiye düşülür.
  Future<void> _loadRoad() async {
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

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final list = await LiveBusService.instance.vehicles(_code);
    if (!mounted) return;
    setState(() {
      _vehicles = list;
      _loading = false;
      _updatedAt = DateTime.now();
    });
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Bu hattın tek yönü var')));
      }
      return;
    }
    final line = await TransitDb.instance
        .buildLine(other.id, cityId: widget.city?.id);
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

  /// Yalnızca GÖSTERİLEN yöndeki araçlar.
  ///
  /// İETT hattın bütün araçlarını tek listede veriyor; yönü `guzergahkodu`
  /// içindeki `_G_`/`_D_` ayırıyor. Süzgeç olmadan gidişteki 3 ve dönüşteki 2
  /// otobüs her iki yönde de görünüyordu.
  ///
  /// Yön anlaşılamayan araç (depar/garaj seferi, boş güzergâh kodu) GİZLENMEZ:
  /// otobüsün orada olduğu gerçek, yönünü bilmemek onu yok saymayı gerektirmez.
  List<BusVehicle> get _shown => [
        for (final v in _vehicles)
          if (v.routeCode.isEmpty ||
              (!v.routeCode.contains('_G_') && !v.routeCode.contains('_D_')) ||
              v.isGidis == _isGidisLine)
            v,
      ];

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
    _drawRouteCache =
        onlyUsable(_road.length >= 2 ? _road : _routePointsCache);
    _arrowsRouteLen = -1;
  }

  void _fit() {
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
      final mid = safeLatLng((a.latitude + b.latitude) / 2,
          (a.longitude + b.longitude) / 2);
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
                    : const LatLng(41.0082, 28.9784),
                initialZoom: _zoom,
                minZoom: AppMapStyle.minZoom,
                maxZoom: AppMapStyle.maxZoom,
                backgroundColor: VigilantColors.surfaceContainerLowest,
                onMapReady: () {
                  _mapReady = true;
                  _fit();
                },
                onPositionChanged: (cam, _) {
                  // Etiket ve ok yoğunluğu yakınlaşmaya bağlı. Yalnızca bir
                  // EŞİK geçilince yeniden çizilir — kaydırmanın her karesinde
                  // değil.
                  final before = (_zoom >= _labelZoom, _arrowSpacing);
                  _zoom = cam.zoom;
                  if (mounted && before != (_zoom >= _labelZoom, _arrowSpacing)) {
                    setState(() {});
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
                // Gidiş yönü okları
                Builder(builder: (context) {
                  final b = MarkerCull.paddedBounds(MapCamera.of(context));
                  return MarkerLayer(markers: [
                    for (final m in _directionArrows())
                      if (MarkerCull.visible(b, m.point.latitude,
                          m.point.longitude))
                        m,
                  ]);
                }),
                // Ara duraklar — GÖRÜNEN ALANA kırpılır (bkz. MarkerCull):
                // kamera her karede değiştiği için ekran dışı durakları da
                // kurmak ana iş parçacığını kilitliyordu.
                Builder(builder: (context) {
                  final b = MarkerCull.paddedBounds(MapCamera.of(context));
                  return MarkerLayer(markers: [
                    for (var i = 0; i < stops.length; i++)
                      if (i != 0 && i != stops.length - 1)
                        if (MarkerCull.visible(b, stops[i].lat, stops[i].lon))
                          _stopMarker(stops[i], showLabels: showLabels),
                  ]);
                }),
                // Başlangıç ve bitiş
                MarkerLayer(markers: [
                  if (stops.isNotEmpty)
                    _terminalMarker(stops.first, isStart: true),
                  if (stops.length > 1)
                    _terminalMarker(stops.last, isStart: false),
                ]),
                // CANLI otobüsler
                MarkerLayer(markers: [
                  for (final v in shown)
                    if (safeLatLng(v.lat, v.lon) case final vp?)
                    Marker(
                      point: vp,
                      width: 44,
                      height: 44,
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
                            vehicle: v, selected: _selected?.plate == v.plate),
                      ),
                    ),
                ]),
                // Kullanıcının CANLI konumu — en üstte çizilir.
                MarkerLayer(markers: [
                  if (ref.watch(liveLocationProvider).valueOrNull
                      case final me? when me.isUsable)
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
      alignment:
          showLabels ? _dotAlignment(dotBox, height) : Alignment.center,
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
              child: _MapLabel(
                  text: s.name, highlight: selected, strong: true),
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
                    color: VigilantColors.surfaceContainer
                        .withValues(alpha: 0.92),
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
  const _BusMarker({required this.vehicle, this.selected = false});

  final BusVehicle vehicle;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      margin: EdgeInsets.all(selected ? 0 : 4),
      decoration: BoxDecoration(
        color: selected ? Colors.white : VigilantColors.primary,
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
      child: Icon(Icons.directions_bus_filled_rounded,
          color: selected ? VigilantColors.primary : Colors.white,
          size: selected ? 22 : 20),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.count,
    required this.loading,
    required this.switchingDirection,
    required this.updatedAt,
    required this.directionLabel,
    required this.onSwitchDirection,
    required this.onRefresh,
    required this.onSetAlarm,
    this.selected,
    this.selectedStop,
    this.onClearSelection,
  });

  final int count;
  final bool loading;
  final bool switchingDirection;
  final DateTime? updatedAt;

  /// Hattın gittiği son durak — "→ Kadıköy" biçiminde yön göstergesi.
  final String directionLabel;
  final VoidCallback onSwitchDirection;
  final VoidCallback onRefresh;
  final VoidCallback onSetAlarm;

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
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.4), blurRadius: 20),
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
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onSetAlarm,
                      icon: const Icon(Icons.alarm_add_rounded, size: 18),
                      label: const Text('Bu durağa alarm kur'),
                      style: FilledButton.styleFrom(
                        backgroundColor: VigilantColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
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
                      ? 'Hatta $count otobüs'
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
              updatedAt == null
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
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
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
      color: filled
          ? VigilantColors.primary
          : VigilantColors.surfaceContainerHigh,
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
