import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/favorite_route.dart';
import '../data/journey_payload.dart';
import '../data/journey_record.dart';
import '../data/journey_suggestion.dart';
import '../data/models.dart';
import '../data/transit_db.dart';
import '../services/bus_data_service.dart';
import '../data/stopi_tips.dart';
import '../state/city_provider.dart';
import '../state/hero_image_provider.dart';
import '../state/journey_provider.dart';
import '../state/settings_provider.dart';
import '../state/weather_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/duration_label.dart';
import '../util/greeting.dart';
import '../util/haptics.dart';
import '../widgets/anim.dart';
import '../widgets/bottom_nav_shell.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mascot.dart';
import '../widgets/permission_required_sheet.dart';
import '../widgets/skeleton.dart';
import '../widgets/traffic_strip.dart';
import 'alarm_setup_screen.dart';
import 'announcements_screen.dart';
import 'lines_by_type_screen.dart';
import 'live_tracking_screen.dart';
import 'nearby_map_screen.dart';
import 'stop_lines_screen.dart';

/// Ana Sayfa — "StopAlert Ana Sayfa Premium" (Stitch) tasarımının Flutter portu.
/// Koyu tema, marka kırmızısı, Stopi maskotu; canlı yakın duraklar kartı, büyük
/// "Yolculuk Başlat" CTA, premium kategoriler, promo hero ve zengin favoriler.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  // Tasarım paleti (Stitch design.md)
  static const _cardDark = Color(0xFF1E1E1E);
  static const _chipDark = Color(0xFF2C2C2C);
  static const _chipBorder = Color(0xFF3A3A3A);

  static const _months = [
    'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
    'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
  ];

  String get _todayText {
    final n = DateTime.now();
    return '${n.day} ${_months[n.month - 1]} ${n.year}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    ref.watch(settingsProvider); // haptik senkron
    final nickname =
        ref.watch(settingsProvider).valueOrNull?.nickname ?? 'Yolcu';

    /// Arama kutusu DURAKLAR'a gider, Hatlar'a değil.
    ///
    /// Kutunun vaadi "ineceğin durağı ara" — uygulamanın işi de durak alarmı.
    /// Hat listesine düşürmek kullanıcıyı bir adım uzağa atıyordu.
    void goToStops() {
      Haptics.light();
      ref.read(bottomNavIndexProvider.notifier).state = NavTab.stops;
    }

    return Scaffold(
      body: Stack(
        children: [
          // Üstte İstanbul arka planı; altı tema rengine gradient geçişli.
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _HeroBackground(),
          ),
          SafeArea(
            bottom: false,
            child: ListView(
              // Alt boşluk = alt menü (80) + sistem çubuğu payı + nefes.
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, AppInsets.listBottom(context)),
              children: [
                EntranceFade(
                    child: _TopBar(nickname: nickname, dateText: _todayText)),
            const SizedBox(height: 24),
            EntranceFade(delayMs: 60, child: _SearchRow(onTap: goToStops)),
            const SizedBox(height: 20),
            EntranceFade(
              delayMs: 120,
              child: _NearbyCard(
                // ALARM KURMANIN YOLU DURAKTAN GEÇİYOR: kullanıcı "nereye
                // gideceğim" değil "nerede ineceğim" sorusunu çözüyor.
                // Hat listesine düşürmek bir adım fazlaydı.
                onStart: goToStops,
                onOpenStop: (line, stop) => _openStop(context, ref, line, stop),
                onMap: () {
                  Haptics.light();
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const NearbyMapScreen()));
                },
              ),
            ),
            const SizedBox(height: 28),
            EntranceFade(
              delayMs: 180,
              child: _CategoryRow(
                onTap: (type) => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => LinesByTypeScreen(type: type)),
                ),
              ),
            ),
            const SizedBox(height: 28),
            EntranceFade(delayMs: 220, child: _PromoHero(onStart: goToStops)),
            const SizedBox(height: 28),
            // Şehir trafik yoğunlukları (İstanbul canlı, diğerleri yer tutucu).
            // Trafik yoğunluğu İBB servisinden geliyor — yalnızca İstanbul.
            if (ref.watch(activeCityProvider).hasTraffic)
              const EntranceFade(delayMs: 260, child: TrafficStrip()),
            // Sık rota önerisi (bizim özellik) — varsa
            ..._buildSuggestionSection(context, ref, text),
            const SizedBox(height: 28),
            ..._buildFavoritesSection(context, ref, text),
            ..._buildRecentSection(context, ref, text, goToStops),
                const SizedBox(height: 16),
                  ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Favori rotalar (zengin kartlar, yatay) ----

  List<Widget> _buildFavoritesSection(
      BuildContext context, WidgetRef ref, TextTheme text) {
    final favs =
        ref.watch(favoritesStreamProvider).valueOrNull ?? const <FavoriteRoute>[];
    if (favs.isEmpty) return const [];
    return [
      _SectionHeader(
        title: 'Favori Rotalar',
        actionLabel: 'Tümü',
        onAction: () {
          Haptics.light();
          ref.read(bottomNavIndexProvider.notifier).state = NavTab.favorites;
        },
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 176,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: favs.length,
          separatorBuilder: (_, __) => const SizedBox(width: 14),
          itemBuilder: (_, i) => _FavoriteCard(
            favorite: favs[i],
            relative: _relativeTime(favs[i].createdAt),
            onStart: () => _startFavorite(context, ref, favs[i]),
          ),
        ),
      ),
      const SizedBox(height: 28),
    ];
  }

  // ---- Son yolculuklar / boş durum ----

  List<Widget> _buildRecentSection(
    BuildContext context,
    WidgetRef ref,
    TextTheme text,
    VoidCallback goToStops,
  ) {
    final async = ref.watch(journeysStreamProvider);
    final journeys = async.valueOrNull;

    if (async.isLoading && journeys == null) {
      return [
        _SectionHeader(title: 'Son Yolculuklar'),
        const SizedBox(height: 12),
        Row(children: const [
          Expanded(child: SkeletonTile(height: 110)),
          SizedBox(width: 12),
          Expanded(child: SkeletonTile(height: 110)),
        ]),
      ];
    }

    if (journeys != null && journeys.isNotEmpty) {
      final latest = journeys.take(2).toList();
      return [
        _SectionHeader(
          title: 'Son Yolculuklar',
          actionLabel: 'Tümü',
          onAction: () {
            Haptics.light();
            ref.read(bottomNavIndexProvider.notifier).state = NavTab.profile;
          },
        ),
        const SizedBox(height: 12),
        // TAM GENİŞLİK, ALT ALTA. Yan yana iki kart 390 px'lik ekranda kart
        // başına ~145 px içerik alanı bırakıyordu: durak adları ortasından
        // kesiliyor, satırlar birbirine yapışıyordu. Bu kartın tek işi hangi
        // yolculuk olduğunu okutmak.
        for (var i = 0; i < latest.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _JourneyCard(
            record: latest[i],
            relative: _relativeTime(latest[i].createdAt),
            onTap: () => _repeatJourney(context, ref, latest[i]),
          ),
        ],
      ];
    }

    // Boş durum
    return [
      _SectionHeader(title: 'Son Yolculuklar'),
      const SizedBox(height: 12),
      _EmptyJourneys(onStart: goToStops),
    ];
  }

  // ---- Öneri (sık rota) ----

  List<Widget> _buildSuggestionSection(
      BuildContext context, WidgetRef ref, TextTheme text) {
    final journeys =
        ref.watch(journeysStreamProvider).valueOrNull ?? const <JourneyRecord>[];
    final s = JourneySuggester.suggest(journeys, DateTime.now());
    if (s == null) return const [];
    final color = lineTypeColor(LineType.fromName(s.lineTypeName));
    return [
      const SizedBox(height: 28),
      GlassPanel(
        borderRadius: 24,
        borderColor: VigilantColors.primary.withValues(alpha: 0.35),
        padding: const EdgeInsets.all(16),
        onTap: () => _startSuggestion(context, ref, s),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: VigilantColors.primary.withValues(alpha: 0.15),
              ),
              child:
                  const Icon(Icons.auto_awesome, color: VigilantColors.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sık kullandığın rota',
                      style: text.labelMedium
                          ?.copyWith(color: VigilantColors.primary)),
                  const SizedBox(height: 2),
                  Text('${s.boardingStopName} → ${s.targetStopName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('${s.lineCode} · alarmı kurayım mı?',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelMedium
                          ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                ],
              ),
            ),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  shape: BoxShape.circle, color: color.withValues(alpha: 0.15)),
              child: Icon(lineTypeIcon(LineType.fromName(s.lineTypeName)),
                  size: 20, color: color),
            ),
          ],
        ),
      ),
    ];
  }

  // ---- Navigasyon eylemleri ----

  Future<void> _openStop(BuildContext context, WidgetRef ref,
      TransitLine? line, Stop stop) async {
    Haptics.light();
    // OTOBÜS durağı: hangi hatla gidileceği belli değil — duraktan geçen
    // hatlar sunulur, kullanıcı seçince alarma geçilir.
    if (line == null) {
      final lines = await TransitDb.instance.linesForStop(stop.id);
      if (!context.mounted) return;
      if (lines.isEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
              content: Text('Bu duraktan geçen hat bulunamadı.')));
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StopLinesScreen(stop: stop, lines: lines),
      ));
      return;
    }
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(line)
      ..selectTargetStop(stop.id);
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          AlarmSetupScreen(stopName: stop.name, lineLabel: line.code),
    ));
  }

  /// Kayıtlı bir hattı kimliğinden çöz.
  ///
  /// Otobüs hatları indirilen SQLite paketinde, ray/vapur ise gömülü
  /// listede. Favori/geçmiş yalnızca kimlik sakladığı için ikisine de
  /// bakılmalı — eskiden sadece gömülü listeye bakılıyor ve tüm OTOBÜS
  /// favorileri "verisi güncel değil" diye reddediliyordu.
  Future<TransitLine?> _resolveLine(WidgetRef ref, String lineId) async {
    if (isBusId(lineId)) {
      // Favori başka şehirde eklenmiş olabilir; kurulu paketleri açıp ara.
      await BusDataService.instance.openAllForLookup();
      return TransitDb.instance.buildLineAnyCity(lineId);
    }
    final lines = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    for (final l in lines) {
      if (l.id == lineId) return l;
    }
    return null;
  }

  Future<void> _startFavorite(
      BuildContext context, WidgetRef ref, FavoriteRoute fav) async {
    Haptics.light();
    final line = await _resolveLine(ref, fav.lineId);
    if (!context.mounted) return;
    if (line == null ||
        line.indexOfStop(fav.boardingStopId) == -1 ||
        line.indexOfStop(fav.targetStopId) == -1) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Bu favorinin hattı bu cihazda yüklü değil — '
                'şehir paketini Ayarlar’dan indir.')));
      return;
    }
    // FAVORİDEN BAŞLATMA DA İZİN İSTER. Bu yol alarm kurulum ekranını
    // atlıyor ve izin kontrolü orada yapılıyordu; izinsiz başlayan yolculukta
    // alarm sessizce hiç çalmıyordu.
    if (!await PermissionRequiredSheet.ensure(context)) return;
    if (!context.mounted) return;
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(line)
      ..selectBoardingStop(fav.boardingStopId)
      ..selectTargetStop(fav.targetStopId);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LiveTrackingScreen(
        payload: JourneyPayload(
          line: line,
          boardingStopId: fav.boardingStopId,
          targetStopId: fav.targetStopId,
          alarmDistanceMeters: 500,
        ),
      ),
    ));
  }

  /// Hat KODU ve durak ADIndan çöz — geçmiş/öneri kayıtlarında kimlik yok.
  ///
  /// Ray/vapur gömülü listede, otobüs indirilen pakette aranır.
  Future<(TransitLine, Stop)?> _resolveByCode(
      WidgetRef ref, String code, String stopName) async {
    final lines = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    for (final l in lines) {
      if (l.code != code) continue;
      for (final st in l.stops) {
        if (st.name == stopName) return (l, st);
      }
    }
    // Otobüs: hat kodunun varyantları arasında durağı içeren ilkini al.
    try {
      await BusDataService.instance.openAllForLookup();
      final briefs = await TransitDb.instance.searchLines(code, limit: 6);
      for (final b in briefs) {
        if (b.code != code) continue;
        final line = await TransitDb.instance.buildLineAnyCity(b.id);
        if (line == null) continue;
        for (final st in line.stops) {
          if (st.name == stopName) return (line, st);
        }
      }
    } catch (_) {
      // Paket yok/okunamadı: alarm ekranı ad ile açılır.
    }
    return null;
  }

  Future<void> _startSuggestion(
      BuildContext context, WidgetRef ref, JourneySuggestion s) async {
    Haptics.light();
    final hit = await _resolveByCode(ref, s.lineCode, s.targetStopName);
    if (!context.mounted) return;
    if (hit != null) {
      ref.read(journeyDraftProvider.notifier)
        ..reset()
        ..selectLine(hit.$1)
        ..selectTargetStop(hit.$2.id);
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AlarmSetupScreen(
          stopName: hit?.$2.name ?? s.targetStopName,
          lineLabel: hit?.$1.code ?? s.lineCode),
    ));
  }

  Future<void> _repeatJourney(
      BuildContext context, WidgetRef ref, JourneyRecord r) async {
    Haptics.light();
    final hit = await _resolveByCode(ref, r.lineCode, r.targetStopName);
    if (!context.mounted) return;
    if (hit != null) {
      ref.read(journeyDraftProvider.notifier)
        ..reset()
        ..selectLine(hit.$1)
        ..selectTargetStop(hit.$2.id);
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AlarmSetupScreen(
          stopName: hit?.$2.name ?? r.targetStopName,
          lineLabel: hit?.$1.code ?? r.lineCode),
    ));
  }


  String _relativeTime(DateTime? t) {
    if (t == null) return 'yeni';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 60) return 'az önce';
    if (diff.inHours < 24) return '${diff.inHours} sa önce';
    if (diff.inDays == 1) return 'Dün';
    if (diff.inDays < 7) return '${diff.inDays} gün önce';
    return '${t.day}.${t.month}.${t.year}';
  }
}

