import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../state/locale_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';

/// Dil seçimi — "Sistem dili" + desteklenen diller (endonim adlarıyla).
///
/// Seçim [localeControllerProvider] üzerinden cihazda saklanır ve tüm uygulamaya
/// anında yansır. "Sistem dili" kaydı siler → cihaz dili neyse o kullanılır.
class LanguageScreen extends ConsumerWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final current = ref.watch(localeControllerProvider).valueOrNull;
    final currentCode = current?.languageCode;

    void pick(Locale? locale) {
      Haptics.selection();
      ref.read(localeControllerProvider.notifier).setLocale(locale);
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(l.language),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, AppInsets.pageBottom(context) + 16),
        children: [
          _LangTile(
            title: l.systemDefault,
            selected: currentCode == null,
            onTap: () => pick(null),
          ),
          const SizedBox(height: 8),
          for (final lang in LocaleController.supported) ...[
            _LangTile(
              title: lang.name,
              selected: currentCode == lang.code,
              onTap: () => pick(Locale(lang.code)),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _LangTile extends StatelessWidget {
  const _LangTile({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected
          ? VigilantColors.primary.withValues(alpha: 0.14)
          : VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(title,
                    style: text.bodyLarge?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? VigilantColors.primary
                            : VigilantColors.onSurface)),
              ),
              if (selected)
                const Icon(Icons.check_circle_rounded,
                    color: VigilantColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}
