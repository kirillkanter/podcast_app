import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/ui/podcast_cover.dart';

void main() {
  test('обложка декодируется с запасом вдвое', () {
    expect(decodeWidth(56 * 2.6), 512, reason: 'Nothing Phone 2: 56 × 2,6 ≈ 146 пикселей');
    expect(decodeWidth(40), 256);
    expect(decodeWidth(320 * 2.6), 1600);
    expect(decodeWidth(150 * 1.25), 512);
  });
}
