// Правит платформенные файлы после `flutter create`.
//
// Папки android/ и windows/ не хранятся в репозитории: их генерирует
// `flutter create` при сборке. Этот скрипт добавляет то, чего нет в шаблоне:
// - разрешение на интернет (в шаблоне оно есть только для отладочной сборки);
// - загрузку по http:// (Android 9+ по умолчанию разрешает только https,
//   а многие старые фиды и аудиофайлы до сих пор отдаются по http);
// - название приложения «Подкасты».
//
// Запуск: dart run tool/patch_platforms.dart
import 'dart:io';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stdout.writeln('Нет android/ — пропускаю Android.');
    return;
  }

  var xml = manifest.readAsStringSync();

  if (!xml.contains('android.permission.INTERNET')) {
    xml = xml.replaceFirst(
      '<application',
      '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
    );
  }

  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }

  xml = xml.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Подкасты"');

  manifest.writeAsStringSync(xml);
  stdout.writeln('AndroidManifest.xml обновлён.');
}
