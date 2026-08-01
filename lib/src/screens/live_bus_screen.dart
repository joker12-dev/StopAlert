import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import '../services/iett_service.dart';
import '../services/live_bus_service.dart';
import '../services/routing_service.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/map_style.dart';

/// "Otobüsüm nerede" — bir hattın canlı araç konumları harita üzerinde.
///
/// Veri [LiveBusService] üzerinden gelir: İETT filo servisi saatte 100 istekle
/// sınırlı olduğu için sonuçlar Firestore'da paylaşımlı olarak önbelleklenir.
/// Ekran açıkken 30 sn'de bir tazelenir, kapanınca durur.
class LiveBusScreen extends ConsumerStatefulWidget {
  const LiveBusScreen({super.key, required this.line});

  /// Konumları gösterilecek hat (güzergâh çizgisi + duraklar buradan).
  final TransitLine line;

  @override
  ConsumerState<LiveBusScreen> createState() => _LiveBusScreenState();
}

class _LiveBusScreenState extends ConsumerState<LiveBusScreen>
    with WidgetsBindingObserver {
  final _map = MapController();
  bool _mapReady = false;
  Timer? _timer;

  List<BusVehicle> _vehicles = const [];
  bool _loading = true;
  DateTime? _updatedAt;

  /// Güzergâhın YOLLARA oturmuş hali (OSRM). Boşsa duraklar arası düz çizgi.
  List<LatLng> _road = const [];

  /// Haritada seçilen araç — alt kartta detayı gösterilir.
  BusVehicle? _selected;

  /// Yalnızca bu hattın yönüne ait araçları göster (gidiş/dönüş karışmasın).
  bool _onlyThisDirection = true;

  String get _code => widget.line.code;

  /// Hat id'si `bus:MK13_G` biçiminde — yön harfi sonda.
  bool get _isGidisLine => widget.line.id.endsWith('_G');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _loadRoad();
    _startTimer();
  }

  /// Güzergâhı gerçek yollara oturt (OSRM). Ağ yoksa düz çizgiye düşülür —
  /// alarm/canlı takip haritasındaki davranışın aynısı.
  Future<void> _loadRoad() async {
    final pts = _routePoints;
    if (pts.length < 2) return;
    final road = await RoutingService.instance.route(pts);
    if (mounted && road.length >= 2) setState(() => _road = road);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// Yenileme aralığı servisin kota bütçesinden gelir (bkz. LiveBusService).
  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
        LiveBusService.refreshInterval, (_) => _load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Uygulama arka plandayken yenileme YAPMA: hem kota hem pil israfı olur.
    if (state == AppLifecycleState.resumed) {
      _load();
      _startTimer();
    } else {
      _timer?.cancel();
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

  List<BusVehicle> get _shown => _onlyThisDirection
      ? [for (final v in _vehicles) if (v.isGidis == _isGidisLine) v]
      : _vehicles;

  List<LatLng> get _routePoints => [
        for (final s in widget.line.stops)
          if (s.lat != 0 || s.lon != 0) LatLng(s.lat, s.lon),
      ];

  void _fit() {
    final pts = [
      ..._routePoints,
      for (final v in _shown) LatLng(v.lat, v.lon),
    ];
    if (!_mapReady || pts.isEmpty) return;
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(pts),
      padding: const EdgeInsets.fromLTRB(40, 100, 40, 160),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final shown = _shown;
    final route = _routePoints;
    // Yollara oturmuş rota varsa onu çiz; yoksa duraklar arası düz çizgi.
    final drawRoute = _road.length >= 2 ? _road : route;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: route.isNotEmpty
                    ? route.first
                    : const LatLng(41.0082, 28.9784),
                initialZoom: 13,
                minZoom: 3,
                maxZoom: 18,
                backgroundColor: VigilantColors.surfaceContainerLowest,
                onMapReady: () {
                  _mapReady = true;
                  _fit();
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: AppMapStyle.urlTemplate,
                  subdomains: AppMapStyle.subdomains,
                  userAgentPackageName: 'com.originstudios.stopalert',
                  retinaMode: AppMapStyle.supportsRetina &&
                      RetinaMode.isHighDensity(context),
                ),
                if (AppMapStyle.needsLabelOverlay)
                  TileLayer(
                    urlTemplate: AppMapStyle.labelOverlayUrl,
                    subdomains: AppMapStyle.labelSubdomains,
                    userAgentPackageName: 'com.originstudios.stopalert',
                  ),
                // Hat güzergâhı — OSRM ile yollara oturmuş hali (varsa).
                if (drawRoute.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: drawRoute,
                      strokeWidth: 4,
                      color: VigilantColors.primary.withValues(alpha: 0.75),
                      borderStrokeWidth: 1,
                      borderColor: Colors.white.withValues(alpha: 0.25),
                    ),
                  ]),
                // Duraklar
                MarkerLayer(markers: [
                  for (final s in widget.line.stops)
                    if (s.lat != 0 || s.lon != 0)
                      Marker(
                        point: LatLng(s.lat, s.lon),
                        width: 10,
                        height: 10,
                        child: Container(
                          decoration: BoxDecoration(
                            color: VigilantColors.background,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: VigilantColors.primary
                                    .withValues(alpha: 0.8),
                                width: 2),
                          ),
                        ),
                      ),
                ]),
                // CANLI otobüsler
                MarkerLayer(markers: [
                  for (final v in shown)
                    Marker(
                      point: LatLng(v.lat, v.lon),
                      width: 44,
                      height: 44,
                      child: GestureDetector(
                        onTap: () {
                          Haptics.light();
                          setState(() => _selected =
                              _selected?.plate == v.plate ? null : v);
                        },
                        child: _BusMarker(
                            vehicle: v, selected: _selected?.plate == v.plate),
                      ),
                    ),
                ]),
              ],
            ),
          ),
          // Üst çubuk
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
                            .withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.directions_bus_filled_rounded,
                              size: 16, color: VigilantColors.primary),
                          const SizedBox(width: 6),
                          Text('$_code · canlı',
                              style: text.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ],
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
          ),
          // Alt bilgi kartı
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: _InfoCard(
              count: shown.length,
              loading: _loading,
              updatedAt: _updatedAt,
              selected: _selected,
              onClearSelection: () => setState(() => _selected = null),
              onlyThisDirection: _onlyThisDirection,
              onToggleDirection: () {
                Haptics.selection();
                setState(() => _onlyThisDirection = !_onlyThisDirection);
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
    required this.updatedAt,
    required this.onlyThisDirection,
    required this.onToggleDirection,
    required this.onRefresh,
    this.selected,
    this.onClearSelection,
  });

  final int count;
  final bool loading;
  final DateTime? updatedAt;
  final bool onlyThisDirection;
  final VoidCallback onToggleDirection;
  final VoidCallback onRefresh;

  /// Haritadan seçilen araç — varsa güzergâh detayı gösterilir.
  final BusVehicle? selected;
  final VoidCallback? onClearSelection;

  /// Seçili araç detayındaki tek satır (ikon + metin).
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
          // Seçili araç: hangi güzergâhta, nereye gidiyor, ne zaman görüldü.
          if (selected case final v?) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: VigilantColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: VigilantColors.primary.withValues(alpha: 0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.directions_bus_filled_rounded,
                          size: 18, color: VigilantColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(v.plate,
                            style: text.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w800)),
                      ),
                      GestureDetector(
                        onTap: onClearSelection,
                        behavior: HitTestBehavior.opaque,
                        child: const Icon(Icons.close_rounded,
                            size: 18, color: VigilantColors.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
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
              if (loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: VigilantColors.primary),
                )
              else
                GestureDetector(
                  onTap: onRefresh,
                  behavior: HitTestBehavior.opaque,
                  child: const Icon(Icons.refresh_rounded,
                      size: 20, color: VigilantColors.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            updatedAt == null
                ? 'İETT canlı filo verisi'
                : 'Güncellendi: $_ago · '
                    '${LiveBusService.refreshInterval.inSeconds} sn\'de bir',
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onToggleDirection,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Icon(
                    onlyThisDirection
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 18,
                    color: onlyThisDirection
                        ? VigilantColors.primary
                        : VigilantColors.onSurfaceVariant),
                const SizedBox(width: 8),
                Text('Yalnızca bu yön',
                    style: text.labelLarge?.copyWith(
                        color: onlyThisDirection
                            ? VigilantColors.onSurface
                            : VigilantColors.onSurfaceVariant)),
              ],
            ),
          ),
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
