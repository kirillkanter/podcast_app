/// Реклама Рекламной сети Яндекса — только в публичной версии на Android.
///
/// Небольшой баннер в библиотеке и в поиске (по одному, в оформлении темы
/// приложения) и изредка заставка при возврате в приложение. В плеере,
/// читалке и на странице книги рекламы нет.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Brightness;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:yandex_mobileads/mobile_ads.dart';

import '../data/db/database.dart';
import '../edition.dart';

/// Места для рекламы и их блоки в кабинете РСЯ. Для проверки без показа
/// настоящих объявлений можно временно подставить тестовые блоки Яндекса:
/// demo-banner-yandex и demo-appopenad-yandex.
enum AdPlacement {
  /// Баннер в библиотеке после новых выпусков.
  library('R-M-20237517-1'),

  /// Баннер в поиске после «Популярного».
  discover('R-M-20237517-2'),

  /// Заставка при возврате в приложение.
  appOpen('R-M-20237517-3');

  const AdPlacement(this.adUnitId);
  final String adUnitId;
}

abstract final class AdSettings {
  /// 'false' — персональная реклама выключена.
  static const personal = 'ads.personal';
}

/// Реклама показывается: публичная версия, Android, SDK запустился.
final adsReady = ValueNotifier<bool>(false);

bool get adsSupported => Edition.hasAds && !kIsWeb && Platform.isAndroid;

/// Запустить SDK. Согласие на персональную рекламу передаётся при каждом
/// запуске, до инициализации.
Future<void> initAds(AppDatabase db) async {
  if (!adsSupported) return;
  try {
    final personal = await db.setting(AdSettings.personal) != 'false';
    await YandexAds.setUserConsent(personal);
    await YandexAds.initialize();
    adsReady.value = true;
  } catch (e) {
    debugPrint('Реклама не запустилась: $e');
  }
}

/// Включить или выключить персональную рекламу.
Future<void> setPersonalAds(AppDatabase db, bool on) async {
  await db.setSetting(AdSettings.personal, '$on');
  if (!adsSupported) return;
  try {
    await YandexAds.setUserConsent(on);
  } catch (_) {}
}

/// Встроенный баннер: [width] — доступная ширина, высоту выбирает SDK, но
/// не больше [maxHeight] — так приходят компактные объявления в строку.
///
/// У модуля Яндекса запрос уходит, только когда платформенный вид баннера
/// уже на экране: [AdWidget] ставится в дерево сразу после [load] (пока
/// объявления нет, он высотой в 1 точку), а карточка показывается, когда
/// [loaded] стал true.
class InlineBanner {
  InlineBanner(this.placement, {required int width, required this.dark, int maxHeight = 90})
      : _ad = BannerAd(adSize: BannerAdSize.inline(width: width, maxHeight: maxHeight));

  final AdPlacement placement;

  /// Тёмная тема приложения — просить у Яндекса объявление в тёмном оформлении.
  final bool dark;
  final BannerAd _ad;

  /// Вид баннера создан — [widget] можно ставить в дерево.
  final ready = ValueNotifier<bool>(false);

  /// Объявление загрузилось.
  final loaded = ValueNotifier<bool>(false);
  StreamSubscription<Object?>? _sub;

  Future<void> load() async {
    _sub = _ad.loadStateStream.listen((state) {
      if (state is BannerAdLoadStateLoaded) {
        loaded.value = true;
      } else if (state is BannerAdLoadStateError) {
        debugPrint('Реклама ${placement.name}: $state');
      }
    });
    try {
      await _ad.load(AdRequest(
        adUnitId: placement.adUnitId,
        preferredTheme: dark ? AdTheme.dark : AdTheme.light,
      ));
      ready.value = true;
    } catch (e) {
      debugPrint('Реклама ${placement.name}: $e');
    }
  }

  Widget widget() => AdWidget(bannerAd: _ad);

  Future<void> dispose() async {
    await _sub?.cancel();
    ready.dispose();
    loaded.dispose();
    try {
      await _ad.destroy();
    } catch (_) {}
  }
}

