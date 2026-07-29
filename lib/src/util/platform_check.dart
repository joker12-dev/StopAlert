/// Platforma göre koşullu içe aktarım:
/// - Web: stub (false)
/// - IO platformları: Platform.isAndroid
library;

export 'platform_check_stub.dart' if (dart.library.io) 'platform_check_io.dart';
