import 'package:flutter/material.dart';

import '../providers/year_filter_provider.dart';

/// Earliest year the year-range slider allows. TMDB has older titles but
/// the release-date index gets sparse before this, and the slider gets
/// uncomfortably long. Users who want silents can still see them — just
/// without a lower bound.
const int kMinYearSlider = 1920;

/// RangeSlider from [kMinYearSlider] to the current year. When a handle is
/// dragged to its endpoint, the corresponding bound is stored as null — i.e.
/// the slider reads "no lower bound" / "no upper bound" rather than being
/// pinned to a specific decade. Writes happen on drag end only so prefs
/// don't get hammered on every tick.
class YearRangeSlider extends StatefulWidget {
  final YearRange range;
  final ValueChanged<YearRange> onChanged;
  final int? maxYearOverride;

  const YearRangeSlider({
    super.key,
    required this.range,
    required this.onChanged,
    this.maxYearOverride,
  });

  @override
  State<YearRangeSlider> createState() => _YearRangeSliderState();
}

class _YearRangeSliderState extends State<YearRangeSlider> {
  late RangeValues _values;
  late int _maxYear;

  @override
  void initState() {
    super.initState();
    _maxYear = widget.maxYearOverride ?? DateTime.now().year;
    _values = _rangeToSlider(widget.range);
  }

  @override
  void didUpdateWidget(covariant YearRangeSlider old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range) {
      _values = _rangeToSlider(widget.range);
    }
  }

  RangeValues _rangeToSlider(YearRange r) {
    final lo = (r.minYear ?? kMinYearSlider).clamp(kMinYearSlider, _maxYear);
    final hi = (r.maxYear ?? _maxYear).clamp(kMinYearSlider, _maxYear);
    return RangeValues(lo.toDouble(), hi.toDouble());
  }

  YearRange _sliderToRange(RangeValues v) {
    final lo = v.start.round();
    final hi = v.end.round();
    return YearRange(
      minYear: lo <= kMinYearSlider ? null : lo,
      maxYear: hi >= _maxYear ? null : hi,
    );
  }

  String _label(int year, {required bool isLow}) {
    if (isLow && year <= kMinYearSlider) return 'Any';
    if (!isLow && year >= _maxYear) return 'Any';
    return '$year';
  }

  @override
  Widget build(BuildContext context) {
    final lo = _values.start.round();
    final hi = _values.end.round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                const Icon(Icons.calendar_today, size: 14, color: Colors.white54),
                const SizedBox(width: 6),
                Text(
                  'Year: ${_label(lo, isLow: true)} – ${_label(hi, isLow: false)}',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          RangeSlider(
            min: kMinYearSlider.toDouble(),
            max: _maxYear.toDouble(),
            divisions: _maxYear - kMinYearSlider,
            values: _values,
            labels: RangeLabels(
              _label(lo, isLow: true),
              _label(hi, isLow: false),
            ),
            onChanged: (v) => setState(() => _values = v),
            onChangeEnd: (v) => widget.onChanged(_sliderToRange(v)),
          ),
        ],
      ),
    );
  }
}
