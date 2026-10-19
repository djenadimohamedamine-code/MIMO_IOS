import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_ndi/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final action in ['TAKE', 'AUTO']) {
    testWidgets('$action feedback is cancelled when leaving switcher', (tester) async {
      SharedPreferences.setMockInitialValues({});
      const ndi = MethodChannel('com.antigravity/ndi');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(ndi, (_) async => true);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(ndi, null));
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: SwitcherScreen(sources: const [], onRefresh: () {}),
      )));
      await tester.pump();
      await tester.tap(find.text('RELAY'));
      await tester.pump();
      await tester.tap(find.text(action));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}
