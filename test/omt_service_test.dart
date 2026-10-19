import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_ndi/omt/omt_protocol.dart';
import 'package:mimo_ndi/omt/omt_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.antigravity/omt_events');
  const codec = StandardMethodCodec();
  final service = OMTService();

  test('repeated initialization opens only one native subscription', () async {
    var listens = 0;
    var cancels = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel') cancels++;
      return null;
    });
    addTearDown(() async {
      await service.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await service.initialize();
    await service.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(listens, 1);
    await service.dispose();
    expect(cancels, 1);
  });

  test('singleton streams still deliver after closing and reopening', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() async {
      await service.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final states = <OMTConnectionState>[];
    final subscription = service.stateStream.listen(states.add);
    addTearDown(subscription.cancel);
    await service.initialize();
    await Future<void>.delayed(Duration.zero);
    messenger.handlePlatformMessage(
      channel.name, codec.encodeSuccessEnvelope({'type': 'stateChanged', 'state': 'receiving'}), (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    await service.dispose();
    await service.initialize();
    await Future<void>.delayed(Duration.zero);
    messenger.handlePlatformMessage(
      channel.name, codec.encodeSuccessEnvelope({'type': 'stateChanged', 'state': 'connected'}), (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(states, [OMTConnectionState.receiving, OMTConnectionState.connected]);
  });

  test('reopen waits for native cancellation and cancels stale init', () async {
    var listens = 0;
    final cancelGate = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel' && !cancelGate.isCompleted) await cancelGate.future;
      return null;
    });
    addTearDown(() async {
      if (!cancelGate.isCompleted) cancelGate.complete();
      await service.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await service.initialize();
    await Future<void>.delayed(Duration.zero);
    final closing = service.dispose();
    final staleInit = service.initialize();
    final closingAgain = service.dispose();
    final reopening = service.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(listens, 1);
    cancelGate.complete();
    await Future.wait([closing, staleInit, closingAgain, reopening]);
    await Future<void>.delayed(Duration.zero);
    expect(listens, 2);
  });
}
