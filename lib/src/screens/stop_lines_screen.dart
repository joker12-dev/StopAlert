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
import '../services/izmir_live_service.dart';
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
import 'guide_screen.dart';
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

  /// "Yaklaşan Araçlar" katlanır bölümü VARSAYILAN KAPALI. Kullanıcı durak
  /// sayfasına alarm kurmaya gelir; canlı araç sorgusu (İETT/ESHOT çağrısı)
  /// yalnızca kullanıcı bu bölümü AÇINCA yapılır — ilgilenmeyenler boşuna
  /// veri indirmez.
  bool _arrivalsExpanded = false;
  bool _arrivalsLoadedOnce = false;

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
    // Yaklaşan araçlar VARSAYILAN KAPALI → açılışta canlı veri çekilmez.
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
      _arrivalsLoadedOnce = false;
      // Bölüm zaten açıksa yeni durak için yeniden yükle; kapalıysa dokunma.
      if (_arrivalsExpanded) {
        _arrivalsLoadedOnce = true;
        _loadArrivals();
      }
    }
  }

  /// Katlanır "Yaklaşan Araçlar" başlığına dokununca aç/kapat. İlk açılışta
  /// canlı veriyi bir kez yükler.
  void _toggleArrivals() {
    Haptics.light();
    setState(() => _arrivalsExpanded = !_arrivalsExpanded);
    if (_arrivalsExpanded && !_arrivalsLoadedOnce) {
      _arrivalsLoadedOnce = true;
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

    // İZMİR: ESHOT canlı "durağa yaklaşan otobüsler" — tek durak çağrısı,
    // paketten çözülen hat + gerçek segment süresiyle varış. Ardından tarife.
    if (lineCity.id == TransitCities.izmir.id && rubber.isNotEmpty) {
      final iz = await IzmirLiveService.arrivalsForStop(stop);
      if (!mounted) return;
      setState(() {
        _arrivals = [
          for (final a in iz)
            _Arrival(
              brief: TransitLineBrief(
                  id: a.line.id,
                  code: a.line.code,
                  name: a.line.name,
                  type: a.line.type),
              line: a.line,
              estimate: a.estimate),
        ];
        _loadingArrivals = false;
        _arrivalsAt = DateTime.now();
      });
      if (lineCity.hasTimetable) {
        await _loadScheduled(lineCity, [...rail, ...rubber]);
      }
      return;
    }

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
          _ScheduledRow(item: a),
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

  /// "Alarm kurmak için hattını seç" — durak sayfasının BİRİNCİL eylemi.
  ///
  /// Yaklaşan araç ve tarife kartlarındaki alarm düğmeleri kaldırıldı;
  /// kullanıcı onları "şu otobüse/sefere alarm" sanıyordu. Alarm HEP buradan,
  /// bineceği hattı seçerek kurulur. Başlık + tek cümlelik yönlendirme,
  /// kafasını bulandırmadan sonuca götürür.
  List<Widget> _chooseLineSection(TextTheme text) {
    return [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
        decoration: BoxDecoration(
          // Uygulamanın çoğunlukla kullandığı standart koyu kart rengi.
          color: VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(18),
          border:
              Border.all(color: VigilantColors.primary.withValues(alpha: 0.30)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: VigilantColors.primary.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.alarm_add_rounded,
                  color: VigilantColors.primary, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Alarm kurmak için hattını seç',
                      style: text.titleSmall?.copyWith(
                          color: VigilantColors.onSurface,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(
                    'İçinde olduğun ya da bineceğin aracı seç; durağına '
                    'yaklaşınca seni uyaralım.',
                    style: text.labelMedium?.copyWith(
                        color: VigilantColors.onSurfaceVariant, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      // 3 sütunlu ızgara; 9'dan fazla hat varsa yana kaydırmalı sayfalar.
      _LineGrid(
        lines: lines,
        onPick: (b) => _pick(context, ref, b),
        onInfo: _openLinePage,
      ),
      const SizedBox(height: 18),
    ];
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
      // KATLANIR BAŞLIK (varsayılan kapalı): dokununca açılır ve canlı veri
      // ilk kez o an yüklenir.
      Material(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: _toggleArrivals,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
            child: Row(
              children: [
                const Icon(Icons.directions_bus_filled_rounded,
                    size: 18, color: VigilantColors.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Yaklaşan Araçlar',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (!_arrivalsExpanded) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'görmek için tıklayın',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelMedium?.copyWith(
                              color: VigilantColors.onSurfaceVariant
                                  .withValues(alpha: 0.55),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_arrivalsExpanded && _loadingArrivals)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (_arrivalsExpanded)
                  IconButton(
                    onPressed: () {
                      Haptics.light();
                      _loadArrivals();
                    },
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Yenile',
                    icon: const Icon(Icons.refresh_rounded,
                        size: 20, color: VigilantColors.onSurfaceVariant),
                  ),
                AnimatedRotation(
                  turns: _arrivalsExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.expand_more_rounded,
                        color: VigilantColors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (_arrivalsExpanded) ...[
        const SizedBox(height: 12),
        // Yaklaşan araçların ÜSTÜNE yerel reklam. Tam ekran değil, içeriği
        // kesmez; yüklenmezse hiç yer kaplamaz.
        const NativeAdSlot(
          key: ValueKey('stop-info-native-ad'),
          margin: EdgeInsets.only(bottom: 14),
          template: TemplateType.small,
        ),
        if (hasRubber) ..._liveSection(text),
        ..._scheduledSection(text, lineCity),
      ],
      const SizedBox(height: 18),
    ];
  }

  /// Canlı filodan yaklaşanlar (yalnızca lastikli hatlar). Başlık/yenile
  /// katlanır bölümün kendisinde; burada yalnızca liste + dipnot.
  List<Widget> _liveSection(TextTheme text) {
    if (!_loadingArrivals && _arrivals.isEmpty && _arrivalsAt == null) {
      return const [];
    }
    return [
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
                // "Nasıl durak seçilir / alarm kurulur?" bilgi butonu.
                IconButton(
                  tooltip: 'Nasıl kullanılır?',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) =>
                            const GuideScreen(section: GuideSection.stop)),
                  ),
                  icon: const Icon(Icons.help_outline_rounded,
                      color: VigilantColors.onSurfaceVariant),
                ),
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
        const SizedBox(height: 12),
        Expanded(
          child: RefreshIndicator(
            color: VigilantColors.primary,
            // AŞAĞI ÇEK-YENİLE: yaklaşan araçları yeniden hesaplar.
            onRefresh: () async {
              _arrivals = const [];
              _scheduled = const [];
              _arrivalsAt = null;
              await _loadArrivals();
            },
            child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
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
              // ÖNCE "hattını seç": kullanıcı durak sayfasına alarm kurmaya
              // gelir. Yaklaşan araç kartındaki "Alarm kur" düğmesi "şu
              // otobüse alarm" gibi anlaşılıyordu; alarm kurmanın TEK yeri
              // artık bu başlıklı hat listesi. Yaklaşan araçlar altında
              // yalnızca BİLGİ olarak durur.
              if (lines.isNotEmpty) ..._chooseLineSection(text),
              ..._arrivalsSection(text),
            ],
          ),
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

/// "Alarm kurmak için hattını seç" ızgarası: 2 sütun, satır başına 2 hat.
///
/// Alt alta uzun liste yerine kompakt 2×N ızgara; 6'dan fazla hat olduğunda
/// sayfalara bölünüp YANA KAYDIRILIR (dikey yer kaplamaz). Kutucuğun sol tarafı
/// alarm kurar; sağdaki bilgi alanı hattın sayfasını açar.
class _LineGrid extends StatefulWidget {
  const _LineGrid({
    required this.lines,
    required this.onPick,
    required this.onInfo,
  });

  final List<TransitLineBrief> lines;
  final void Function(TransitLineBrief) onPick;
  final void Function(TransitLineBrief) onInfo;

  @override
  State<_LineGrid> createState() => _LineGridState();
}

class _LineGridState extends State<_LineGrid> {
  final _controller = PageController();
  int _page = 0;
  bool _nudged = false;

  static const _cols = 2; // 2×3
  static const _perPage = _cols * 3; // 6
  static const _tileH = 66.0;
  static const _gap = 8.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// İLK GİRİŞTE kaydırma ipucu: sayfa yana biraz kayar, sonra yerine döner —
  /// kullanıcı daha fazla hat için yana kaydırabileceğini anlar.
  void _maybeNudge(bool multi) {
    if (_nudged || !multi) return;
    _nudged = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_controller.hasClients) return;
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted || !_controller.hasClients) return;
      try {
        await _controller.animateTo(36,
            duration: const Duration(milliseconds: 360), curve: Curves.easeOut);
        if (!mounted || !_controller.hasClients) return;
        await _controller.animateTo(0,
            duration: const Duration(milliseconds: 460), curve: Curves.easeOut);
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    final pages = <List<TransitLineBrief>>[];
    for (var i = 0; i < lines.length; i += _perPage) {
      final end = i + _perPage < lines.length ? i + _perPage : lines.length;
      pages.add(lines.sublist(i, end));
    }
    if (pages.isEmpty) return const SizedBox.shrink();

    final multi = pages.length > 1;
    _maybeNudge(multi);
    // Tek sayfada satır sayısı hat sayısına göre; çok sayfada hep 3 satır.
    final rows = multi ? 3 : ((lines.length + 1) ~/ _cols).clamp(1, 3);
    final gridHeight = rows * _tileH + (rows - 1) * _gap;
    final active = _page.clamp(0, pages.length - 1);

    return Column(
      children: [
        SizedBox(
          height: gridHeight,
          child: multi
              ? PageView(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    // Sayfa değişirken kutucuklar birbirine sıfır görünmesin
                    // diye her sayfaya yatay boşluk.
                    for (final pg in pages)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: _grid(pg),
                      ),
                  ],
                )
              : _grid(pages.first),
        ),
        if (multi) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < pages.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == active ? 20 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: i == active
                        ? VigilantColors.primary
                        : VigilantColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Bir sayfayı 2 sütunlu satırlara dizer (boş hücreler boşlukla dolar).
  Widget _grid(List<TransitLineBrief> pg) {
    final rowWidgets = <Widget>[];
    for (var r = 0; r * _cols < pg.length; r++) {
      final cells = <Widget>[];
      for (var c = 0; c < _cols; c++) {
        if (c > 0) cells.add(const SizedBox(width: _gap));
        final idx = r * _cols + c;
        cells.add(Expanded(
          child: idx < pg.length
              ? _LineTile(
                  brief: pg[idx],
                  onTap: () => widget.onPick(pg[idx]),
                  onInfo: () => widget.onInfo(pg[idx]),
                )
              : const SizedBox.shrink(),
        ));
      }
      if (r > 0) rowWidgets.add(const SizedBox(height: _gap));
      rowWidgets.add(SizedBox(height: _tileH, child: Row(children: cells)));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rowWidgets);
  }
}

/// Izgaradaki tek hat kutucuğu — kart alarm, sağ üstte küçük kare hat bilgisi.
class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.brief,
    required this.onTap,
    required this.onInfo,
  });

  final TransitLineBrief brief;
  final VoidCallback onTap;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(14);
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 36, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(brief.code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(
                            color: VigilantColors.primary,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(brief.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelSmall
                            ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: InkWell(
              onTap: onInfo,
              borderRadius: BorderRadius.circular(7),
              child: Container(
                width: 27,
                height: 27,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: VigilantColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: VigilantColors.primary.withValues(alpha: 0.24),
                  ),
                ),
                child: const Icon(Icons.info_outline_rounded,
                    size: 15, color: VigilantColors.primary),
              ),
            ),
          ),
        ],
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

/// Yaklaşan tek otobüs kartı.
class _ArrivalRow extends StatelessWidget {
  const _ArrivalRow({
    required this.arrival,
    required this.onLive,
    required this.onInfo,
  });

  final _Arrival arrival;

  /// Aracın canlı konumunu haritada aç.
  final VoidCallback onLive;

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
                    icon: Icons.my_location_rounded,
                    label: 'Canlı konum',
                    onTap: onLive,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ArrivalAction(
                    icon: Icons.directions_bus_filled_rounded,
                    label: 'Hat sayfası',
                    onTap: onInfo,
                  ),
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
  });

  final IconData icon;
  final String? label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const fg = VigilantColors.primary;
    final button = Material(
      color: VigilantColors.primary.withValues(alpha: 0.12),
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
    return button;
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
  const _ScheduledRow({required this.item});

  final _Scheduled item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final a = item.arrival;
    // BİLGİ satırı: tıklanmaz. Alarm, yukarıdaki "hattını seç" listesinden
    // kurulur; buradaki eski alarm düğmesi "şu sefere alarm" sanılıyordu.
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
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
            ],
          ),
        ),
    );
  }
}
