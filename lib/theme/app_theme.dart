import 'package:flutter/material.dart';

/// WatchNext is dark-mode only (per spec).
final appDarkTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFFE50914), // streaming-red accent
    brightness: Brightness.dark,
  ),
);
