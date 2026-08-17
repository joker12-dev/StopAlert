import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../services/bus_data_service.dart';
import '../engine/arrival_estimator.dart';
import '../data/timetable.dart';
import '../services/live_bus_service.dart';
import '../services/timetable_service.dart';
import '../services/segment_learning_store.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/native_ad_slot.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../util/turkish.dart';
import 'alarm_setup_screen.dart';
import 'line_detail_screen.dart';
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
    this.embedded = false,
  });

  /// Bir PANELİN içinde mi gösteriliyor (yakındaki duraklar haritası)?
  ///
  /// Gömülüyken kendi Scaffold'unu ve geri satırını çizmez — paneli saran
  /// ekran zaten bir kapatma yolu sunuyor.
  final bool embedded;

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
  String get _stopCode => stop.id.startsWith(kBusPrefix)
      ? stop.id.substring(kBusPrefix.length)
      : '';

  /// Bu durağa yaklaşan otobüsler — en yakın varıştan uzağa sıralı.
  List<_Arrival> _arrivals = const [];

  /// Canlı konum olmayan hatlarda tarifeye göre sıradaki
  /// seferler. Canlı veriyle aynı şey değil, ayrı gösterilir.
  List<_Scheduled> _scheduled = const [];
  bool _loadingArrivals = false;
  DateTime? _arrivalsAt;

  /// Kaç hat için canlı konum sorgulanacağı.
  ///
  /// Bir duraktan 30 hat geçebiliyor; hepsi için ayrı çağrı yapmak hem
  /// yavaş hem de İETT'nin saatlik kotasına yüklenmek olurdu. Kullanıcı
  /// pratikte ilk birkaç hatla ilgileniyor.
  /// Bundan uzaktaki varışlar LİSTELENMEZ.
  ///
  /// Yarım saat sonrasını "yaklaşan araç" saymak listeyi şişiriyor ve asıl
  /// binilecek aracı gözden kaçırtıyor. Bu kadar uzaktaki bir sefer için
  /// bakılacak yer sefer saatleri sayfası.
  static const _maxArrivalSeconds = 30 * 60;

  static const _maxLinesQueried = 10;

  @override
  void initState() {
    super.initState();
    _loadArrivals();
  }

  @override
  void didUpdateWidget(StopLinesScreen old) {
    super.didUpdateWidget(old);
    // HAT LİSTESİ SONRADAN GELİYOR. Harita panelinde durağa dokununca ekran
    // ÖNCE boş hat listesiyle kuruluyor, hatlar async yükleniyor. `initState`
    // yalnızca bir kez çalıştığı için o ilk boş listeyle hesaplanıyor ve
    // hatlar geldiğinde yaklaşan araçlar hiç hesaplanmıyordu (aynı key
    // yüzünden State korunuyor, yeni widget yeni initState açmıyor).
    if (old.stop.id != widget.stop.id ||
        old.lines.length != widget.lines.length) {
      _arrivals = const [];
      _scheduled = const [];
      _arrivalsAt = null;
      _loadArrivals();
    }
  }

  /// Yaklaşan araçlar — HAT TÜRÜNE GÖRE İKİ AYRI KAYNAK.
  ///
  /// Canlı araç konumu yalnızca LASTİKLİ hatlar için var (İETT filo servisi).
  /// Metro, Marmaray, tramvay ve vapurun canlı konumu hiçbir yerde yayınlanmıyor;
  /// onlar TARİFEDEN hesaplanır. Şehir bazlı ayırmak yetmiyordu: İstanbul'da
  /// canlı otobüs var diye metro durakları bomboş kalıyordu.
  Future<void> _loadArrivals() async {
    final TransitCity lineCity = city ?? ref.read(activeCityProvider);

    // HATLARI KENDİ ÇÖZ. Harita panelinden gelindiğinde hat listesi async
    // yükleniyor ve ekran ilk kez boş listeyle kuruluyordu; panelin
    // zamanlamasına bel bağlamak yerine liste boşsa burada doğrudan çözülür.
    var briefs = lines;
    if (briefs.isEmpty) {
      briefs = await _resolveLines(lineCity);
      if (!mounted || briefs.isEmpty) return;
    }

    final rubber = [
      for (final b in briefs)
        if (_isRubberTyred(b.type)) b
    ];
    final rail = [
      for (final b in briefs)
        if (!_isRubberTyred(b.type)) b
    ];

    setState(() => _loadingArrivals = true);
    final learner = await SegmentLearningStore.load();
    final found = <_Arrival>[];

    // CANLI YOL ARTIK ŞEHİRDEN BAĞIMSIZ. Lastikli her hat için canlı araç
    // denenir (İstanbul İETT; Kocaeli e-komobil — izinliyken). Canlı bulunmayan
    // lastikli hatlar tarifeye düşer, ray hatları zaten tarifeden gelir.
    final noLiveRubber = <TransitLineBrief>[];
    for (final brief in rubber.take(_maxLinesQueried)) {
      try {
        final line =
            await TransitDb.instance.buildLine(brief.id, cityId: city?.id);
        if (line == null || line.indexOfStop(stop.id) <= 0) {
          continue;
        }
        final all = await LiveBusService.instance.vehicles(
          brief.code,
          city: lineCity,
          lineId: line.id,
        );
        // Yalnızca BU yöndeki araçlar: karşı yöndeki otobüsün varışını
        // göstermek kullanıcıyı yanlış otobüse bindirir.
        final isGidis = line.id.endsWith('_G');
        final sameWay = [
          for (final v in all)
            if (v.routeCode.contains('_G_') || v.routeCode.contains('_D_'))
              if (v.isGidis == isGidis) v,
        ];
        if (sameWay.isEmpty) {
          noLiveRubber.add(brief); // canlı yok: tarifeye düşecek
          continue;
        }

        final ests = ArrivalEstimator.forStop(
          line: line,
          targetStopId: stop.id,
          vehicles: sameWay,
          learner: learner,
        );
        for (final e in ests) {
          // Yarım saatten uzaktaki araç "yaklaşıyor" değildir.
          if (e.seconds > _maxArrivalSeconds) continue;
          found.add(_Arrival(brief: brief, line: line, estimate: e));
        }
      } catch (_) {
        noLiveRubber.add(brief);
      }
    }

    found.sort((a, b) => a.estimate.seconds.compareTo(b.estimate.seconds));
    if (!mounted) return;
    setState(() {
      _arrivals = found;
      _loadingArrivals = false;
      _arrivalsAt = DateTime.now();
    });

    // Tarife: ray hatları + canlısı bulunamayan lastikli hatlar.
    final scheduled = [...rail, ...noLiveRubber];
    if (scheduled.isNotEmpty && lineCity.hasTimetable) {
      await _loadScheduled(lineCity, scheduled);
    }
  }

  /// Durağın hatlarını (panel vermediyse) doğrudan çözer.
  Future<List<TransitLineBrief>> _resolveLines(TransitCity lineCity) async {
    try {
      if (isBusId(stop.id)) {
        await BusDataService.instance.openAllForLookup();
        return await TransitDb.instance.linesForStopAnyCity(stop.id);
      }
      final rail = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
      return [
        for (final l in rail)
          if (l.stops.any((s) => s.id == stop.id))
            TransitLineBrief(id: l.id, code: l.code, name: l.name, type: l.type),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Tarifeye göre sıradaki seferler (canlı konum olmayan şehirler).
  ///
  /// Hesap: seferin İLK DURAKTAN kalkış saati + ilk duraktan bu durağa
  /// kadarki yol süresi. Plan; trafiği ve gecikmeyi bilmez.
  Future<void> _loadScheduled(
      TransitCity lineCity, List<TransitLineBrief> targets) async {
    setState(() => _loadingArrivals = true);
    final learner = await SegmentLearningStore.load();
    final today = DayType.forDate(DateTime.now());
    final found = <_Scheduled>[];

    for (final brief in targets.take(_maxLinesQueried)) {
      try {
        final line =
            await TransitDb.instance.buildLine(brief.id, cityId: city?.id);
        if (line == null || line.indexOfStop(stop.id) < 0) continue;
        final table = await TimetableService.instance
            .forLine(brief.code, city: lineCity, type: brief.type);
        if (table.isEmpty) continue;
        // Bu varyant hangi yön: kimlikte kodlu ("10_G" gidiş).
        final rows = table.forDay(today, outbound: line.id.contains('_G'));
        if (rows.isEmpty) continue;
        final next = ScheduledArrivals.fromSchedule(
          line: line,
          targetStopId: stop.id,
          departures: rows,
          learner: learner,
          limit: 2,
        );
        for (final n in next) {
          if (n.secondsAway > _maxArrivalSeconds) continue;
          found.add(_Scheduled(brief: brief, line: line, arrival: n));
        }
      } catch (_) {
        // Tek hattın verisi alınamadıysa ötekiler yine gösterilir.
      }
    }

    found
        .sort((a, b) => a.arrival.secondsAway.compareTo(b.arrival.secondsAway));
    if (!mounted) return;
    setState(() {
      _scheduled = found;
      _loadingArrivals = false;
      _arrivalsAt = DateTime.now();
    });
  }

  /// Canlı konumu YAYINLANAN türler. Ötekiler tarifeden hesaplanır.
  static bool _isRubberTyred(LineType t) =>
      t == LineType.bus || t == LineType.metrobus;

  Future<void> _pick(
      BuildContext context, WidgetRef ref, TransitLineBrief brief) async {
    Haptics.light();
    // RAY/VAPUR hatları indirilen SQLite paketinde DEĞİL, ayrı listede.
    // Yalnızca otobüs veritabanına bakmak Marmaray/metro duraklarında
    // "hat verisi yüklenemedi" hatası veriyordu.
    TransitLine? line;
    if (isBusId(brief.id)) {
      line = await TransitDb.instance.buildLine(brief.id, cityId: city?.id);
    } else {
      for (final l
          in ref.read(linesProvider).valueOrNull ?? const <TransitLine>[]) {
        if (l.id == brief.id) {
          line = l;
          break;
        }
      }
    }
    if (!context.mounted) return;
    if (line == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Hat verisi yüklenemedi — tekrar dene.')));
      return;
    }
    // Buradan sonra hat KESİN var (null yukarıda ele alındı); yerel bir
    // değişkene alıp akış analizini netleştiriyoruz.
    final resolved = line;
    // Seçilen durağı hatta bul (aynı bus: önekli id).
    var target = stop;
    final i = resolved.indexOfStop(stop.id);
    if (i != -1) target = resolved.stops[i];
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(resolved)
      ..selectTargetStop(target.id);
    ref.read(recentSearchesProvider.notifier).add(RecentSearch(
          stopName: target.name,
          stopId: target.id,
          lineId: resolved.id,
          lineCode: resolved.code,
          lineTypeName: resolved.type.name,
        ));
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          AlarmSetupScreen(stopName: target.name, lineLabel: resolved.code),
    ));
  }

  /// TARİFEYE göre sıradaki seferler bloğu.
  ///
  /// Canlı bölümden AYRI ve farklı isimli: "yaklaşan otobüs" demek, gerçekten
  /// yolda olduğunu bildiğimiz anlamına gelir. Burada yalnızca planı biliyoruz.
  List<Widget> _scheduledSection(TextTheme text, TransitCity lineCity) {
    if (!lineCity.hasTimetable) return const [];
    if (!_loadingArrivals && _scheduled.isEmpty && _arrivalsAt == null) {
      return const [];
    }
    return [
      Row(
        children: [
          const Icon(Icons.schedule_rounded,
              size: 16, color: VigilantColors.tertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text('TARİFEYE GÖRE YAKLAŞANLAR',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall?.copyWith(
                    color: VigilantColors.onSurfaceVariant,
                    letterSpacing: 1.2)),
          ),
          if (_loadingArrivals)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      const SizedBox(height: 10),
      if (_scheduled.isEmpty && !_loadingArrivals)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'Bugün için kalan sefer görünmüyor.',
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        )
      else
        for (final a in _scheduled.take(6)) ...[
          _ScheduledRow(item: a, onAlarm: () => _pick(context, ref, a.brief)),
          const SizedBox(height: 8),
        ],
      if (_scheduled.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(
            'Metro, Marmaray, tramvay ve vapurun canlı konumu yayınlanmıyor; '
            'saatler TARİFEDEN hesaplanır.',
            style: text.labelSmall
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 18),
    ];
  }

  /// Hattın kendi sayfası (duraklar, yön, sefer saatleri).
  void _openLinePage(TransitLineBrief brief) {
    Haptics.light();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          LineDetailScreen(code: brief.code, city: city, type: brief.type),
    ));
  }

  /// Bu otobüsü haritada TEK BAŞINA göster.
  ///
  /// Bakılan DURAK da haritada işaretli kalır: aracın nerede olduğu tek
  /// başına bir şey söylemiyor, asıl soru "bana ne kadar kaldı".
  void _openBusOnMap(_Arrival a) {
    Haptics.light();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LiveBusScreen(
        line: a.line,
        city: city,
        focusPlate: a.estimate.vehicle.plate,
        highlightStopId: stop.id,
      ),
    ));
  }

  /// "Yaklaşan araçlar" bloğu.
  ///
  /// İKİSİ BİRDEN ÇİZİLİR: bir durakta hem otobüs hem metro/Marmaray olabilir.
  /// Eskiden yalnızca şehre bakılıyordu; İstanbul'da canlı otobüs var diye
  /// Marmaray duraklarında boş bir "yaklaşan otobüs yok" yazısı çıkıyordu.
  List<Widget> _arrivalsSection(TextTheme text) {
    final TransitCity lineCity = city ?? ref.read(activeCityProvider);
    // CANLI bölüm lastikli hat varsa gösterilir (şehir fark etmez); veri
    // yoksa bölüm kendini gizler. TARİFE bölümü kendi kaydı doldukça çıkar.
    final hasRubber = lines.any((b) => _isRubberTyred(b.type));
    return [
      // Yaklaşan araçların ÜSTÜNE yerel reklam. Tam ekran değil, içeriği
      // kesmez; yüklenmezse hiç yer kaplamaz.
      const NativeAdSlot(
        key: ValueKey('stop-info-native-ad'),
        margin: EdgeInsets.only(bottom: 14),
        template: TemplateType.small,
      ),
      if (hasRubber) ..._liveSection(text),
      ..._scheduledSection(text, lineCity),
    ];
  }

  /// Canlı filodan yaklaşanlar (yalnızca lastikli hatlar).
  List<Widget> _liveSection(TextTheme text) {
    if (!_loadingArrivals && _arrivals.isEmpty && _arrivalsAt == null) {
      return const [];
    }
    return [
      Row(
        children: [
          const Icon(Icons.directions_bus_filled_rounded,
              size: 16, color: VigilantColors.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('YAKLAŞAN ARAÇLAR',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall?.copyWith(
                    color: VigilantColors.onSurfaceVariant,
                    letterSpacing: 1.2)),
          ),
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
            'Şu an bu durağa yaklaşan araç görünmüyor.',
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        )
      else
        for (final a in _arrivals.take(6)) ...[
          _ArrivalRow(
            arrival: a,
            onLive: () => _openBusOnMap(a),
            onAlarm: () => _pick(context, ref, a.brief),
            onInfo: () => _openLinePage(a.brief),
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded)
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
                // PANELDE "Konuma git" YOK: kullanıcı durağı zaten
                // haritadan seçti, onu haritaya götürmenin bir anlamı
                // kalmıyor. Onun yerine oradan devam edeceği şey duruyor:
                // yol tarifi.
                InkWell(
                  onTap: () {
                    Haptics.light();
                    if (widget.embedded) {
                      // TAM EKRAN AÇ: panel dar, hatların ve yaklaşan
                      // araçların tamamı sığmıyor.
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => StopLinesScreen(
                          stop: stop,
                          lines: lines,
                          city: city,
                        ),
                      ));
                    } else {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => NearbyMapScreen(focusStop: stop),
                      ));
                    }
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
                        Icon(
                            widget.embedded
                                ? Icons.open_in_full_rounded
                                : Icons.route_rounded,
                            color: VigilantColors.onPrimary,
                            size: 22),
                        const SizedBox(height: 4),
                        Text(widget.embedded ? 'Tam ekran' : 'Konuma git',
                            textAlign: TextAlign.center,
                            style: text.labelSmall?.copyWith(
                                color: VigilantColors.onPrimary, fontSize: 10)),
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
                20,
                0,
                20,
                // PANELDE alt menü + reklam da işin içinde: panelin kendi
                // alt kenarı ekranın altına yapışık ve son satır menünün
                // altında kalıyordu.
                widget.embedded
                    ? AppInsets.listBottom(context)
                    : AppInsets.pageBottom(context)),
            children: [
              ..._arrivalsSection(text),
              // Başlık BÖLÜMLERDEN BAĞIMSIZ: yaklaşan otobüs / tarife
              // bölümü çizilmediğinde (canlı veri yok, şehir
              // desteklemiyor) hat listesi başlıksız kalıyordu.
              if (lines.isNotEmpty) ...[
                Row(
                  children: [
                    const Icon(Icons.alt_route_rounded,
                        size: 16, color: VigilantColors.primary),
                    const SizedBox(width: 8),
                    Text('BU DURAKTAN GEÇEN HATLAR',
                        style: text.labelSmall?.copyWith(
                            color: VigilantColors.onSurfaceVariant,
                            letterSpacing: 1.2)),
                  ],
                ),
                const SizedBox(height: 10),
              ],
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
    );
    // Gömülüyken panelin içine düz gövde konur; tek başına açıldığında
    // kendi Scaffold'u olur.
    if (widget.embedded) return body;
    return Scaffold(body: SafeArea(bottom: false, child: body));
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
    required this.onLive,
    required this.onAlarm,
    required this.onInfo,
  });

  final _Arrival arrival;

  /// Aracın canlı konumunu haritada aç.
  final VoidCallback onLive;

  /// Bu hatla bu durağa alarm kur.
  final VoidCallback onAlarm;

  /// Hattın kendi sayfasını aç (duraklar, yön, sefer saatleri).
  final VoidCallback onInfo;

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

    // KARTIN TAMAMI TIKLANMIYOR.
    //
    // Eskiden karta dokunmak doğrudan canlı konumu açıyordu; kullanıcı
    // alarm kurmak ya da hattın sayfasına gitmek istediğinde yanlış yere
    // düşüyordu. Üç eylem de artık kendi düğmesinde ve adı yazılı.
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                            color: VigilantColors.onSurfaceVariant,
                            height: 1.3),
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
                // Otobüsün hattaki ilerleyişi: kaç durak kaldığını tek
                // bakışta veren dikey gösterge.
                _StopsAwayGauge(stopsAway: e.stopsAway, accent: accent),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _ArrivalAction(
                    icon: Icons.alarm_add_rounded,
                    label: 'Alarm kur',
                    filled: true,
                    onTap: onAlarm,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ArrivalAction(
                    icon: Icons.my_location_rounded,
                    label: 'Canlı konum',
                    onTap: onLive,
                  ),
                ),
                const SizedBox(width: 8),
                _ArrivalAction(
                  icon: Icons.info_outline_rounded,
                  tooltip: 'Hat sayfası',
                  onTap: onInfo,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Yaklaşan araç kartındaki tek eylem düğmesi.
///
/// [label] verilmezse yalnızca simge çizilir (dar "i" düğmesi).
class _ArrivalAction extends StatelessWidget {
  const _ArrivalAction({
    required this.icon,
    required this.onTap,
    this.label,
    this.tooltip,
    this.filled = false,
  });

  final IconData icon;
  final String? label;
  final String? tooltip;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final fg = filled ? VigilantColors.onPrimary : VigilantColors.primary;
    final button = Material(
      color: filled
          ? VigilantColors.primary
          : VigilantColors.primary.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () {
          Haptics.light();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: label == null ? 12 : 10, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: fg),
              if (label case final l?) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(l,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelMedium
                          ?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
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

/// Tarifeye göre planlanmış tek sefer.
class _Scheduled {
  const _Scheduled({
    required this.brief,
    required this.line,
    required this.arrival,
  });

  final TransitLineBrief brief;
  final TransitLine line;
  final ScheduledArrival arrival;
}

/// Tarifeye göre sıradaki sefer satırı.
class _ScheduledRow extends StatelessWidget {
  const _ScheduledRow({required this.item, required this.onAlarm});

  final _Scheduled item;
  final VoidCallback onAlarm;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final a = item.arrival;
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onAlarm,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(item.brief.code,
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(
                      item.line.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(
                          color: VigilantColors.onSurfaceVariant, height: 1.3),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Kalkış ${a.departureTime}',
                      style: text.labelSmall
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Saat ÖNCE: tarifeye dayanan bir bilgide "12 dk" değil,
                  // "14:32" kullanıcının doğrulayabileceği şeydir.
                  Text(a.clockLabel,
                      style: text.titleLarge?.copyWith(
                          color: VigilantColors.tertiaryContainer,
                          fontWeight: FontWeight.w800)),
                  Text('~${a.awayLabel}',
                      style: text.labelSmall
                          ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                ],
              ),
              IconButton(
                onPressed: onAlarm,
                visualDensity: VisualDensity.compact,
                tooltip: 'Bu hatla alarm kur',
                icon: const Icon(Icons.alarm_add_rounded,
                    size: 20, color: VigilantColors.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