// ===================== Bileşenler =====================

/// Sayfanın en üstündeki şehir arka planı. Foto üste hizalı; alt tarafı
/// tema rengine doğru gradient geçişli (üstte hafif koyu perde → selam/tarih
/// yazıları okunur kalır). Foto yoksa (asset eksik) sessizce boş geçer.
///
/// Görsel HER AÇILIŞTA rastgele seçilir (bkz. [heroImageProvider]); oturum
/// içinde sabit kalır ki her yeniden çizimde değişip göz yormasın.
class _HeroBackground extends ConsumerWidget {
  const _HeroBackground();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final asset = ref.watch(heroImageProvider);
    return SizedBox(
      height: 300,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (asset != null)
            Image.asset(
              asset,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  bg.withValues(alpha: 0.45), // üst perde (yazı okunsun)
                  bg.withValues(alpha: 0.15),
                  bg.withValues(alpha: 0.88),
                  bg, // alt: tamamen tema rengine erir
                ],
                stops: const [0.0, 0.38, 0.82, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Üst çubuk: profil avatarı + selam + tarih + hava durumu + zil.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.nickname, required this.dateText});

  final String nickname;
  final String dateText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final weather = ref.watch(weatherProvider).valueOrNull;
    return Row(
      children: [
        // PROFİL avatarı — maskot değil.
        //
        // Buradaki yuvarlak kullanıcıyı temsil ediyor (adının yanında duruyor),
        // uygulamayı değil; profil sayfasındaki avatarla aynı simge olması
        // ikisinin aynı şey olduğunu anlatıyor. Maskot ana sayfanın başka
        // yerlerinde duruyor.
        Container(
          width: 48,
          height: 48,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: VigilantColors.surfaceContainer,
            border: Border.all(
                color: VigilantColors.primaryContainer, width: 2),
          ),
          child: const CircleAvatar(
            backgroundColor: VigilantColors.surfaceContainerHigh,
            child: Icon(Icons.person_outline,
                size: 22, color: VigilantColors.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${greetingForHour(DateTime.now().hour)}, $nickname!',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.headlineSmall),
              const SizedBox(height: 3),
              Row(
                children: [
                  Flexible(
                    child: Text(dateText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium?.copyWith(
                            fontSize: 12,
                            color: VigilantColors.onSurfaceVariant)),
                  ),
                  if (weather != null) ...[
                    const SizedBox(width: 8),
                    Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: VigilantColors.outline
                                .withValues(alpha: 0.6))),
                    const SizedBox(width: 8),
                    Icon(weather.icon,
                        size: 14, color: VigilantColors.tertiaryContainer),
                    const SizedBox(width: 3),
                    Text('${weather.tempC}°',
                        style: text.labelMedium?.copyWith(
                            fontSize: 12,
                            color: VigilantColors.onSurfaceVariant)),
                  ],
                ],
              ),
            ],
          ),
        ),
        SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                onPressed: () {
                  Haptics.light();
                  // Bildirim merkezi = İETT hat duyuruları (sefer iptali vb.).
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const AnnouncementsScreen()));
                },
                icon: const ShakeIcon(
                  child: Icon(Icons.notifications_none_rounded,
                      color: VigilantColors.onSurface),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: PulseDot(color: VigilantColors.primary, size: 7),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Arama satırı: "Nerede ineceksin?" + cam arama kutusu + filtre.
class _SearchRow extends StatelessWidget {
  const _SearchRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Nerede ineceksin?',
            style:
                text.bodyMedium?.copyWith(color: VigilantColors.onSurface)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GlassPanel(
                borderRadius: 20,
                onTap: onTap,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
                child: Row(
                  children: [
                    const Icon(Icons.search,
                        color: VigilantColors.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('İneceğin durağı veya hattı ara...',
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                              color: VigilantColors.onSurfaceVariant
                                  .withValues(alpha: 0.7))),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            GlassPanel(
              borderRadius: 20,
              onTap: onTap,
              padding: const EdgeInsets.all(16),
              child: const Icon(Icons.tune, color: VigilantColors.onSurface),
            ),
          ],
        ),
      ],
    );
  }
}

