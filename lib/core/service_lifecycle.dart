import 'dart:async';

/// A Dart stop acknowledgment can precede native Android service teardown.
/// Starting another engine is safe only after the native service is absent.
Future<void> waitForServiceStop(
  Future<bool> Function() isRunning, {
  Duration timeout = const Duration(seconds: 8),
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final elapsed = Stopwatch()..start();
  while (await isRunning()) {
    if (elapsed.elapsed >= timeout) {
      throw TimeoutException(
        'Receiving is still stopping. Try Stop receiving again before changing modes.',
      );
    }
    await Future<void>.delayed(pollInterval);
  }
}
