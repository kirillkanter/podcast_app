/// Реклама Рекламной сети Яндекса — только в публичной версии на Android.
///
/// Мягкие встроенные баннеры высотой до 100 точек, в оформлении темы
/// приложения: в библиотеке, в поиске и в длинных списках каталога, не больше
/// одного на экране; в плеере, читалке и на странице книги рекламы нет.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:yandex_mobileads/mobile_ads.dart';

import '../data/db/database.dart';
import '../edition.dart';

/// Места для рекламы и их блоки в кабинете РСЯ. Пока — тестовые блоки
/// Яндекса; настоящие идентификаторы вида R-M-XXXXXX-Y подставить сюда.
enum AdPlacement {
  library('demo-banner-yandex'),
  discover('demo-banner-yandex'),

  /// Ниже по странице поиска, между рубриками.
  discoverMore('demo-banner-yandex'),

  /// В результатах поиска и в длинных списках каталога.
  searchResults('demo-banner-yandex');

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
  InlineBanner(this.placement, {required int width, required this.dark, int maxHeight = 100})
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
