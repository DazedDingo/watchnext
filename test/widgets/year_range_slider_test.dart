import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/providers/year_filter_provider.dart';
import 'package:watchnext/widgets/year_range_slider.dart';

/// Pins maxYear at 2026 so the slider layout is deterministic and doesn't
/// drift as the test clock's real "now" changes year-over-year.
const _maxYearFixed = 2026;

Future<void> _pump(
  WidgetTester tester, {
  required YearRange range,
  required ValueChanged<YearRange> onChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: YearRangeSlider(
          range: range,
          onChanged: onChanged,
          maxYearOverride: _maxYearFixed,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('YearRangeSlider — label behaviour', () {
    testWidgets('unbounded range reads "Any – Any"', (tester) async {
      await _pump(
        tester,
        range: const YearRange.unbounded(),
        onChanged: (_) {},
      );
      expect(find.text('Year: Any – Any'), findsOneWidget);
    });

    testWidgets('min-only bound reads "<year> – Any"', (tester) async {
      await _pump(
        tester,
        range: const YearRange(minYear: 1970),
        onChanged: (_) {},
      );
      expect(find.text('Year: 1970 – Any'), findsOneWidget);
    });

    testWidgets('max-only bound reads "Any – <year>"', (tester) async {
      await _pump(
        tester,
        range: const YearRange(maxYear: 1989),
        onChanged: (_) {},
      );
      expect(find.text('Year: Any – 1989'), findsOneWidget);
    });

    testWidgets('70s-80s bound reads "1970 – 1989"', (tester) async {
      await _pump(
        tester,
        range: const YearRange(minYear: 1970, maxYear: 1989),
        onChanged: (_) {},
      );
      expect(find.text('Year: 1970 – 1989'), findsOneWidget);
    });
  });

  group('YearRangeSlider — RangeSlider wiring', () {
    testWidgets('rangeslider bounds match kMinYearSlider..maxYearOverride',
        (tester) async {
      await _pump(
        tester,
        range: const YearRange.unbounded(),
        onChanged: (_) {},
      );
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      expect(slider.min, kMinYearSlider.toDouble());
      expect(slider.max, _maxYearFixed.toDouble());
      expect(slider.divisions, _maxYearFixed - kMinYearSlider);
    });

    testWidgets('unbounded range maps to slider endpoints', (tester) async {
      await _pump(
        tester,
        range: const YearRange.unbounded(),
        onChanged: (_) {},
      );
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      expect(slider.values.start, kMinYearSlider.toDouble());
      expect(slider.values.end, _maxYearFixed.toDouble());
    });

    testWidgets('bounded range maps to slider positions', (tester) async {
      await _pump(
        tester,
        range: const YearRange(minYear: 1970, maxYear: 1989),
        onChanged: (_) {},
      );
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      expect(slider.values.start, 1970.0);
      expect(slider.values.end, 1989.0);
    });

    testWidgets('onChangeEnd at slider endpoints emits unbounded range',
        (tester) async {
      YearRange? emitted;
      await _pump(
        tester,
        range: const YearRange(minYear: 1970, maxYear: 1989),
        onChanged: (r) => emitted = r,
      );
      // Simulate a drag-end at the literal slider endpoints.
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      slider.onChangeEnd!(
        RangeValues(kMinYearSlider.toDouble(), _maxYearFixed.toDouble()),
      );
      expect(emitted, const YearRange.unbounded());
      expect(emitted!.minYear, isNull);
      expect(emitted!.maxYear, isNull);
    });

    testWidgets('onChangeEnd inside slider range emits bounded YearRange',
        (tester) async {
      YearRange? emitted;
      await _pump(
        tester,
        range: const YearRange.unbounded(),
        onChanged: (r) => emitted = r,
      );
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      slider.onChangeEnd!(const RangeValues(1970, 1989));
      expect(emitted, const YearRange(minYear: 1970, maxYear: 1989));
    });

    testWidgets('onChange (mid-drag) does NOT emit — writes only on drag end',
        (tester) async {
      int emitCount = 0;
      await _pump(
        tester,
        range: const YearRange.unbounded(),
        onChanged: (_) => emitCount++,
      );
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      slider.onChanged!(const RangeValues(1970, 1989));
      slider.onChanged!(const RangeValues(1972, 1988));
      await tester.pumpAndSettle();
      expect(emitCount, 0,
          reason: 'writes must batch to drag-end to avoid hammering prefs');
    });

    testWidgets('mid-drag updates still move the visible thumbs',
        (tester) async {
      await _pump(
        tester,
        range: const YearRange.unbounded(),
        onChanged: (_) {},
      );
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      slider.onChanged!(const RangeValues(1970, 1989));
      await tester.pumpAndSettle();
      // Label should update immediately to reflect in-progress drag.
      expect(find.text('Year: 1970 – 1989'), findsOneWidget);
    });
  });

  group('YearRangeSlider — didUpdateWidget', () {
    testWidgets('external range change re-seats the handles', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YearRangeSlider(
              range: const YearRange.unbounded(),
              onChanged: (_) {},
              maxYearOverride: _maxYearFixed,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YearRangeSlider(
              range: const YearRange(minYear: 2000, maxYear: 2010),
              onChanged: (_) {},
              maxYearOverride: _maxYearFixed,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      expect(slider.values.start, 2000.0);
      expect(slider.values.end, 2010.0);
    });

    testWidgets('out-of-range year is clamped into slider bounds on hydrate',
        (tester) async {
      // A stored range below kMinYearSlider (e.g. 1900) should clamp to 1920
      // rather than crash. The label still reads "Any" because the min is
      // pinned to the slider's low endpoint.
      await _pump(
        tester,
        range: const YearRange(minYear: 1900),
        onChanged: (_) {},
      );
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      expect(slider.values.start, kMinYearSlider.toDouble());
    });
  });
}
