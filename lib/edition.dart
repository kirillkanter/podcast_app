/// Версия сборки: публичная (RuStore — с рекламой, без синхронизации)
/// или личная (без рекламы, с синхронизацией).
///
/// Задаётся при сборке: `flutter build apk --dart-define=BCASTER_EDITION=public`.
/// Без флага — личная (так собираются тесты и программа для Windows).
/// Значения — константы: код, который в версии не нужен, компилятор
/// выбрасывает из сборки.
library;

abstract final class Edition {
  static const name = String.fromEnvironment('BCASTER_EDITION', defaultValue: 'personal');

  /// Публичная версия для RuStore.
  static const isPublic = name == 'public';

  /// Синхронизация и вход в аккаунт.
  static const hasSync = !isPublic;

  /// Реклама Рекламной сети Яндекса.
  static const hasAds = isPublic;
}
