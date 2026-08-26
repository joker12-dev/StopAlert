// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get navHome => 'Accueil';

  @override
  String get navLines => 'Lignes';

  @override
  String get navStops => 'Arrêts';

  @override
  String get navFavorites => 'Favoris';

  @override
  String get navProfile => 'Profil';

  @override
  String get homeSearchTitle => 'Où descendez-vous ?';

  @override
  String get homeSearchHint => 'Saisissez l\'arrêt ou la ligne où descendre...';

  @override
  String get homeCurrentLocation => 'Position actuelle : ';

  @override
  String get homeYourLocation => 'Votre position';

  @override
  String get homeNearbyStops => 'Arrêts à proximité';

  @override
  String get homeStartAlarm => 'Démarrer l\'alarme';

  @override
  String get stopBadge => 'ARRÊT';

  @override
  String get homeNearbyError => 'Impossible de charger les arrêts à proximité.';

  @override
  String get homeLocationOff =>
      'Localisation désactivée — autorisez la localisation pour voir les arrêts proches.';

  @override
  String get homeFavoriteRoutes => 'Trajets favoris';

  @override
  String get seeAll => 'Tout';

  @override
  String get tipMorning =>
      'L\'affluence du matin a commencé ; réglez l\'alarme pour votre arrêt maintenant.';

  @override
  String get tipEvening =>
      'Les soirées sont chargées ; réglez votre alarme tôt.';

  @override
  String get tipLateNight =>
      'Ne manquez pas les derniers trajets ; réglez une alarme pour votre arrêt.';

  @override
  String get tipDefault =>
      'Au cas où vous vous assoupiriez — réglez une alarme pour votre arrêt.';

  @override
  String get categoryBus => 'Bus';

  @override
  String get categoryMetrobus => 'Métrobus';

  @override
  String get categoryMarmaray => 'Marmaray';

  @override
  String get categoryMetro => 'Métro';

  @override
  String get categoryFerry => 'Ferry';

  @override
  String get actionUnderstood => 'Compris';

  @override
  String get actionCancel => 'Annuler';

  @override
  String get actionSave => 'Enregistrer';

  @override
  String get actionContinue => 'Continuer';

  @override
  String get actionClose => 'Fermer';

  @override
  String get settingsTitle => 'Paramètres';

  @override
  String get appSection => 'APPLICATION';

  @override
  String get language => 'Langue';

  @override
  String get languageSubtitle => 'Langue d\'affichage de l\'application';

  @override
  String get systemDefault => 'Langue du système';
}
