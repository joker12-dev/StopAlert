// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get navHome => 'الرئيسية';

  @override
  String get navLines => 'الخطوط';

  @override
  String get navStops => 'المحطات';

  @override
  String get navFavorites => 'المفضلة';

  @override
  String get navProfile => 'الملف الشخصي';

  @override
  String get homeSearchTitle => 'أين ستنزل؟';

  @override
  String get homeSearchHint => 'اكتب المحطة أو الخط الذي ستنزل عنده...';

  @override
  String get homeCurrentLocation => 'الموقع الحالي: ';

  @override
  String get homeYourLocation => 'موقعك';

  @override
  String get homeNearbyStops => 'المحطات القريبة';

  @override
  String get homeStartAlarm => 'بدء المنبه';

  @override
  String get stopBadge => 'محطة';

  @override
  String get homeNearbyError => 'تعذّر تحميل المحطات القريبة.';

  @override
  String get homeLocationOff =>
      'الموقع مُعطّل — امنح إذن الموقع لرؤية المحطات القريبة.';

  @override
  String get homeFavoriteRoutes => 'المسارات المفضلة';

  @override
  String get seeAll => 'الكل';

  @override
  String get tipMorning => 'بدأ ازدحام الصباح؛ اضبط المنبه لمحطتك الآن.';

  @override
  String get tipEvening => 'المساء مزدحم؛ اضبط منبهك مبكرًا.';

  @override
  String get tipLateNight => 'لا تفوّت آخر الرحلات؛ اضبط منبهًا لمحطتك.';

  @override
  String get tipDefault => 'تحسّبًا للنعاس — اضبط منبهًا لمحطتك.';

  @override
  String get categoryBus => 'حافلة';

  @override
  String get categoryMetrobus => 'مترو باص';

  @override
  String get categoryMarmaray => 'مرمراي';

  @override
  String get categoryMetro => 'مترو';

  @override
  String get categoryFerry => 'عبّارة';

  @override
  String get actionUnderstood => 'حسنًا';

  @override
  String get actionCancel => 'إلغاء';

  @override
  String get actionSave => 'حفظ';

  @override
  String get actionContinue => 'متابعة';

  @override
  String get actionClose => 'إغلاق';

  @override
  String get settingsTitle => 'الإعدادات';

  @override
  String get appSection => 'التطبيق';

  @override
  String get language => 'اللغة';

  @override
  String get languageSubtitle => 'لغة عرض التطبيق';

  @override
  String get systemDefault => 'لغة النظام';
}
