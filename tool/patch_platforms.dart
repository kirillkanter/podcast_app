// Правит платформенные файлы после `flutter create`.
//
// Папки android/ и windows/ не хранятся в репозитории: их генерирует
// `flutter create` при сборке. Этот скрипт добавляет то, чего нет в шаблоне:
// - разрешение на интернет (в шаблоне оно есть только для отладочной сборки);
// - загрузку по http:// (Android 9+ по умолчанию разрешает только https,
//   а многие старые фиды и аудиофайлы до сих пор отдаются по http);
// - название приложения «Подкасты»;
// - фоновое воспроизведение через audio_service: разрешения, сервис,
//   приёмник медиа-кнопок и AudioServiceActivity вместо MainActivity.
//
// Скрипт можно запускать повторно: уже внесённые правки не дублируются.
// Запуск: dart run tool/patch_platforms.dart
import 'dart:io';

const _permissions = [
  'android.permission.INTERNET',
  'android.permission.WAKE_LOCK',
  'android.permission.FOREGROUND_SERVICE',
  'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
];

const _audioServiceComponents = '''
        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true"
            tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>

        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true"
            tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON" />
            </intent-filter>
        </receiver>
''';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stdout.writeln('Нет android/ — пропускаю Android.');
    return;
  }

  var xml = manifest.readAsStringSync();

  if (!xml.contains('xmlns:tools=')) {
    xml = xml.replaceFirst('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ');
  }

  for (final permission in _permissions) {
    if (!xml.contains('"$permission"')) {
      xml = xml.replaceFirst(
        '<application',
        '<uses-permission android:name="$permission"/>\n    <application',
      );
    }
  }

  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }

  xml = xml.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Подкасты"');

  // audio_service требует свою Activity, чтобы фоновый сервис и интерфейс
  // работали с одним и тем же движком Flutter.
  xml = xml.replaceFirst(
    'android:name=".MainActivity"',
    'android:name="com.ryanheise.audioservice.AudioServiceActivity"',
  );

  if (!xml.contains('com.ryanheise.audioservice.AudioService"')) {
    xml = xml.replaceFirst('</application>', '$_audioServiceComponents    </application>');
  }

  manifest.writeAsStringSync(xml);
  stdout.writeln('AndroidManifest.xml обновлён.');
}
