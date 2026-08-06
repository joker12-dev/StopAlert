import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../engine/arrival_estimator.dart';
import '../services/live_bus_service.dart';
import '../services/segment_learning_store.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../util/turkish.dart';
import 'alarm_setup_screen.dart';
import 'live_bus_screen.dart';
import 'nearby_map_screen.dart';

/// Bir otobüs durağından geçen hatları TEMİZ, tam ekran olarak sunar. Kullanıcı
/// bu durağı hedef seçmiştir; burada "hangi hatla gidiyorum" der, o hatla alarm
/// kurulur. (Modal yerine net bir ekran — akış karışmasın.)
class StopLinesScreen extends ConsumerStatefulWidget {
  const StopLinesScreen({
    super.key,
    required this.stop,
    required this.lines,
    this.city,
  });

  final Stop stop;
  final List<TransitLineBrief> lines;

  /// Durak BAŞKA şehrin paketindeyse o şehir (aktif şehir değiştirilmez).
  final TransitCity? city;

  @override
  ConsumerState<StopLinesScreen> createState() => _StopLinesScreenState();
}

class _StopLinesScreenState extends ConsumerState<StopLinesScreen> {
  Stop get stop => widget.stop;
  List<TransitLineBrief> get lines => widget.lines;
  TransitCity? get city => widget.city;

  /// Durak kodu (İETT'nin kullandığı ham numara).
  String get _stopCode =>
      stop.id.startsWith(kBusPrefix) ? stop.id.substring(kBusPrefix.length) : '';

  /// Bu durağa yaklaşan otobüsler — en yakın varıştan uzağa sıralı.
  List<_Arrival> _arrivals = const [];
  bool _loadingArrivals = false;
  DateTime? _arrivalsAt;

  /// Kaç hat için canlı konum sorgulanacağı.
  ///
  /// Bir duraktan 30 hat geçebiliyor; hepsi için ayrı çağrı yapmak hem
  /// yavaş hem de İETT'nin saatlik kotasına yüklenmek olurdu. Kullanıcı
  /// pratikte ilk birkaç hatla ilgileniyor.
  static const _maxLinesQueried = 10;

  @override
  void initState() {
    super.initState();
    _loadArrivals();
  }

  /// Şehrin canlı filo servisi varsa yaklaşan otobüsleri hesapla.
  Future<void> _loadArrivals() async {
    final TransitCity lineCity = city ?? ref.read(activeCityProvider);
    if (!lineCity.hasLiveBus) return;
    setState(() => _loadingArrivals = true);

    final learner = await SegmentLearningStore.load();
    final found = <_Arrival>[];

    for (final brief in lines.take(_maxLinesQueried)) {
      try {
        final line =
            await TransitDb.instance.buildLine(brief.id, cityId: city?.id);
        if (line == null || line.indexOfStop(stop.id) <= 0) continue;

        final all = await LiveBusService.instance.vehicles(brief.code);
        // Yalnızca BU yöndeki araçlar: karşı yöndeki otobüsün varışını
        // göstermek kullanıcıyı yanlış otobüse bindirir.
        final isGidis = line.id.endsWith('_G');
        final sameWay = [
          for (final v in all)
            if (v.routeCode.contains('_G_') || v.routeCode.contains('_D_'))
              if (v.isGidis == isGidis) v,
        ];
        if (sameWay.isEmpty) continue;

        final ests = ArrivalEstimator.forStop(
          line: line,
          targetStopId: stop.id,
          vehicles: sameWay,
          learner: learner,
        );
        for (final e in ests) {
          found.add(_Arrival(brief: brief, line: line, estimate: e));
        }
      } catch (_) {
        // Tek hattın verisi alınamadıysa ötekiler yine gösterilir.
      }
    }

    found.sort((a, b) => a.estimate.seconds.compareTo(b.estimate.seconds));
    if (!mounted) return;
    setState(() {
      _arrivals = found;
      _loadingArrivals = false;
      _arrivalsAt = DateTime.now();
    });
  }

