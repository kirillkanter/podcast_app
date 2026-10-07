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
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(long), findsNWidgets(2), reason: 'бегущая строка: текст и его продолжение');
    final moved = tester.getTopLeft(find.text(long).first).dx;

    await tester.pumpWidget(app(long, running: false));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(long), findsOneWidget);
    expect(tester.getTopLeft(find.text(long)).dx, greaterThan(moved), reason: 'вернулась к началу');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('короткое название не двигается', (tester) async {
    await tester.pumpWidget(app('Коротко', running: true, width: 300));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Коротко'), findsOneWidget);
  });
}
