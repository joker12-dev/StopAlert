import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_announcement.dart';
import '../state/app_announcements_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../widgets/offline_banner.dart';
import '../widgets/mascot.dart';
import '../widgets/offline_notice.dart';

/// Bildirim merkezi — UYGULAMA duyuruları (aksaklık, bakım, güncelleme,
/// bilgilendirme). Kaynak: uzak JSON (bkz. [AppAnnouncementsService]).
class AnnouncementsScreen extends ConsumerStatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  ConsumerState<AnnouncementsScreen> createState() =>
      _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends ConsumerState<AnnouncementsScreen> {
  bool _markedSeen = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final async = ref.watch(appAnnouncementsProvider);
    final items = async.valueOrNull ?? const <AppAnnouncement>[];

    // İlk yüklemede en yeni duyuruyu "okundu" işaretle (zil rozeti sönsün).
    if (!_markedSeen && items.isNotEmpty) {
      _markedSeen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(announcementsSeenProvider.notifier).markSeen(items.first.id);
      });
    }

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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Duyurular',
                            style: text.headlineSmall?.copyWith(fontSize: 20)),
                        Text(
                          async.isLoading
                              ? 'Yenileniyor…'
                              : 'Uygulama duyuruları',
                          style: text.labelSmall?.copyWith(
                              color: VigilantColors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Yenile',
                    onPressed: () {
                      Haptics.light();
                      ref.read(appAnnouncementsRefreshProvider.notifier).state++;
                    },
                    icon: const Icon(Icons.refresh_rounded,
                        color: VigilantColors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const OfflineBanner(
                message: 'Bağlantı yok — duyurular güncellenemiyor.'),
            Expanded(
              child: async.isLoading && items.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: VigilantColors.primary))
                  : RefreshIndicator(
                      color: VigilantColors.primary,
                      onRefresh: () async {
                        Haptics.light();
                        ref
                            .read(appAnnouncementsRefreshProvider.notifier)
                            .state++;
                        await Future<void>.delayed(
                            const Duration(milliseconds: 500));
                      },
                      child: items.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                async.hasError
                                    ? OfflineNotice(
                                        title: 'Duyurular alınamadı',
                                        detail:
                                            'Duyuru dosyasına ulaşılamadı. '
                                            'Bağlantını kontrol edip tekrar dene.',
                                        onRetry: () => ref
                                            .read(appAnnouncementsRefreshProvider
                                                .notifier)
                                            .state++,
                                      )
                                    : _empty(text),
                              ],
                            )
                          : ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: EdgeInsets.fromLTRB(
                                  20, 4, 20, AppInsets.pageBottom(context)),
                              itemCount: items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, i) =>
                                  _AnnouncementCard(item: items[i]),
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(TextTheme text) => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Mascot(MascotAssets.hero, height: 120),
              const SizedBox(height: 14),
              Text(
                'Şu an yeni bir duyuru yok.',
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                'Aksaklık, bakım ya da güncelleme olduğunda burada göreceksin.',
                textAlign: TextAlign.center,
                style: text.bodyMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
}

/// Kategoriye göre renk + ikon + etiket.
({Color color, IconData icon, String label}) _kindStyle(AnnouncementKind k) =>
    switch (k) {
      AnnouncementKind.uyari => (
          color: VigilantColors.primary,
          icon: Icons.error_outline_rounded,
          label: 'Uyarı',
        ),
      AnnouncementKind.dikkat => (
          color: VigilantColors.tertiaryContainer,
          icon: Icons.warning_amber_rounded,
          label: 'Dikkat',
        ),
      AnnouncementKind.bilgi => (
          color: VigilantColors.accentBlue,
          icon: Icons.info_outline_rounded,
          label: 'Bilgi',
        ),
    };

const _months = [
  'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz',
  'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
];

String _dateLabel(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard({required this.item});

  final AppAnnouncement item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = _kindStyle(item.kind);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Kategori rozeti.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: s.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(s.icon, size: 13, color: s.color),
                    const SizedBox(width: 5),
                    Text(s.label,
                        style: text.labelSmall?.copyWith(
                            color: s.color, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              const Spacer(),
              if (item.date != null)
                Text(_dateLabel(item.date!),
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
            ],
          ),
          if (item.title.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(item.title,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ],
          if (item.body.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(item.body,
                style: text.bodyMedium?.copyWith(
                    color: VigilantColors.onSurfaceVariant, height: 1.35)),
          ],
        ],
      ),
    );
  }
}
