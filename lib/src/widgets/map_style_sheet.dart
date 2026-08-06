import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/map_style.dart';

/// Harita görünümü seçici (Gece / Canlı / Uydu / Sade).
///
/// Seçim Ayarlar'a KALICI yazılır ve tüm haritalarda geçerli olur — kullanıcı
/// bir ekranda uyduya geçip ötekinde koyu haritayla karşılaşmasın.
///
/// Ortak: yakındaki duraklar haritası ve canlı takip aynı sayfayı açar.
/// Dönen değer, stil değişip değişmediğidir (çağıran ekran kendini yeniler).
Future<bool> pickMapStyle(BuildContext context, WidgetRef ref) async {
  Haptics.light();
  final chosen = await showModalBottomSheet<MapTileStyle>(
    context: context,
    backgroundColor: VigilantColors.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      final t = Theme.of(context).textTheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: VigilantColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text('Harita Görünümü',
                  style: t.headlineSmall?.copyWith(fontSize: 20)),
              const SizedBox(height: 12),
              for (final s in MapTileStyle.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    switch (s) {
                      MapTileStyle.gece => Icons.dark_mode_rounded,
                      MapTileStyle.canli => Icons.palette_rounded,
                      MapTileStyle.uydu => Icons.satellite_alt_rounded,
                      MapTileStyle.sade => Icons.light_mode_rounded,
                    },
                    color: AppMapStyle.style == s
                        ? VigilantColors.primary
                        : VigilantColors.onSurfaceVariant,
                  ),
                  title: Text(s.label, style: t.bodyMedium),
                  trailing: AppMapStyle.style == s
                      ? const Icon(Icons.check_rounded,
                          color: VigilantColors.primary)
                      : null,
                  onTap: () => Navigator.of(context).pop(s),
                ),
            ],
          ),
        ),
      );
    },
  );
  if (chosen == null) return false;
  Haptics.selection();
  AppMapStyle.style = chosen;
  await ref.read(settingsProvider.notifier).setMapStyle(chosen.name);
  return true;
}
