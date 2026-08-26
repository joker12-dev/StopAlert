// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get navHome => 'Inicio';

  @override
  String get navLines => 'Líneas';

  @override
  String get navStops => 'Paradas';

  @override
  String get navFavorites => 'Favoritos';

  @override
  String get navProfile => 'Perfil';

  @override
  String get homeSearchTitle => '¿Dónde te bajas?';

  @override
  String get homeSearchHint => 'Escribe la parada o línea donde te bajas...';

  @override
  String get homeCurrentLocation => 'Ubicación actual: ';

  @override
  String get homeYourLocation => 'Tu ubicación';

  @override
  String get homeNearbyStops => 'Paradas cercanas';

  @override
  String get homeStartAlarm => 'Iniciar alarma';

  @override
  String get stopBadge => 'PARADA';

  @override
  String get homeNearbyError => 'No se pudieron cargar las paradas cercanas.';

  @override
  String get homeLocationOff =>
      'Ubicación desactivada — concede el permiso de ubicación para ver las paradas cercanas.';

  @override
  String get homeFavoriteRoutes => 'Rutas favoritas';

  @override
  String get seeAll => 'Todas';

  @override
  String get mostUsedLines => 'Líneas más usadas';

  @override
  String get mostUsedStops => 'Paradas más frecuentes';

  @override
  String get tipMorning =>
      'Ha empezado la hora punta de la mañana; pon la alarma para tu parada ahora.';

  @override
  String get tipEvening =>
      'Las tardes están concurridas; pon tu alarma temprano.';

  @override
  String get tipLateNight =>
      'No te pierdas los últimos viajes; pon una alarma para tu parada.';

  @override
  String get tipDefault =>
      'Por si te quedas dormido — pon una alarma para tu parada.';

  @override
  String get categoryBus => 'Autobús';

  @override
  String get categoryMetrobus => 'Metrobús';

  @override
  String get categoryMarmaray => 'Marmaray';

  @override
  String get categoryMetro => 'Metro';

  @override
  String get categoryFerry => 'Ferry';

  @override
  String get actionUnderstood => 'Entendido';

  @override
  String get actionCancel => 'Cancelar';

  @override
  String get actionSave => 'Guardar';

  @override
  String get actionContinue => 'Continuar';

  @override
  String get actionClose => 'Cerrar';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get appSection => 'APLICACIÓN';

  @override
  String get language => 'Idioma';

  @override
  String get languageSubtitle => 'Idioma de la aplicación';

  @override
  String get systemDefault => 'Idioma del sistema';
}
