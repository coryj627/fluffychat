// Picked up by `flutter test` for every test file under test/: audits recorded by
// flutter_a11y_test's auditScreen() (test/a11y/) are merged into one runtime report
// that `a11y_check_flutter scan` reads. Tests that never audit are unaffected.
import 'dart:async';

import 'package:flutter_a11y_test/flutter_a11y_test.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  RuntimeFindingsSink.configure(); // .a11y/flutter/runtime-findings.json
  tearDownAll(RuntimeFindingsSink.flush);
  await testMain();
}
