import 'dart:async';
import 'package:flutter/services.dart';
import 'omt_protocol.dart';

/// Flutter service that bridges to the native iOS OMT implementation
/// via a dedicated MethodChannel independent of the NDI channel.
///
/// Channel: com.antigravity/omt
/// EventChannel: com.antigravity/omt_events
/// This is completely separate from 'com.antigravity/ndi'
class OMTService {
  static const MethodChannel _channel = MethodChannel('com.antigravity/omt');
  static const EventChannel _eventChannel = EventChannel('com.antigravity/omt_events');

  // Singleton
  static final OMTService _instance = OMTService._internal();
  factory OMTService() => _instance;
  OMTService._internal();

  // State management
  final StreamController<OMTConnectionState> _stateController =
      StreamController<OMTConnectionState>.broadcast();
  final StreamController<List<OMTSource>> _sourcesController =
      StreamController<List<OMTSource>>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _statsController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<OMTConnectionState> get stateStream => _stateController.stream;
  Stream<List<OMTSource>> get sourcesStream => _sourcesController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<Map<String, dynamic>> get statsStream => _statsController.stream;

  OMTConnectionState _currentState = OMTConnectionState.idle;
  List<OMTSource> _discoveredSources = [];
  StreamSubscription<dynamic>? _eventSubscription;

  OMTConnectionState get currentState => _currentState;
  List<OMTSource> get discoveredSources => List.unmodifiable(_discoveredSources);