/// Konum satırı + Yakındaki Duraklar kartı (içinde "Yolculuk Başlat" CTA).
class _NearbyCard extends ConsumerWidget {
  const _NearbyCard(
      {required this.onStart, required this.onOpenStop, required this.onMap});

  final VoidCallback onStart;
  /// Ray/vapur durağında hat bellidir; OTOBÜS durağında null gelir ve
  /// kullanıcıya önce "hangi hatla?" sorulur.
  final void Function(TransitLine? line, Stop stop) onOpenStop;
  final VoidCallback onMap;

  String _fmt(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
      : '${m.round()} m';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final locName = ref.watch(currentLocationProvider).valueOrNull?.name;
    final nearby = ref.watch(nearbyStopsProvider);
    final hits = nearby.valueOrNull ?? const <NearbyStopHit>[];
    final nearestBadge = hits.isNotEmpty ? _fmt(hits.first.meters) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.location_on, size: 18, color: VigilantColors.primary),
            const SizedBox(width: 6),
            Flexible(
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  children: [
                    const TextSpan(text: 'Mevcut Konum: '),
                    TextSpan(
                        text: locName ?? 'Konumun',
                        style: const TextStyle(
                            color: VigilantColors.onSurface,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: HomeScreen._cardDark,
            borderRadius: BorderRadius.circular(24),
            border:
                Border.all(color: VigilantColors.surfaceVariant.withValues(alpha: 0.3)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 30,
                  offset: const Offset(0, 8)),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Kırmızı ışıma (sağ üst)
              Positioned(
                right: -30,
                top: -30,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: VigilantColors.primary.withValues(alpha: 0.10),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text('Yakındaki Duraklar',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 8),
                            if (nearestBadge != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: VigilantColors.surfaceContainer,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(nearestBadge,
                                    style: text.labelSmall?.copyWith(
                                        color: VigilantColors.onSurfaceVariant,
                                        fontWeight: FontWeight.w500)),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Sağ üst: haritada göster (yakın duraklar + yürüme rotası).
                      GestureDetector(
                        onTap: onMap,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: VigilantColors.surfaceContainer,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: VigilantColors.surfaceVariant
                                    .withValues(alpha: 0.4)),
                          ),
                          child: const Icon(Icons.map_rounded,
                              size: 18, color: VigilantColors.primary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ...nearby.when(
                    loading: () => [
                      const SkeletonBox(width: double.infinity, height: 18),
                      const SizedBox(height: 12),
                      const SkeletonBox(width: 200, height: 18),
                    ],
                    error: (_, __) => [
                      Text('Yakındaki duraklar alınamadı.',
                          style: text.labelMedium?.copyWith(
                              color: VigilantColors.onSurfaceVariant)),
                    ],
                    data: (hits) => hits.isEmpty
                        ? [
                            Text(
                                'Konum kapalı — yakındaki durakları görmek için '
                                'konum izni ver.',
                                style: text.labelMedium?.copyWith(
                                    color: VigilantColors.onSurfaceVariant)),
                          ]
                        : [
                            for (var i = 0; i < hits.take(2).length; i++) ...[
                              if (i > 0) const SizedBox(height: 14),
                              _NearbyRow(
                                hit: hits[i],
                                live: i == 0,
                                distanceText: _fmt(hits[i].meters),
                                onTap: () =>
                                    onOpenStop(hits[i].line, hits[i].stop),
                              ),
                            ],
                          ],
                  ),
                  const SizedBox(height: 20),
                  // Ana CTA — Yolculuk Başlat
                  _PrimaryCta(onTap: onStart),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NearbyRow extends StatelessWidget {
  const _NearbyRow({
    required this.hit,
    required this.live,
    required this.distanceText,
    required this.onTap,
  });

  final NearbyStopHit hit;
  final bool live;
  final String distanceText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 50),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: HomeScreen._chipDark,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: HomeScreen._chipBorder),
            ),
            child: Text(hit.line?.code ?? 'DURAK',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelLarge
                    ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(hit.stop.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelLarge
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ),
          const SizedBox(width: 8),
          if (live)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sensors,
                    size: 15, color: VigilantColors.primary),
                const SizedBox(width: 4),
                Text(distanceText,
                    style: text.labelLarge?.copyWith(
                        color: VigilantColors.primary,
                        fontWeight: FontWeight.w700)),
              ],
            )
          else
            Text(distanceText,
                style: text.labelLarge?.copyWith(
                    color: VigilantColors.onSurfaceVariant,
                    fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// Büyük kırmızı "Yolculuk Başlat" CTA.
class _PrimaryCta extends StatelessWidget {
  const _PrimaryCta({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: VigilantColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 8,
          shadowColor: VigilantColors.primary.withValues(alpha: 0.4),
        ),
        onPressed: onTap,
        icon: const Icon(Icons.directions_run_rounded),
        label: Text('Yolculuk Başlat',
            style: text.bodyLarge
                ?.copyWith(fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }
}

/// Ulaşım kategorileri — her biri o TÜRÜN hat listesini açar.
///
/// Eskiden hepsi aynı yere (arama ekranına) gidiyordu; çipler süs gibiydi.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.onTap});

  final void Function(LineType type) onTap;

  static const _cats = [
    (
      label: 'Otobüs',
      icon: Icons.directions_bus_filled_rounded,
      type: LineType.bus
    ),
    (
      label: 'Metrobüs',
      icon: Icons.airport_shuttle_rounded,
      type: LineType.metrobus
    ),
    (
      label: 'Marmaray',
      icon: Icons.directions_railway_filled_rounded,
      type: LineType.marmaray
    ),
    (label: 'Metro', icon: Icons.subway_rounded, type: LineType.metro),
    (
      label: 'Vapur',
      icon: Icons.directions_boat_rounded,
      type: LineType.ferry
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _cats.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _CategoryChip(
              label: _cats[i].label,
              icon: _cats[i].icon,
              onTap: () => onTap(_cats[i].type),
            ),
          ),
        ],
      ],
    );
  }
}

class _CategoryChip extends StatefulWidget {
  const _CategoryChip(
      {required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<_CategoryChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final active = _pressed;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: 60,
            height: 60,
            transform: Matrix4.translationValues(0, active ? -3 : 0, 0)
              ..scaleByDouble(
                  active ? 1.06 : 1.0, active ? 1.06 : 1.0, 1, 1),
            transformAlignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? VigilantColors.primary
                  : VigilantColors.surfaceContainer,
              border: Border.all(
                  color: active
                      ? Colors.transparent
                      : VigilantColors.surfaceVariant.withValues(alpha: 0.5)),
              boxShadow: active
                  ? [
                      BoxShadow(
                          color: VigilantColors.primary.withValues(alpha: 0.3),
                          blurRadius: 18,
                          offset: const Offset(0, 6)),
                    ]
                  : null,
            ),
            child: Icon(widget.icon,
                size: 26,
                color: active ? Colors.white : VigilantColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: text.labelMedium?.copyWith(
                  color: active
                      ? VigilantColors.onSurface
                      : VigilantColors.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
        ],
      ),
    );
  }
}

/// Promo hero: gradyan kart + Stopi ipucu balonu + maskot + "Hemen Başla".
class _PromoHero extends ConsumerWidget {
  const _PromoHero({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final weather = ref.watch(weatherProvider).valueOrNull;
    final journeys =
        ref.watch(journeysStreamProvider).valueOrNull ?? const <JourneyRecord>[];
    final favs =
        ref.watch(favoritesStreamProvider).valueOrNull ?? const <FavoriteRoute>[];
    final tip = StopiTips.pick(
      weatherLabel: weather?.label,
      hour: DateTime.now().hour,
      hasFavorites: favs.isNotEmpty,
      hasJourneys: journeys.isNotEmpty,
      seed: DateTime.now().day,
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Gradyan kart
        Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 12, 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1A1A1A), Color(0xFF2D0A0A), Color(0xFF4A0E0E)],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 40,
                  offset: const Offset(0, 20)),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Yolculuğa\nHazır mısın?',
                        style: text.headlineLarge?.copyWith(
                            color: Colors.white,
                            fontSize: 28,
                            height: 1.1,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    Text(
                        'StopAlert, inmek istediğin durağa yaklaşmadan seni '
                        'önceden uyarır.',
                        style: text.labelLarge?.copyWith(
                            color: Colors.white.withValues(alpha: 0.72),
                            height: 1.4,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 20),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF1A1A1A),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999)),
                        textStyle:
                            text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      onPressed: onStart,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.rocket_launch_rounded, size: 18),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text('Hemen Başla',
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Maskot (küçültülmüş, kartın tamamını kaplamaz)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: SizedBox(
                  width: 104,
                  child: AnimatedMascot(MascotAssets.hero, height: 120),
                ),
              ),
            ],
          ),
        ),
        // Stopi ipucu balonu
        Positioned(
          top: -14,
          right: 16,
          child: _TipBubble(tip: tip),
        ),
      ],
    );
  }
}

