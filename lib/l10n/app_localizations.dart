import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_tr.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('tr')
  ];

  /// Bottom navigation: home tab
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navLines.
  ///
  /// In en, this message translates to:
  /// **'Lines'**
  String get navLines;

  /// No description provided for @navStops.
  ///
  /// In en, this message translates to:
  /// **'Stops'**
  String get navStops;

  /// No description provided for @navFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get navFavorites;

  /// No description provided for @navProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get navProfile;

  /// No description provided for @homeSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Where are you getting off?'**
  String get homeSearchTitle;

  /// No description provided for @homeSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Type the stop or line you\'ll get off at...'**
  String get homeSearchHint;

  /// No description provided for @homeCurrentLocation.
  ///
  /// In en, this message translates to:
  /// **'Current Location: '**
  String get homeCurrentLocation;

  /// No description provided for @homeYourLocation.
  ///
  /// In en, this message translates to:
  /// **'Your location'**
  String get homeYourLocation;

  /// No description provided for @homeNearbyStops.
  ///
  /// In en, this message translates to:
  /// **'Nearby Stops'**
  String get homeNearbyStops;

  /// No description provided for @homeStartAlarm.
  ///
  /// In en, this message translates to:
  /// **'Start Alarm'**
  String get homeStartAlarm;

  /// No description provided for @stopBadge.
  ///
  /// In en, this message translates to:
  /// **'STOP'**
  String get stopBadge;

  /// No description provided for @homeNearbyError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load nearby stops.'**
  String get homeNearbyError;

  /// No description provided for @homeLocationOff.
  ///
  /// In en, this message translates to:
  /// **'Location off — grant location permission to see nearby stops.'**
  String get homeLocationOff;

  /// No description provided for @homeFavoriteRoutes.
  ///
  /// In en, this message translates to:
  /// **'Favorite Routes'**
  String get homeFavoriteRoutes;

  /// No description provided for @seeAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get seeAll;

  /// No description provided for @tipMorning.
  ///
  /// In en, this message translates to:
  /// **'Morning rush has started; set your alarm for your stop now.'**
  String get tipMorning;

  /// No description provided for @tipEvening.
  ///
  /// In en, this message translates to:
  /// **'Evenings are busy; set your alarm early.'**
  String get tipEvening;

  /// No description provided for @tipLateNight.
  ///
  /// In en, this message translates to:
  /// **'Don\'t miss the last trips; set an alarm for your stop.'**
  String get tipLateNight;

  /// No description provided for @tipDefault.
  ///
  /// In en, this message translates to:
  /// **'In case you doze off — set an alarm for your stop.'**
  String get tipDefault;

  /// No description provided for @categoryBus.
  ///
  /// In en, this message translates to:
  /// **'Bus'**
  String get categoryBus;

  /// No description provided for @categoryMetrobus.
  ///
  /// In en, this message translates to:
  /// **'Metrobus'**
  String get categoryMetrobus;

  /// No description provided for @categoryMarmaray.
  ///
  /// In en, this message translates to:
  /// **'Marmaray'**
  String get categoryMarmaray;

  /// No description provided for @categoryMetro.
  ///
  /// In en, this message translates to:
  /// **'Metro'**
  String get categoryMetro;

  /// No description provided for @categoryFerry.
  ///
  /// In en, this message translates to:
  /// **'Ferry'**
  String get categoryFerry;

  /// No description provided for @actionUnderstood.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get actionUnderstood;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @actionContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get actionContinue;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @appSection.
  ///
  /// In en, this message translates to:
  /// **'APP'**
  String get appSection;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'App display language'**
  String get languageSubtitle;

  /// No description provided for @systemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get systemDefault;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en', 'es', 'fr', 'tr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'tr':
      return AppLocalizationsTr();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