  /// Initialize the OMT service and subscribe to native events
  Future<void> initialize() async {
    try {
      _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
        _handleNativeEvent,
        onError: (error) {
          _errorController.add('Event channel error: $error');
        },
      );
    } catch (e) {
      // Event channel may not be available on non-iOS platforms
      print('[OMT] Event channel init: $e');
    }
  }

  void _handleNativeEvent(dynamic event) {
    if (event is! Map) return;
    final Map<String, dynamic> data = Map<String, dynamic>.from(event);
    final String type = data['type'] as String? ?? '';

    switch (type) {
      case 'stateChanged':
        final String stateName = data['state'] as String? ?? 'idle';
        final newState = _parseState(stateName);
        _currentState = newState;
        _stateController.add(newState);
        break;

      case 'sourcesDiscovered':
        final List<dynamic> rawSources = data['sources'] as List? ?? [];
        _discoveredSources = rawSources
            .whereType<Map>()
            .map((m) => OMTSource.fromMap(Map<String, dynamic>.from(m)))
            .toList();
        _sourcesController.add(List.unmodifiable(_discoveredSources));
        break;

      case 'error':
        final String message = data['message'] as String? ?? 'Unknown error';
        _errorController.add(message);
        break;

      case 'stats':
        _statsController.add(data);
        break;
    }
  }

  OMTConnectionState _parseState(String s) {
    switch (s) {
      case 'idle':
        return OMTConnectionState.idle;
      case 'discovering':
        return OMTConnectionState.discovering;
      case 'listening':
        return OMTConnectionState.listening;
      case 'connected':
        return OMTConnectionState.connected;
      case 'connecting':
        return OMTConnectionState.connecting;
      case 'transmitting':
        return OMTConnectionState.transmitting;
      case 'receiving':
        return OMTConnectionState.receiving;
      case 'disconnecting':
        return OMTConnectionState.disconnecting;
      case 'error':
        return OMTConnectionState.error;
      default:
        return OMTConnectionState.idle;
    }
  }

  // ─── SENDING ──────────────────────────────────────────────────────────────

  /// Start sending camera video to vMix via OMT protocol.
  /// [sourceName] is the name that will appear in vMix's source list.
  /// [resolution] and [frameRate] control the video format.
  Future<bool> startSending({
    String sourceName = 'MIMO_NDI Camera',
    OMTResolution resolution = OMTResolution.hd1080p,
    OMTFrameRate frameRate = OMTFrameRate.fps30,
    bool useFrontCamera = false,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('startSending', {
        'sourceName': sourceName,
        'width': resolution.width,
        'height': resolution.height,
        'frameRateN': frameRate.numerator,
        'frameRateD': frameRate.denominator,
        'useFrontCamera': useFrontCamera,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add('startSending failed: ${e.message}');
      return false;
    }
  }

  /// Stop sending camera video
  Future<void> stopSending() async {
    try {
      await _channel.invokeMethod('stopSending');
    } on PlatformException catch (e) {
      _errorController.add('stopSending error: ${e.message}');
    }
  }

  /// Start local camera preview via native AVCaptureVideoPreviewLayer PlatformView
  Future<bool> startCameraPreview({
    OMTResolution resolution = OMTResolution.hd1080p,
    OMTFrameRate frameRate = OMTFrameRate.fps30,
    bool useFrontCamera = false,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('startCameraPreview', {
        'width': resolution.width,
        'height': resolution.height,
        'frameRateN': frameRate.numerator,
        'frameRateD': frameRate.denominator,
        'useFrontCamera': useFrontCamera,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add('startCameraPreview error: ${e.message}');
      return false;
    }
  }

  /// Stop local camera preview
  Future<bool> stopCameraPreview() async {
    try {
      final result = await _channel.invokeMethod<bool>('stopCameraPreview');
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add('stopCameraPreview error: ${e.message}');
      return false;
    }
  }

  /// Toggle diagnostic test pattern (SMPTE 75% color bars with motion indicator)
  Future<bool> setTestPattern(bool enabled) async {
    try {
      final result = await _channel.invokeMethod<bool>('setTestPattern', {
        'enabled': enabled,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add('setTestPattern error: ${e.message}');
      return false;
    }
  }

  /// Switch between front and back camera dynamically
  Future<bool> switchCamera({required bool useFrontCamera}) async {
    try {
      final result = await _channel.invokeMethod<bool>('switchCamera', {
        'useFrontCamera': useFrontCamera,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add('switchCamera error: ${e.message}');
      return false;
    }
  }

  // ─── DISCOVERY ────────────────────────────────────────────────────────────

  /// Start discovering OMT sources on the local network via DNS-SD (_omt._tcp)
  Future<void> startDiscovery() async {
    try {
      await _channel.invokeMethod('startDiscovery');
    } on PlatformException catch (e) {
      _errorController.add('startDiscovery error: ${e.message}');
    }
  }

  /// Stop network discovery
  Future<void> stopDiscovery() async {
    try {
      await _channel.invokeMethod('stopDiscovery');
    } on PlatformException catch (e) {
      _errorController.add('stopDiscovery error: ${e.message}');
    }
  }

  /// Get current list of discovered sources
  Future<List<OMTSource>> getSources() async {
    try {
      final List<dynamic>? result =
          await _channel.invokeMethod<List<dynamic>>('getSources');
      if (result == null) return [];
      return result
          .whereType<Map>()
          .map((m) => OMTSource.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } on PlatformException catch (e) {
      _errorController.add('getSources error: ${e.message}');
      return [];
    }
  }

  // ─── RECEIVING ────────────────────────────────────────────────────────────

  /// Connect to a specific OMT source for receiving
  Future<bool> connectToSource(OMTSource source) async {
    try {
      final result = await _channel.invokeMethod<bool>('connectToSource', {
        'host': source.host,
        'port': source.port,
        'name': source.name,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _errorController.add('connectToSource error: ${e.message}');
      return false;
    }
  }

  /// Disconnect from current source
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } on PlatformException catch (e) {
      _errorController.add('disconnect error: ${e.message}');
    }
  }

  // ─── STATUS ───────────────────────────────────────────────────────────────

  /// Get current connection state from native layer
  Future<OMTConnectionState> getState() async {
    try {
      final String? state = await _channel.invokeMethod<String>('getState');
      return _parseState(state ?? 'idle');
    } on PlatformException {
      return OMTConnectionState.idle;
    }
  }

  /// Get transmission statistics
  Future<Map<String, dynamic>> getStats() async {
    try {
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getStats');
      return result?.cast<String, dynamic>() ?? {};
    } on PlatformException {
      return {};
    }
  }

  // ─── CLEANUP ──────────────────────────────────────────────────────────────

  void dispose() {
    _eventSubscription?.cancel();
    _stateController.close();
    _sourcesController.close();
    _errorController.close();
    _statsController.close();
  }
}
