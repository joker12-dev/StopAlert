import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/recent_search.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';

/// Son aramaların TAMAMI.
///
/// Arama ekranındaki bölüm yalnızca son üçünü gösteriyor; orası ekranın
/// girişi, arşivi değil. Daha eskisini arayan buraya gelir.
class RecentSearchesScreen extends ConsumerWidget {
  const RecentSearchesScreen({super.key, required this.onOpen});

  /// Bir kayda dokunulduğunda çalışacak açma işlemi. Çözümleme mantığı
  /// (hangi şehir, duraklı mı duraksız mı) arama ekranında duruyor;
  /// burada kopyalanmaz.
  final void Function(RecentSearch entry) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final recents =
        ref.watch(recentSearchesProvider).valueOrNull ?? const <RecentSearch>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Son Aramalar'),
        actions: [
          if (recents.isNotEmpty)
            TextButton(
              onPressed: () async {
                Haptics.light();
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: VigilantColors.surfaceContainer,
                    title: const Text('Geçmişi temizle'),
                    content: const Text(
                        'Kayıtlı tüm son aramalar silinecek. Emin misin?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Vazgeç'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Temizle',
                            style: TextStyle(color: VigilantColors.primary)),
                      ),
                    ],
                  ),
                );
                if (ok ?? false) {
                  await ref.read(recentSearchesProvider.notifier).clear();
                }
              },
              child: Text('Temizle',
                  style:
                      text.labelMedium?.copyWith(color: VigilantColors.primary)),
            ),
        ],
      ),
      body: recents.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Henüz arama yok — seçtiğin hat ve duraklar burada birikir.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                ),
              ),
            )
          : ListView.separated(
              padding:
                  EdgeInsets.fromLTRB(20, 16, 20, AppInsets.listBottom(context)),
              itemCount: recents.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final e = recents[i];
                return _RecentRow(
                  entry: e,
                  onTap: () {
                    // Önce bu sayfayı kapat: kullanıcı geri geldiğinde arama
                    // ekranına dönsün, üst üste iki sayfa birikmesin.
                    Navigator.of(context).pop();
                    onOpen(e);
                  },
                );
              },
            ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.entry, required this.onTap});

  final RecentSearch entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(lineTypeIcon(entry.lineType),
                    size: 20, color: VigilantColors.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.stopName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall,
                    ),
                    if (entry.lineCode.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.lineCode,
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.north_east_rounded,
                  size: 18, color: VigilantColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
