import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/ui/marquee.dart';

void main() {
  Widget app(String text, {required bool running, double width = 120}) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: Marquee(text: text, running: running, style: const TextStyle(fontSize: 14)),
            ),
          ),
        ),
      );

  const long = 'Очень длинное название эпизода, которое не помещается в строку';

  testWidgets('длинное название бежит, пока играет, и возвращается на паузе', (tester) async {
    await tester.pumpWidget(app(long, running: false));
    expect(find.text(long), findsOneWidget, reason: 'на паузе — обычная строка с многоточием');

    await tester.pumpWidget(app(long, running: true));
    await tester.pump();
    // Пауза в начале круга, затем несколько кадров движения.
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text(long), findsNWidgets(2), reason: 'бегущая строка: текст и его продолжение');
    final moved = tester.getTopLeft(find.text(long).first).dx;

    expect(moved, lessThan(340), reason: 'строка поехала влево');

    await tester.pumpWidget(app(long, running: false));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(long), findsOneWidget);
    expect(tester.getTopLeft(find.text(long)).dx, 340, reason: 'вернулась к началу');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('короткое название не двигается', (tester) async {
    await tester.pumpWidget(app('Коротко', running: true, width: 300));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Коротко'), findsOneWidget);
  });
}
