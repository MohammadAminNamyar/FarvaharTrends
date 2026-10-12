import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'ui/pilot_app.dart';

export 'ui/pilot_app.dart' show PersianTrendApp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Manrope',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
    yield LicenseEntryWithLineBreaks([
      'Vazirmatn',
    ], await rootBundle.loadString('assets/fonts/Vazirmatn-OFL.txt'));
  });
  runApp(const PersianTrendApp());
}
