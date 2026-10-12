// OMT Protocol Constants — Open Media Transport 1.0
// Based on: https://github.com/openmediatransport/libomtnet/blob/master/PROTOCOL.md
//
// All data stored in Little-Endian byte order.

/// OMT Frame Types
class OMTFrameType {
  static const int none = 0;
  static const int metadata = 1;
  static const int video = 2;
  static const int audio = 4;
}

/// OMT Video Codec FourCC values (Little-Endian)
class OMTCodecFourCC {
  // VMX 4:2:2 codec (primary OMT video codec)
  static const int vmx1 = 0x31584D56; // 'VMX1' LE
  // Raw YUV formats
  static const int uyvy = 0x59565955; // 'UYVY' LE
  static const int yuy2 = 0x32595559; // 'YUY2' LE
  static const int bgra = 0x41524742; // 'BGRA' LE
  static const int nv12 = 0x3231564E; // 'NV12' LE
  static const int yv12 = 0x32315659; // 'YV12' LE
  static const int uyva = 0x41565955; // 'UYVA' LE
  static const int p216 = 0x36313250; // 'P216' LE
  static const int pa16 = 0x36314150; // 'PA16' LE
  // Audio
  static const int fpa1 = 0x31415046; // 'FPA1' LE
}

/// OMT Audio Codec
class OMTAudioCodec {
  // 32-bit floating point planar audio
  static const int fpa1 = 0x31415046; // 'FPA1' LE
}

/// OMT Video Flags
class OMTVideoFlags {
  static const int none = 0;
  static const int interlaced = 1;
  static const int alpha = 2;
  static const int preMultiplied = 4;
  static const int preview = 8;
  static const int highBitDepth = 16;
}

/// OMT Color Space
class OMTColorSpace {
  static const int undefined = 0;
  static const int bt601 = 601;
  static const int bt709 = 709;
}

/// OMT Header size constants
class OMTHeaderSize {
  static const int mainHeader = 16;
  static const int videoExtendedHeader = 32;
  static const int audioExtendedHeader = 24;
}

/// OMT DNS-SD Service Type
const String kOMTServiceType = '_omt._tcp';
const String kOMTServiceDomain = 'local';
const int kOMTDefaultPort = 7788;

/// OMT Protocol Version
const int kOMTProtocolVersion = 1;

/// OMT Connection States
enum OMTConnectionState {
  idle,
  discovering,
  connecting,
  transmitting,
  receiving,
  disconnecting,
  error,
}

/// Represents a discovered OMT source on the network
class OMTSource {
  final String name;
  final String host;
  final int port;
  final String? metadata;
  final DateTime discoveredAt;

  const OMTSource({
    required this.name,
    required this.host,
    required this.port,
    this.metadata,
    required this.discoveredAt,
  });

  @override
  String toString() => '$name @ $host:$port';

  Map<String, dynamic> toMap() => {
        'name': name,
        'host': host,
        'port': port,
        'metadata': metadata ?? '',
      };

  factory OMTSource.fromMap(Map<String, dynamic> map) => OMTSource(
        name: map['name'] as String? ?? 'Unknown',
        host: map['host'] as String? ?? '',
        port: map['port'] as int? ?? kOMTDefaultPort,
        metadata: map['metadata'] as String?,
        discoveredAt: DateTime.now(),
      );
}

/// OMT video resolutions supported for sending
enum OMTResolution {
  hd720p,
  hd1080p,
  uhd4k,
}

extension OMTResolutionExtension on OMTResolution {
  int get width {
    switch (this) {
      case OMTResolution.hd720p:
        return 1280;
      case OMTResolution.hd1080p:
        return 1920;
      case OMTResolution.uhd4k:
        return 3840;
    }
  }

  int get height {
    switch (this) {
      case OMTResolution.hd720p:
        return 720;
      case OMTResolution.hd1080p:
        return 1080;
      case OMTResolution.uhd4k:
        return 2160;
    }
  }

  String get label {
    switch (this) {
      case OMTResolution.hd720p:
        return '720p HD';
      case OMTResolution.hd1080p:
        return '1080p Full HD';
      case OMTResolution.uhd4k:
        return '4K UHD';
    }
  }
}

/// OMT frame rates supported
enum OMTFrameRate {
  fps25,
  fps30,
  fps50,
  fps60,
}

extension OMTFrameRateExtension on OMTFrameRate {
  int get numerator {
    switch (this) {
      case OMTFrameRate.fps25:
        return 25;
      case OMTFrameRate.fps30:
        return 30000;
      case OMTFrameRate.fps50:
        return 50;
      case OMTFrameRate.fps60:
        return 60000;
    }
  }

  int get denominator {
    switch (this) {
      case OMTFrameRate.fps25:
        return 1;
      case OMTFrameRate.fps30:
        return 1001;
      case OMTFrameRate.fps50:
        return 1;
      case OMTFrameRate.fps60:
        return 1001;
    }
  }

  String get label {
    switch (this) {
      case OMTFrameRate.fps25:
        return '25 fps (PAL)';
      case OMTFrameRate.fps30:
        return '29.97 fps (NTSC)';
      case OMTFrameRate.fps50:
        return '50 fps';
      case OMTFrameRate.fps60:
        return '59.94 fps';
    }
  }
}