/// Заставка при возврате в приложение (App Open Ad). Только статичные
/// объявления с кнопкой закрытия — видео в этом формате Яндекс не показывает.
///
/// Редко и не мешая: только после [minBackground] в фоне, не чаще раза в
/// [minInterval], не раньше [minLaunches]-го открытия и никогда во время
/// воспроизведения (в том числе когда приложение открыли из уведомления
/// плеера). При холодном запуске не показывается.
class AppOpenAds {
  AppOpenAds(this._db, {required bool Function() isPlaying}) : _isPlaying = isPlaying;

  static const minBackground = Duration(minutes: 15);
  static const minInterval = Duration(hours: 4);
  static const minLaunches = 5;

  /// Загруженное объявление старше этого не показываем — грузим новое.
  static const _maxAge = Duration(hours: 3);
  static const _launchesKey = 'ads.launches';
  static const _shownKey = 'ads.appOpenShownAt';

  final AppDatabase _db;
  final bool Function() _isPlaying;
  AppLifecycleListener? _life;
  AppOpenAdLoader? _loader;
  AppOpenAd? _ad;
  DateTime? _loadedAt;
  DateTime? _pausedAt;
  bool _loading = false;
  bool _showing = false;

  void start() {
    if (!adsSupported || _life != null) return;
    _life = AppLifecycleListener(
      onPause: () => _pausedAt ??= DateTime.now(),
      onResume: () => unawaited(_onResume()),
    );
    unawaited(_bumpLaunches());
    if (adsReady.value) {
      unawaited(_preload());
    } else {
      void ready() {
        if (!adsReady.value) return;
        adsReady.removeListener(ready);
        unawaited(_preload());
      }

      adsReady.addListener(ready);
    }
  }

  Future<int> _bumpLaunches() async {
    final n = (int.tryParse(await _db.setting(_launchesKey) ?? '') ?? 0) + 1;
    await _db.setSetting(_launchesKey, '$n');
    return n;
  }

  Future<void> _preload() async {
    if (!adsReady.value || _loading) return;
    final age = _loadedAt == null ? null : DateTime.now().difference(_loadedAt!);
    if (_ad != null && age != null && age < _maxAge) return;
    _loading = true;
    try {
      final old = _ad;
      _ad = null;
      if (old != null) unawaited(old.destroy());
      final dark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
      _loader ??= AppOpenAdLoader();
      _ad = await _loader!.loadAd(
        adRequest: AdRequest(
          adUnitId: AdPlacement.appOpen.adUnitId,
          preferredTheme: dark ? AdTheme.dark : AdTheme.light,
        ),
      );
      _loadedAt = DateTime.now();
    } catch (e) {
      debugPrint('Заставка не загрузилась: $e');
    } finally {
      _loading = false;
    }
  }

  Future<void> _onResume() async {
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null || _showing || !adsReady.value) return;
    if (DateTime.now().difference(pausedAt) < minBackground) return;
    final launches = await _bumpLaunches();
    if (launches < minLaunches || _isPlaying()) {
      unawaited(_preload());
      return;
    }
    final last = int.tryParse(await _db.setting(_shownKey) ?? '') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - last < minInterval.inMilliseconds) return;
    final ad = _ad;
    final age = _loadedAt == null ? null : DateTime.now().difference(_loadedAt!);
    if (ad == null || age == null || age >= _maxAge) {
      unawaited(_preload());
      return;
    }
    _ad = null;
    _showing = true;
    void done() {
      _showing = false;
      unawaited(ad.destroy());
      unawaited(_preload());
    }

    try {
      await ad.setAdEventListener(
        eventListener: AppOpenAdEventListener(
          onAdShown: () => unawaited(_db.setSetting(_shownKey, '${DateTime.now().millisecondsSinceEpoch}')),
          onAdDismissed: done,
          onAdFailedToShow: (e) {
            debugPrint('Заставка не показалась: $e');
            done();
          },
        ),
      );
      await ad.show();
    } catch (e) {
      debugPrint('Заставка: $e');
      done();
    }
  }
}
