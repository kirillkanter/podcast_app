/// Реклама Рекламной сети Яндекса — только в публичной версии на Android.
///
/// Мягкие встроенные баннеры: в библиотеке и в поиске, не больше одного на
/// экране; в плеере, читалке и на странице книги рекламы нет.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:yandex_mobileads/mobile_ads.dart';

import '../data/db/database.dart';
import '../edition.dart';

/// Места для рекламы и их блоки в кабинете РСЯ. Пока — тестовые блоки
/// Яндекса; настоящие идентификаторы вида R-M-XXXXXX-Y подставить сюда.
enum AdPlacement {
  library('demo-banner-yandex'),
  discover('demo-banner-yandex');

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

/// Встроенный баннер: [width] — доступная ширина, высоту выбирает SDK.
class InlineBanner {
  InlineBanner(this.placement, {required int width, int maxHeight = 260})
      : _ad = BannerAd(adSize: BannerAdSize.inline(width: width, maxHeight: maxHeight));

  final AdPlacement placement;
  final BannerAd _ad;
  final loaded = ValueNotifier<bool>(false);
  StreamSubscription<Object?>? _sub;

  void load() {
    _sub = _ad.loadStateStream.listen((state) {
      if (state is BannerAdLoadStateLoaded) loaded.value = true;
    });
    _ad.load(AdRequest(adUnitId: placement.adUnitId));
  }

  Widget widget() => AdWidget(bannerAd: _ad);

  Future<void> dispose() async {
    await _sub?.cancel();
    loaded.dispose();
    try {
      await _ad.destroy();
    } catch (_) {}
  }
}
