/// FarvaharTrends's app shell: `MaterialApp`, theme, locale and the reader.
///
/// `main.dart` and the tests import this file; the screens live in their own
/// modules (`reader_shell.dart`, `legacy_diagnostics.dart`, ...).
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_controller.dart';
import 'localization.dart';
import 'reader_shell.dart';
import 'theme.dart';

export 'legacy_diagnostics.dart' show maxQrBytes;

class FarvaharTrendsApp extends StatefulWidget {
  const FarvaharTrendsApp({
    super.key,
    this.controller,
    this.initialize = true,
    this.animateRadar = true,
  });
  final AppController? controller;
  final bool initialize;
  final bool animateRadar;
  @override
  State<FarvaharTrendsApp> createState() => _AppState();
}

class _AppState extends State<FarvaharTrendsApp> {
  late final AppController app = widget.controller ?? AppController();
  @override
  void initState() {
    super.initState();
    if (widget.initialize) app.initialize();
  }

  @override
  void dispose() {
    if (widget.controller == null) app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => MaterialApp(
      title: 'FarvaharTrends',
      debugShowCheckedModeBanner: false,
      locale: Locale(app.languageCode),
      supportedLocales: const [Locale('fa'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => LanguageScope(
        fa: isFarsiLanguage(app.languageCode),
        child: Directionality(
          textDirection: app.languageCode == 'en'
              ? TextDirection.ltr
              : TextDirection.rtl,
          child: child!,
        ),
      ),
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: app.languageCode == 'en' ? 'Manrope' : 'Vazirmatn',
        fontFamilyFallback: const ['Vazirmatn', 'Manrope'],
        scaffoldBackgroundColor: canvasColor,
        colorScheme: ColorScheme.fromSeed(seedColor: inkColor).copyWith(
          primary: inkColor,
          secondary: tealTextColor,
          tertiary: goldTextColor,
          primaryContainer: const Color(0xFFE2F0EE),
          onPrimaryContainer: inkColor,
          secondaryContainer: const Color(0xFFE2F0EE),
          onSecondaryContainer: tealTextColor,
          surface: Colors.white,
          error: errorColor,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontSize: 27,
            fontWeight: FontWeight.w800,
            color: inkColor,
            height: 1.22,
            letterSpacing: -.8,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: inkColor,
          ),
          titleMedium: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: inkColor,
          ),
          bodyMedium: TextStyle(fontSize: 13, color: mutedColor, height: 1.65),
          bodySmall: TextStyle(fontSize: 11, color: mutedColor, height: 1.6),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            textStyle: TextStyle(
              fontFamily: app.languageCode == 'en' ? 'Manrope' : 'Vazirmatn',
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            side: const BorderSide(color: lineColor),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            textStyle: TextStyle(
              fontFamily: app.languageCode == 'en' ? 'Manrope' : 'Vazirmatn',
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.all(16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: lineColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: lineColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: tealColor, width: 1.5),
          ),
          labelStyle: const TextStyle(color: mutedColor, fontSize: 13),
        ),
        dividerColor: lineColor,
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: tealColor.withValues(alpha: .12),
          elevation: 0,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: inkColor,
        ),
      ),
      home: RepaintBoundary(
        key: const ValueKey('pilot-preview'),
        child: ReaderHome(app: app, animateRadar: widget.animateRadar),
      ),
    ),
  );
}
