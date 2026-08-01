import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/iett_service.dart';
import '../theme/app_theme.dart';
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

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final async = ref.watch(announcementsProvider);
    final all = async.valueOrNull ?? const <IettAnnouncement>[];
    final q = _query.trim().toLowerCase();
    final items = q.isEmpty
        ? all
        : [
            for (final a in all)
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
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
              child: async.isLoading && all.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: VigilantColors.primary))
                  : items.isEmpty
                      ? _empty(text, all.isEmpty)
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
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
