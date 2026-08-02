import 'package:flutter/material.dart';

import '../data/models.dart';

/// "Vigilant Dark" tasarım sistemi — Stitch projesinden birebir porte edildi.
///
/// İlkeler:
/// - Koyu tema birinci sınıf: saf koyu zemin + tonal katmanlar + glassmorphism.
/// - Arayüzde emoji kullanılmaz; görsel dil ikon + tipografiden (Inter) gelir.
/// - Canlı renkler yalnızca durum iletişimi için: mavi (aksiyon),
///   yeşil (güvenli/başarılı), mercan (alarm/kritik).
abstract final class VigilantColors {
  static const background = Color(0xFF131315);
  static const surfaceContainerLowest = Color(0xFF0E0E10);
  static const surfaceContainerLow = Color(0xFF1B1B1D);
  static const surfaceContainer = Color(0xFF1F1F21);
  static const surfaceContainerHigh = Color(0xFF2A2A2C);
  static const surfaceContainerHighest = Color(0xFF353437);
  static const surfaceVariant = Color(0xFF353437);
  static const surfaceBright = Color(0xFF39393B);

  static const onSurface = Color(0xFFE4E2E4);
  static const onSurfaceVariant = Color(0xFFC1C6D7);
  static const outline = Color(0xFF8B90A0);
  static const outlineVariant = Color(0xFF414755);

  // Marka kırmızısı (StopAlert logosu): ana aksiyon/vurgu rengi.
  static const primary = Color(0xFFFF453A);
  static const onPrimary = Color(0xFFFFFFFF);
  static const primaryContainer = Color(0xFFC1170F);
  static const inversePrimary = Color(0xFF8F0E08);

  static const secondary = Color(0xFF53E16F);
  static const secondaryContainer = Color(0xFF05B046);

  // Uyarı vurguları: markanın kırmızısıyla çakışmasın diye amber.
  static const tertiary = Color(0xFFFFD8A8);
  static const tertiaryContainer = Color(0xFFFFB74D);

  static const error = Color(0xFFFFB4AB);

  /// Tasarımda düz aksiyon butonlarında kullanılan canlı iOS mavisi.
  static const accentBlue = Color(0xFF007AFF);
}

abstract final class AppTheme {
  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: VigilantColors.primary,
      onPrimary: VigilantColors.onPrimary,
      primaryContainer: VigilantColors.primaryContainer,
      onPrimaryContainer: Color(0xFFFFDAD6),
      inversePrimary: VigilantColors.inversePrimary,
      secondary: VigilantColors.secondary,
      onSecondary: Color(0xFF003911),
      secondaryContainer: VigilantColors.secondaryContainer,
      onSecondaryContainer: Color(0xFF003A11),
      tertiary: VigilantColors.tertiary,
      onTertiary: Color(0xFF690003),
      tertiaryContainer: VigilantColors.tertiaryContainer,
      onTertiaryContainer: Color(0xFF5C0002),
      error: VigilantColors.error,
      onError: Color(0xFF690005),
      errorContainer: Color(0xFF93000A),
      onErrorContainer: Color(0xFFFFDAD6),
      surface: VigilantColors.background,
      onSurface: VigilantColors.onSurface,
      onSurfaceVariant: VigilantColors.onSurfaceVariant,
      surfaceDim: VigilantColors.background,
      surfaceBright: VigilantColors.surfaceBright,
      surfaceContainerLowest: VigilantColors.surfaceContainerLowest,
      surfaceContainerLow: VigilantColors.surfaceContainerLow,
      surfaceContainer: VigilantColors.surfaceContainer,
      surfaceContainerHigh: VigilantColors.surfaceContainerHigh,
      surfaceContainerHighest: VigilantColors.surfaceContainerHighest,
      outline: VigilantColors.outline,
      outlineVariant: VigilantColors.outlineVariant,
      inverseSurface: Color(0xFFE4E2E4),
      onInverseSurface: Color(0xFF303032),
      surfaceTint: VigilantColors.primary,
      shadow: Colors.black,
      scrim: Colors.black,
    );

    final textTheme = _interTextTheme();

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: VigilantColors.background,
      fontFamily: 'Inter',
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: VigilantColors.onSurface,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: VigilantColors.onSurface,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? VigilantColors.accentBlue
              : VigilantColors.surfaceContainerHighest,
        ),
      ),
    );
  }

  /// Vigilant Dark tipografi ölçeği (Stitch design.md ile birebir).
  static TextTheme _interTextTheme() {
    const base = TextStyle(
      fontFamily: 'Inter',
      color: VigilantColors.onSurface,
    );
    return TextTheme(
      // headline-lg 32/40 700 -0.02em
      headlineLarge: base.copyWith(
        fontSize: 32,
        height: 40 / 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.64,
      ),
      // headline-lg-mobile 28/36 700
      headlineMedium: base.copyWith(
        fontSize: 28,
        height: 36 / 28,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.56,
      ),
      // headline-md 24/32 600
      headlineSmall: base.copyWith(
        fontSize: 24,
        height: 32 / 24,
        fontWeight: FontWeight.w600,
      ),
      // body-lg 18/28 400
      bodyLarge: base.copyWith(fontSize: 18, height: 28 / 18),
      // body-md 16/24 400
      bodyMedium: base.copyWith(fontSize: 16, height: 24 / 16),
      bodySmall: base.copyWith(
        fontSize: 14,
        height: 20 / 14,
        color: VigilantColors.onSurfaceVariant,
      ),
      // label-md 14/20 600
      labelLarge: base.copyWith(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w600,
      ),
      // label-sm 12/16 500
      labelMedium: base.copyWith(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: base.copyWith(
        fontSize: 10,
        height: 14 / 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );
  }
}

/// Hat türü başına ikon eşlemesi (emoji yerine Material ikonları).
IconData lineTypeIcon(LineType type) => switch (type) {
      LineType.marmaray => Icons.directions_railway_filled,
      LineType.metro => Icons.subway_outlined,
      LineType.tram => Icons.tram_outlined,
      LineType.funicular => Icons.stairs_outlined,
      LineType.cableCar => Icons.airline_seat_recline_extra_outlined,
      LineType.ferry => Icons.directions_boat_outlined,
      LineType.bus => Icons.directions_bus_filled_outlined,
      LineType.metrobus => Icons.airport_shuttle_rounded,
    };

/// "#RRGGBB" — platform katmanlarına renk taşımak için (iOS Live Activity,
/// Android ana ekran widget'ı).
String colorHex(Color c) {
  int ch(double v) => (v * 255).round().clamp(0, 255);
  String h(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${h(ch(c.r))}${h(ch(c.g))}${h(ch(c.b))}';
}

/// Hat türü başına vurgu rengi (tasarımdaki Hızlı Başlat çipleri ile uyumlu:
/// Marmaray mercan, metro mavi, otobüs/metrobüs yeşil).
Color lineTypeColor(LineType type) => switch (type) {
      LineType.marmaray => VigilantColors.tertiaryContainer,
      LineType.metro => VigilantColors.primary,
      LineType.tram => VigilantColors.tertiary,
      LineType.funicular => VigilantColors.onSurfaceVariant,
      LineType.cableCar => VigilantColors.onSurfaceVariant,
      LineType.ferry => VigilantColors.primaryContainer,
      LineType.bus => VigilantColors.secondary,
      LineType.metrobus => VigilantColors.accentBlue,
    };
