import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_ndi/omt/omt_protocol.dart';
import 'package:mimo_ndi/omt/omt_service.dart';

void main() {
  const channel = MethodChannel('com.antigravity/omt_events');
  const codec = StandardMethodCodec();
  final service = OMTService();

  testWidgets('repeated initialization opens only one native subscription', (tester) async {
    var listens = 0;
    var cancels = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel') cancels++;
      return null;
    });
    addTearDown(() async {
      await service.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    await service.initialize();
    await service.initialize();
    await tester.pump();
    expect(listens, 1);
    await service.dispose();
    expect(cancels, 1);
  });

  testWidgets('singleton streams still deliver after closing and reopening', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() async {
      await service.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    final states = <OMTConnectionState>[];
    final subscription = service.stateStream.listen(states.add);
    addTearDown(subscription.cancel);
    await service.initialize();
    await tester.pump();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name, codec.encodeSuccessEnvelope({'type': 'stateChanged', 'state': 'receiving'}), (_) {},
    );
    await tester.pump();
    await service.dispose();
    await service.initialize();
    await tester.pump();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name, codec.encodeSuccessEnvelope({'type': 'stateChanged', 'state': 'connected'}), (_) {},
    );
    await tester.pump();
    expect(states, [OMTConnectionState.receiving, OMTConnectionState.connected]);
  });

  testWidgets('reopen waits for native cancellation and cancels stale init', (tester) async {
    var listens = 0;
    final cancelGate = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel' && !cancelGate.isCompleted) await cancelGate.future;
      return null;
    });
    addTearDown(() async {
      if (!cancelGate.isCompleted) cancelGate.complete();
      await service.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    await service.initialize();
    await tester.pump();
    final closing = service.dispose();
    final staleInit = service.initialize();
    final closingAgain = service.dispose();
    final reopening = service.initialize();
    await tester.pump();
    expect(listens, 1);
    cancelGate.complete();
    await Future.wait([closing, staleInit, closingAgain, reopening]);
    await tester.pump();
    expect(listens, 2);
  });
}
