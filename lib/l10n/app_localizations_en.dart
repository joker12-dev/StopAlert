// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get navHome => 'Home';

  @override
  String get navLines => 'Lines';

  @override
  String get navStops => 'Stops';

  @override
  String get navFavorites => 'Favorites';

  @override
  String get navProfile => 'Profile';

  @override
  String get homeSearchTitle => 'Where are you getting off?';

  @override
  String get homeSearchHint => 'Type the stop or line you\'ll get off at...';

  @override
  String get homeCurrentLocation => 'Current Location: ';

  @override
  String get homeYourLocation => 'Your location';

  @override
  String get homeNearbyStops => 'Nearby Stops';

  @override
  String get homeStartAlarm => 'Start Alarm';

  @override
  String get stopBadge => 'STOP';

  @override
  String get homeNearbyError => 'Couldn\'t load nearby stops.';

  @override
  String get homeLocationOff =>
      'Location off — grant location permission to see nearby stops.';

  @override
  String get homeFavoriteRoutes => 'Favorite Routes';

  @override
  String get seeAll => 'All';

  @override
  String get mostUsedLines => 'Most Used Lines';

  @override
  String get mostUsedStops => 'Most Frequent Stops';

  @override
  String get tipMorning =>
      'Morning rush has started; set your alarm for your stop now.';

  @override
  String get tipEvening => 'Evenings are busy; set your alarm early.';

  @override
  String get tipLateNight =>
      'Don\'t miss the last trips; set an alarm for your stop.';

  @override
  String get tipDefault => 'In case you doze off — set an alarm for your stop.';

  @override
  String get categoryBus => 'Bus';

  @override
  String get categoryMetrobus => 'Metrobus';

  @override
  String get categoryMarmaray => 'Marmaray';

  @override
  String get categoryMetro => 'Metro';

  @override
  String get categoryTram => 'Tram';

  @override
  String get categoryFerry => 'Ferry';

  @override
  String get actionUnderstood => 'Got it';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionSave => 'Save';

  @override
  String get actionContinue => 'Continue';

  @override
  String get actionClose => 'Close';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get appSection => 'APP';

  @override
  String get language => 'Language';

  @override
  String get languageSubtitle => 'App display language';

  @override
  String get systemDefault => 'System default';
}
