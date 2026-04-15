import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/widgets/poster_image.dart';

void main() {
  group('PosterImage', () {
    testWidgets('renders fallback icon when url is null', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: PosterImage(url: null, width: 60, height: 90)),
      ));
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('renders fallback icon when url is empty string',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: PosterImage(url: '', width: 60, height: 90)),
      ));
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('wraps in ClipRRect when borderRadius provided',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PosterImage(
            url: null,
            width: 60,
            height: 90,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ));
      expect(find.byType(ClipRRect), findsOneWidget);
    });

    testWidgets('no ClipRRect when borderRadius is null', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: PosterImage(url: null, width: 60, height: 90)),
      ));
      expect(find.byType(ClipRRect), findsNothing);
    });

    testWidgets('honors requested width and height on the fallback',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(
            child: PosterImage(url: null, width: 60, height: 90),
          ),
        ),
      ));
      final box = tester.getSize(find.byType(PosterImage));
      expect(box.width, 60);
      expect(box.height, 90);
    });
  });
}
