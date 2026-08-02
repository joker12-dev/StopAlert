import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/iett_service.dart';
import '../state/city_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../widgets/mascot.dart';

/// İETT duyuruları (sefer iptali, güzergâh değişikliği). Kaynak: İBB Açık Veri
/// — lisans gereği ekranda atıf gösterilir.
final announcementsProvider =
    FutureProvider.autoDispose<List<IettAnnouncement>>((ref) async {
  return IettService.instance.announcements();
});

/// Bildirim merkezi — hat duyurularını listeler, hat adına göre filtrelenir.
class AnnouncementsScreen extends ConsumerStatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  ConsumerState<AnnouncementsScreen> createState() =>
      _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends ConsumerState<AnnouncementsScreen> {
  String _query = '';

  /// 0 = Anlık durumlar (güzergâh/trafik), 1 = Sefer bilgilendirmeleri.
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final async = ref.watch(announcementsProvider);
    final all = async.valueOrNull ?? const <IettAnnouncement>[];
    final q = _query.trim().toLowerCase();

    // Sefer iptali/saat bildirimleri ile anlık durum duyurularını AYIR:
    // ikisi karışınca 200+ sefer iptali diğerlerini boğuyordu.
    final durum = [for (final a in all) if (!a.isTrip) a];
    final sefer = [for (final a in all) if (a.isTrip) a];
    final source = _tab == 0 ? durum : sefer;
    final items = q.isEmpty
        ? source
        : [
            for (final a in source)
              if (a.line.toLowerCase().contains(q) ||
                  a.message.toLowerCase().contains(q))
                a
          ];

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
                  Expanded(
                    child: Text('Duyurular',
                        style: text.headlineSmall?.copyWith(fontSize: 20)),
                  ),
                  IconButton(
                    tooltip: 'Yenile',
                    onPressed: () {
                      Haptics.light();
                      ref.invalidate(announcementsProvider);
                    },
                    icon: const Icon(Icons.refresh_rounded,
                        color: VigilantColors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            // Tür ayrımı: anlık durumlar / sefer bilgilendirmeleri
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Row(
                children: [
                  Expanded(
                    child: _TypeTab(
                      label: 'Anlık durumlar',
                      count: durum.length,
                      selected: _tab == 0,
                      color: VigilantColors.accentBlue,
                      onTap: () => setState(() => _tab = 0),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TypeTab(
                      label: 'Sefer bilgisi',
                      count: sefer.length,
                      selected: _tab == 1,
                      color: VigilantColors.tertiaryContainer,
                      onTap: () => setState(() => _tab = 1),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: TextField(
                style: text.bodyMedium,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: VigilantColors.surfaceContainer,
                  prefixIcon: const Icon(Icons.search,
                      color: VigilantColors.onSurfaceVariant),
                  hintText: 'Hat veya duyuru ara',
                  hintStyle: text.bodyMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: !ref.watch(activeCityProvider).hasAnnouncements
                  ? _noFeed(text, ref.watch(activeCityProvider).name)
                  : async.isLoading && all.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: VigilantColors.primary))
                  : items.isEmpty
                      ? _empty(text, all.isEmpty)
                      : ListView.separated(
                          padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.pageBottom(context)),
                          itemCount: items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, i) =>
                              _AnnouncementCard(item: items[i]),
                        ),
            ),
            // Lisans gereği kaynak atfı (İBB Açık Veri Lisansı / CC BY 4.0).
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                IettService.attribution,
                textAlign: TextAlign.center,
                style: text.labelSmall
                    ?.copyWith(color: VigilantColors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Şehrin duyuru beslemesi yok (İETT'nin karşılığı Kocaeli'de bulunmuyor).
  /// Boş liste göstermek "duyuru yok" gibi okunurdu; sebebi açıkça yazılır.
  Widget _noFeed(TextTheme text, String cityName) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Mascot(MascotAssets.dikkat, height: 110),
              const SizedBox(height: 12),
              Text(
                '$cityName için duyuru servisi yok',
                textAlign: TextAlign.center,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Hat duyuruları İETT’nin açık servisinden geliyor; '
                '$cityName belediyesi böyle bir besleme yayınlamıyor. '
                'Alarm ve takip normal çalışır.',
                textAlign: TextAlign.center,
                style: text.bodyMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );

  Widget _empty(TextTheme text, bool nothingLoaded) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Mascot(MascotAssets.dikkat, height: 110),
              const SizedBox(height: 12),
              Text(
                nothingLoaded
                    ? 'Duyurular alınamadı — internet bağlantını kontrol et.'
                    : 'Aramanla eşleşen duyuru yok.',
                textAlign: TextAlign.center,
                style: text.bodyMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
}

/// Duyuru türü sekmesi (anlık durum / sefer bilgisi) + sayaç.
class _TypeTab extends StatelessWidget {
  const _TypeTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.15)
              : VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? color
                : VigilantColors.surfaceVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge?.copyWith(
                    color: selected ? color : VigilantColors.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  )),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: (selected ? color : VigilantColors.onSurfaceVariant)
                    .withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('$count',
                  style: text.labelSmall?.copyWith(
                      color: selected ? color : VigilantColors.onSurfaceVariant,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard({required this.item});

  final IettAnnouncement item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = item.isTrip
        ? VigilantColors.tertiaryContainer
        : VigilantColors.accentBlue;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: VigilantColors.surfaceVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(item.type.isEmpty ? 'Duyuru' : item.type,
                    style: text.labelSmall?.copyWith(
                        color: accent, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(item.line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: VigilantColors.onSurface)),
              ),
              if (item.time.isNotEmpty)
                Text(item.time,
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          Text(item.message,
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant)),
        ],
      ),
    );
  }
}
