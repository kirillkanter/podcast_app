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
  'android.permission.POST_NOTIFICATIONS',
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
  _patchAndroid();
  _patchWindows();
}

const _windowsMarker = '# podcast_app: совместимость плагинов с новым MSVC';
const _windowsPatch = '''

$_windowsMarker
# Плагины на C++/WinRT (just_audio_windows, audio_service_win) собираются
# в C++17, где C++/WinRT подключает <experimental/coroutine>. MSVC 14.51+
# превращает это в ошибку STL1011; макрос возвращает прежнее поведение.
# Перевод плагинов на C++20 не подходит: их код не собирается в C++20.
foreach(plugin \${FLUTTER_PLUGIN_LIST})
  if(TARGET \${plugin}_plugin)
    target_compile_definitions(\${plugin}_plugin PRIVATE _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
  endif()
endforeach()
''';

void _patchWindows() {
  final cmake = File('windows/CMakeLists.txt');
  if (!cmake.existsSync()) {
    stdout.writeln('Нет windows/ — пропускаю Windows.');
    return;
  }
  final text = cmake.readAsStringSync();
  if (text.contains(_windowsMarker)) return;
  cmake.writeAsStringSync(text + _windowsPatch);
  stdout.writeln('windows/CMakeLists.txt обновлён.');
}

void _patchAndroid() {
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
