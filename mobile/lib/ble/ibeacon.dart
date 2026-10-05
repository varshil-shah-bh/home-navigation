import 'dart:math' as math;
import 'dart:typed_data';

/// Apple's company identifier in BLE manufacturer data.
const int kAppleCompanyId = 0x004C;

/// Radius Networks' company identifier, used by the AltBeacon reference impl.
const int kAltBeaconCompanyId = 0x0118;

/// Eddystone's 16-bit service UUID.
const String kEddystoneService = 'feaa';

enum BeaconFormat { ibeacon, altbeacon, eddystoneUid }

/// A single beacon advertisement seen by the scanner.
class IBeaconReading {
  final BeaconFormat format;
  final String uuid;
  final int major;
  final int minor;

  /// Calibrated RSSI at 1 m, as advertised by the beacon.
  final int txPower;

  /// Signal strength of this particular packet.
  final int rssi;

  final String deviceId;
  final String deviceName;
  final DateTime seenAt;

  const IBeaconReading({
    required this.format,
    required this.uuid,
    required this.major,
    required this.minor,
    required this.txPower,
    required this.rssi,
    required this.deviceId,
    required this.deviceName,
    required this.seenAt,
  });

  String get key => '$uuid/$major/$minor';

  String get formatLabel => switch (format) {
    BeaconFormat.ibeacon => 'iBeacon',
    BeaconFormat.altbeacon => 'AltBeacon',
    BeaconFormat.eddystoneUid => 'Eddystone-UID',
  };

  /// Log-distance path loss estimate in metres. [pathLoss] is ~2 in open
  /// space and 2.7-3.5 indoors through walls.
  double distance({double pathLoss = 2.8}) =>
      math.pow(10, (txPower - rssi) / (10 * pathLoss)).toDouble();

  /// Decodes iBeacon, AltBeacon or Eddystone-UID from a single advertisement.
  static IBeaconReading? parse({
    required Map<int, List<int>> manufacturerData,
    required Map<String, List<int>> serviceData,
    required int rssi,
    required String deviceId,
    required String deviceName,
  }) {
    // iBeacon: 0x02 0x15, 16B UUID, 2B major, 2B minor, 1B calibrated power.
    final apple = manufacturerData[kAppleCompanyId];
    if (apple != null &&
        apple.length >= 23 &&
        apple[0] == 0x02 &&
        apple[1] == 0x15) {
      return _fromLayout(
        apple,
        BeaconFormat.ibeacon,
        rssi: rssi,
        deviceId: deviceId,
        deviceName: deviceName,
      );
    }

    // AltBeacon: 0xBE 0xAC, then the same 20B id + reference RSSI layout.
    final alt = manufacturerData[kAltBeaconCompanyId];
    if (alt != null && alt.length >= 23 && alt[0] == 0xBE && alt[1] == 0xAC) {
      return _fromLayout(
        alt,
        BeaconFormat.altbeacon,
        rssi: rssi,
        deviceId: deviceId,
        deviceName: deviceName,
      );
    }

    // Eddystone-UID: 0x00 frame, 1B tx power, 10B namespace, 6B instance.
    for (final entry in serviceData.entries) {
      if (!entry.key.toLowerCase().contains(kEddystoneService)) continue;
      final d = entry.value;
      if (d.length < 18 || d[0] != 0x00) continue;
      final bytes = Uint8List.fromList(d);
      return IBeaconReading(
        format: BeaconFormat.eddystoneUid,
        uuid: _hex(bytes.sublist(2, 12)),
        major:
            (bytes[12] << 24) |
            (bytes[13] << 16) |
            (bytes[14] << 8) |
            bytes[15],
        minor: (bytes[16] << 8) | bytes[17],
        txPower: bytes[1].toSigned(8),
        rssi: rssi,
        deviceId: deviceId,
        deviceName: deviceName,
        seenAt: DateTime.now(),
      );
    }
    return null;
  }

  static IBeaconReading _fromLayout(
    List<int> payload,
    BeaconFormat format, {
    required int rssi,
    required String deviceId,
    required String deviceName,
  }) {
    final bytes = Uint8List.fromList(payload);
    final hex = _hex(bytes.sublist(2, 18));
    return IBeaconReading(
      format: format,
      uuid:
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
          '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
          '${hex.substring(20)}',
      major: (bytes[18] << 8) | bytes[19],
      minor: (bytes[20] << 8) | bytes[21],
      txPower: bytes[22].toSigned(8),
      rssi: rssi,
      deviceId: deviceId,
      deviceName: deviceName,
      seenAt: DateTime.now(),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() =>
      '$formatLabel $uuid major=$major minor=$minor '
      'rssi=$rssi txPower=$txPower d≈${distance().toStringAsFixed(2)}m';
}

/// Any BLE advertisement, beacon or not — what the debug screen lists.
class BleObservation {
  final String deviceId;
  final String name;
  final int rssi;
  final int? txPowerLevel;
  final List<String> serviceUuids;
  final Map<int, List<int>> manufacturerData;
  final Map<String, List<int>> serviceData;
  final IBeaconReading? beacon;
  final DateTime seenAt;
  int packetCount;

  BleObservation({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.txPowerLevel,
    required this.serviceUuids,
    required this.manufacturerData,
    required this.serviceData,
    required this.beacon,
    required this.seenAt,
    this.packetCount = 1,
  });

  /// True when the packet carries Apple manufacturer data that is not a
  /// well-formed iBeacon frame — the usual sign of a misconfigured advertiser.
  bool get hasUndecodedAppleData =>
      beacon == null && manufacturerData.containsKey(kAppleCompanyId);

  String get manufacturerHex => manufacturerData.entries
      .map(
        (e) =>
            '0x${e.key.toRadixString(16).padLeft(4, '0')}: '
            '${e.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
      )
      .join('\n');

  String get serviceDataHex => serviceData.entries
      .map(
        (e) =>
            '${e.key}: '
            '${e.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
      )
      .join('\n');
}
