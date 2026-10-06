import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/main.dart';

void main() {
  testWidgets('приложение запускается', (tester) async {
    await tester.pumpWidget(const PodcastApp());
    expect(find.text('Подкасты'), findsOneWidget);
  });
}