class _TipBubble extends StatelessWidget {
  const _TipBubble({required this.tip});

  final StopiTip tip;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 230),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceBright.withValues(alpha: 0.95),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(4),
        ),
        border: Border.all(color: VigilantColors.surfaceVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(tip.icon, size: 15, color: VigilantColors.primary),
          const SizedBox(width: 7),
          Flexible(
            child: Text(tip.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.labelMedium
                    ?.copyWith(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

/// Zengin favori kartı: hat kodu + son kullanım + başlangıç→varış + Alarm Kur.
class _FavoriteCard extends StatelessWidget {
  const _FavoriteCard(
      {required this.favorite, required this.relative, required this.onStart});

  final FavoriteRoute favorite;
  final String relative;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = lineTypeColor(favorite.lineType);
    return Container(
      width: 260,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: HomeScreen._cardDark,
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: VigilantColors.surfaceVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: HomeScreen._chipDark,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: HomeScreen._chipBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(lineTypeIcon(favorite.lineType), size: 12, color: color),
                    const SizedBox(width: 5),
                    Text(favorite.lineCode,
                        style: text.labelMedium?.copyWith(
                            color: Colors.white, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const Spacer(),
              Text('Son: $relative',
                  style: text.labelSmall
                      ?.copyWith(color: VigilantColors.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: VigilantColors.primary, width: 2)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(favorite.boardingStopName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
            child: Container(
                width: 2, height: 12, color: VigilantColors.surfaceVariant),
          ),
          Row(
            children: [
              const Icon(Icons.location_on, size: 13, color: VigilantColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(favorite.targetStopName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 38,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: VigilantColors.surfaceContainer,
                foregroundColor: VigilantColors.onSurface,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                        color: VigilantColors.surfaceVariant
                            .withValues(alpha: 0.5))),
              ),
              onPressed: onStart,
              icon: const Icon(Icons.alarm_add_rounded, size: 17),
              label: Text('Alarm Kur',
                  style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bölüm başlığı: başlık + opsiyonel "Tümü" aksiyonu.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
            child: Text(title,
                style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600))),
        if (actionLabel != null && onAction != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32)),
            child: Text(actionLabel!,
                style: text.labelLarge?.copyWith(color: VigilantColors.primary)),
          ),
      ],
    );
  }
}

/// Geçmiş boşken: davetkâr boş durum + "Yolculuk Yap".
class _EmptyJourneys extends StatelessWidget {
  const _EmptyJourneys({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: HomeScreen._cardDark,
        borderRadius: BorderRadius.circular(24),
        border:
            Border.all(color: VigilantColors.surfaceVariant.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          // ÇİZİM DEĞİL İKON: kart küçük ve mesaj tek satır; maskot burada
          // ne anlatıyor belli olmuyordu.
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: VigilantColors.primary.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.route_rounded,
                size: 26, color: VigilantColors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Henüz yolculuk yapmadınız',
                    style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('İlk yolculuğunu kur, ineceğin durağı asla kaçırma.',
                    style: text.labelMedium?.copyWith(
                        color: VigilantColors.onSurfaceVariant, height: 1.35)),
                const SizedBox(height: 12),
                SizedBox(
                  height: 40,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: VigilantColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: onStart,
                    child: const Text('Yolculuk Yap'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Kare son yolculuk kartı.
class _JourneyCard extends StatelessWidget {
  const _JourneyCard(
      {required this.record, required this.relative, required this.onTap});

  final JourneyRecord record;
  final String relative;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = lineTypeColor(record.lineType);
    final mins = record.durationSeconds ~/ 60;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // ESKİ KOYU KART. Hattın rengiyle gradyan denenmişti ve otobüslerde
        // sarıya boğuluyordu — kart içeriğinden çok kendini gösteriyordu.
        // Renk artık yalnızca rozette ve durak noktalarında.
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: HomeScreen._cardDark,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: VigilantColors.surfaceVariant.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(lineTypeIcon(record.lineType), size: 15, color: color),
                  const SizedBox(height: 2),
                  Text(record.lineCode,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: color)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _JourneyLeg(
                    color: color,
                    label: record.boardingStopName,
                    first: true,
                  ),
                  _JourneyLeg(
                    color: color,
                    label: record.targetStopName,
                    first: false,
                  ),
                  const SizedBox(height: 6),
                  Text('${minutesLabel(mins < 1 ? 1 : mins)} · $relative',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall
                          ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.replay_rounded, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}


/// Son yolculuk kartındaki tek durak satırı (kalkış ya da varış).
///
/// Nokta + çizgi düzeni, iki durak adının hangisinin biniş hangisinin iniş
/// olduğunu bakar bakmaz gösteriyor; düz bir "A → B" satırı uzun durak
/// adlarında okunmuyordu.
class _JourneyLeg extends StatelessWidget {
  const _JourneyLeg({
    required this.color,
    required this.label,
    required this.first,
  });

  final Color color;
  final String label;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 14,
          child: Column(
            children: [
              if (!first)
                Container(
                  width: 2,
                  height: 6,
                  color: color.withValues(alpha: 0.45),
                ),
              Container(
                width: first ? 8 : 9,
                height: first ? 8 : 9,
                margin: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: first ? Colors.transparent : color,
                  border: Border.all(color: color, width: 2),
                ),
              ),
              if (first)
                Container(
                  width: 2,
                  height: 6,
                  color: color.withValues(alpha: 0.45),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelMedium?.copyWith(
                  height: 1.2,
                  fontWeight: first ? FontWeight.w500 : FontWeight.w700,
                  color: first ? VigilantColors.onSurfaceVariant : null),
            ),
          ),
        ),
      ],
    );
  }
}
