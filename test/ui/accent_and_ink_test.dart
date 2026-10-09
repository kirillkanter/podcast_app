import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/ui/books/reader/reader_style.dart';
import 'package:podcast_app/ui/nav_ink.dart';
import 'package:podcast_app/ui/theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  group('цвет акцента', () {
    test('акцент меняет кнопки, ссылки, полосы и переключатели', () {
      final violet = Accent.from('violet');
      final dark = buildTheme(Brightness.dark, violet);
      final c = dark.extension<BcColors>()!;
      expect((c.fill, c.ink, c.bar), (violet.dark, violet.dark, violet.dark));
      expect(dark.colorScheme.primary, violet.dark);
      expect(dark.sliderTheme.activeTrackColor, violet.dark);
      expect(dark.switchTheme.trackColor!.resolve({WidgetState.selected}), violet.dark);

      final light = buildTheme(Brightness.light, violet).extension<BcColors>()!;
      expect((light.fill, light.ink), (violet.light, violet.lightInk));
      // Фон и текст от акцента не зависят.
      expect((light.bg, light.text), (BcColors.light.bg, BcColors.light.text));
    });

    test('по умолчанию — салатовый, неизвестный — тоже', () {
      expect(Accent.from(null).id, 'lime');
      expect(Accent.from('nope').id, 'lime');
      expect(buildTheme(Brightness.dark).extension<BcColors>()!.fill, const Color(0xFFC5F52E));
    });

    test('все акценты читаются', () {
      for (final a in Accent.all) {
        expect(_contrast(a.dark, BcColors.dark.onFill), greaterThanOrEqualTo(4.5), reason: '${a.label}: текст на кнопке');
        expect(_contrast(a.dark, BcColors.dark.bg), greaterThanOrEqualTo(4.5), reason: '${a.label}: ссылка на тёмном');
        expect(_contrast(a.light, Colors.white), greaterThanOrEqualTo(4.5), reason: '${a.label}: текст на кнопке');
        expect(_contrast(a.lightInk, BcColors.light.bg), greaterThanOrEqualTo(4.5), reason: '${a.label}: ссылка на светлом');
      }
    });
  });

  test('листание кнопками громкости: включено по умолчанию, выключение сохраняется', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect((await ReaderStyle.load(db)).volumeKeys, isTrue);
    await const ReaderStyle().copyWith(volumeKeys: false).save(db);
    expect((await ReaderStyle.load(db)).volumeKeys, isFalse);
  });

  testWidgets('плитка: после возврата с другого экрана — без следа нажатия, содержимое то же', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: Scaffold(
        body: Center(
          child: NavInkWell(
            onTap: () => nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Подкаст')))),
            child: const SizedBox(width: 120, height: 120, child: _Counter()),
          ),
        ),
      ),
    ));
    final before = tester.state<_CounterState>(find.byType(_Counter));
    await tester.tap(find.byType(NavInkWell));
    await tester.pumpAndSettle();
    expect(find.text('Подкаст'), findsOneWidget);

    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // Ни всплеска, ни подсветки на плитке.
    final ink = Material.of(tester.element(find.byType(InkWell))) as dynamic;
    expect((ink.debugInkFeatures as List?) ?? const [], isEmpty);
    // Содержимое не пересоздавалось.
    expect(tester.state<_CounterState>(find.byType(_Counter)), same(before));
    await tester.pumpAndSettle();
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
}