  Future<void> _pick(
      BuildContext context, WidgetRef ref, TransitLineBrief brief) async {
    Haptics.light();
    final line =
        await TransitDb.instance.buildLine(brief.id, cityId: city?.id);
    if (!context.mounted) return;
    if (line == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('Hat verisi yüklenemedi — tekrar dene.')));
      return;
    }
    // Seçilen durağı hatta bul (aynı bus: önekli id).
    var target = stop;
    final i = line.indexOfStop(stop.id);
    if (i != -1) target = line.stops[i];
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(line)
      ..selectTargetStop(target.id);
    ref.read(recentSearchesProvider.notifier).add(RecentSearch(
          stopName: target.name,
          stopId: target.id,
          lineId: line.id,
          lineCode: line.code,
          lineTypeName: line.type.name,
        ));
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          AlarmSetupScreen(stopName: target.name, lineLabel: line.code),
    ));
  }

  /// Bu otobüsü haritada TEK BAŞINA göster.
  void _openBusOnMap(_Arrival a) {
    Haptics.light();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LiveBusScreen(
        line: a.line,
        city: city,
        focusPlate: a.estimate.vehicle.plate,
      ),
    ));
  }

  /// "Yaklaşan otobüsler" bloğu — hiç canlı veri yoksa hiç çizilmez.
  List<Widget> _arrivalsSection(TextTheme text) {
    final TransitCity lineCity = city ?? ref.read(activeCityProvider);
    if (!lineCity.hasLiveBus) return const [];
    if (!_loadingArrivals && _arrivals.isEmpty && _arrivalsAt == null) {
      return const [];
    }
    return [
      Row(
        children: [
          const Icon(Icons.directions_bus_filled_rounded,
              size: 16, color: VigilantColors.secondary),
          const SizedBox(width: 8),
          Text('YAKLAŞAN OTOBÜSLER',
              style: text.labelSmall?.copyWith(
                  color: VigilantColors.onSurfaceVariant, letterSpacing: 1.2)),
          const Spacer(),
          if (_loadingArrivals)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            InkResponse(
              onTap: () {
                Haptics.light();
                _loadArrivals();
              },
              radius: 20,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.refresh_rounded,
                    size: 18, color: VigilantColors.onSurfaceVariant),
              ),
            ),
        ],
      ),
      const SizedBox(height: 10),
      if (_arrivals.isEmpty && !_loadingArrivals)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'Şu an bu durağa yaklaşan otobüs görünmüyor.',
            style:
                text.labelMedium?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        )
      else
        for (final a in _arrivals.take(6)) ...[
          _ArrivalRow(
            arrival: a,
            // Karta dokunmak O OTOBÜSÜ haritada açar; alarm kurmak için
            // aşağıdaki hat listesi var. Yaklaşan bir otobüse bakan kişi
            // önce "nerede kalmış" diye merak ediyor.
            onTap: () => _openBusOnMap(a),
            onAlarm: () => _pick(context, ref, a.brief),
          ),
          const SizedBox(height: 8),
        ],
      // Tahminin ne olduğunu SÖYLE: 60 saniyede bir yayın yapan bir
      // beslemeden tek dakikalık kesinlik çıkmaz, aralık gösteriyoruz.
      if (_arrivals.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(
            'Süreler canlı konumdan tahmin edilir; konum ~1 dakikada bir '
            'güncellenir.',
            style: text.labelSmall
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 18),
      Row(
        children: [
          const Icon(Icons.alt_route_rounded,
              size: 16, color: VigilantColors.primary),
          const SizedBox(width: 8),
          Text('BU DURAKTAN GEÇEN HATLAR',
              style: text.labelSmall?.copyWith(
                  color: VigilantColors.onSurfaceVariant, letterSpacing: 1.2)),
        ],
      ),
      const SizedBox(height: 10),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back,
                        color: VigilantColors.onSurfaceVariant),
                  ),
                  const Spacer(),
                ],
              ),
            ),
            // Durak künyesi: ad, yön, durak kodu + "Konuma git".
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            trUpper(stop.name),
                            style: text.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                          if (stop.contextLabel.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              trUpper(stop.contextLabel),
                              style: text.labelMedium?.copyWith(
                                  color: VigilantColors.onSurfaceVariant),
                            ),
                          ],
                          if (_stopCode.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Durak Kodu: $_stopCode',
                              style: text.labelMedium?.copyWith(
                                  color: VigilantColors.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // "Konuma git" — durağı haritada, yürüme rotasıyla açar.
                    InkWell(
                      onTap: () {
                        Haptics.light();
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => NearbyMapScreen(focusStop: stop),
                        ));
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: 74,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: VigilantColors.primary,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.route_rounded,
                                color: VigilantColors.onPrimary, size: 22),
                            const SizedBox(height: 4),
                            Text('Konuma git',
                                textAlign: TextAlign.center,
                                style: text.labelSmall?.copyWith(
                                    color: VigilantColors.onPrimary,
                                    fontSize: 10)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Bu duraktan geçen hatların kodları — dokununca o hatla alarm.
            if (lines.isNotEmpty)
              SizedBox(
                height: 54,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  itemCount: lines.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => _LineChip(
                    code: lines[i].code,
                    onTap: () => _pick(context, ref, lines[i]),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                    20, 0, 20, AppInsets.pageBottom(context)),
                children: [
                  ..._arrivalsSection(text),
                  for (var i = 0; i < lines.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    _LineCard(
                      brief: lines[i],
                      onTap: () => _pick(context, ref, lines[i]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.brief, required this.onTap});

  final TransitLineBrief brief;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 52),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: VigilantColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(brief.code,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium?.copyWith(
                        color: VigilantColors.primary,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(brief.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.alarm_add_rounded,
                  color: VigilantColors.primary, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bir hattın tek bir otobüsünün bu durağa varış tahmini.
class _Arrival {
  const _Arrival({
    required this.brief,
    required this.line,
    required this.estimate,
  });

  final TransitLineBrief brief;
  final TransitLine line;
  final ArrivalEstimate estimate;
}

/// Bu duraktan geçen bir hattın kod çipi.
class _LineChip extends StatelessWidget {
  const _LineChip({required this.code, required this.onTap});

  final String code;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: VigilantColors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minWidth: 76),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: VigilantColors.surfaceVariant.withValues(alpha: 0.5)),
          ),
          child: Text(
            code,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

/// Yaklaşan tek otobüs kartı.
class _ArrivalRow extends StatelessWidget {
  const _ArrivalRow({
    required this.arrival,
    required this.onTap,
    required this.onAlarm,
  });

  final _Arrival arrival;

  /// Kart gövdesi: otobüsü haritada göster.
  final VoidCallback onTap;

  /// Sağdaki düğme: bu hatla bu durağa alarm kur.
  final VoidCallback onAlarm;

  /// Orta tahmini dakikaya çevirir.
  String get _minutes {
    final m = (arrival.estimate.seconds / 60).round();
    if (arrival.estimate.maxSeconds <= 90) return 'şimdi';
    return '$m dk';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final e = arrival.estimate;
    final imminent = e.maxSeconds <= 120;
    final accent =
        imminent ? VigilantColors.secondary : VigilantColors.onSurface;
    final plate = e.vehicle.plate.trim();

    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      arrival.brief.code,
                      style: text.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      arrival.line.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(
                          color: VigilantColors.onSurfaceVariant, height: 1.3),
                    ),
                    if (plate.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Kapı No: $plate',
                        style: text.labelMedium?.copyWith(
                            color: VigilantColors.onSurfaceVariant),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          'Geliş Süresi: ',
                          style: text.bodyMedium?.copyWith(
                              color: VigilantColors.onSurfaceVariant),
                        ),
                        Text(
                          _minutes,
                          style: text.titleLarge?.copyWith(
                              color: accent, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    // Belirsizliği SAKLAMA: konum ~60 sn'de bir geliyor,
                    // tek dakikalık kesinlik iddia edemeyiz. Ana sayı
                    // okunaklı kalsın diye ikincil satırda duruyor.
                    Text(
                      '${e.rangeLabel} aralığında · ${e.stopsAway} durak'
                      '${e.quality == ArrivalQuality.schedule ? " · tarifeye göre" : ""}',
                      style: text.labelSmall
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Otobüsün hattaki ilerleyişi: kaç durak kaldığını tek
                  // bakışta veren dikey gösterge.
                  _StopsAwayGauge(stopsAway: e.stopsAway, accent: accent),
                  const SizedBox(height: 6),
                  IconButton(
                    onPressed: onAlarm,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Bu hatla alarm kur',
                    icon: const Icon(Icons.alarm_add_rounded,
                        size: 20, color: VigilantColors.primary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Kaç durak kaldı" göstergesi — durak sayısı kadar nokta, hedef en altta.
class _StopsAwayGauge extends StatelessWidget {
  const _StopsAwayGauge({required this.stopsAway, required this.accent});

  final int stopsAway;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // En çok 4 nokta çizilir; fazlası okunmuyor ve kartı uzatıyor.
    final dots = stopsAway.clamp(1, 4);
    return Container(
      width: 46,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.directions_bus_rounded, size: 18, color: accent),
          for (var i = 0; i < dots; i++) ...[
            const SizedBox(height: 4),
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: VigilantColors.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ],
          const SizedBox(height: 5),
          const Icon(Icons.person_pin_circle_rounded,
              size: 18, color: VigilantColors.primary),
        ],
      ),
    );
  }
}
