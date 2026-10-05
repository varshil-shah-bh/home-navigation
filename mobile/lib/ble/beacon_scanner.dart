import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ibeacon.dart';

/// Continuously scans for BLE advertisements and keeps the latest packet per
/// device. Every packet is written to the debug console so beacon bring-up can
/// be diagnosed without attaching a profiler.
class BeaconScanner extends ChangeNotifier {
  BeaconScanner({this.logEveryPacket = true});

  /// When false only the first sighting of a device is logged.
  final bool logEveryPacket;

  final Map<String, BleObservation> _devices = {};
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _stateSub;

  bool _scanning = false;
  String? _error;

  List<BleObservation> get devices {
    final list = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  List<BleObservation> get beacons =>
      devices.where((d) => d.beacon != null).toList();

  bool get isScanning => _scanning;
  String? get error => _error;

  Future<void> start() async {
    _error = null;

    if (!await FlutterBluePlus.isSupported) {
      _fail('Bluetooth is not supported on this device.');
      return;
    }

    _stateSub ??= FlutterBluePlus.adapterState.listen((state) {
      _log('adapter state: $state');
      if (state != BluetoothAdapterState.on && _scanning) {
        _scanning = false;
        notifyListeners();
      }
    });

    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      _fail('Bluetooth is off. Turn it on and scan again.');
      return;
    }

    _scanSub ??= FlutterBluePlus.onScanResults.listen(
      _onResults,
      onError: (Object e) => _fail('$e'),
    );

    try {
      // flutter_blue_plus asks for the runtime permissions it needs here.
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        androidScanMode: AndroidScanMode.lowLatency,
        androidUsesFineLocation: true,
      );
      _scanning = true;
      _log('scan started');
    } catch (e) {
      _fail('$e');
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await FlutterBluePlus.stopScan();
    _scanning = false;
    _log('scan stopped — ${_devices.length} device(s) seen');
    notifyListeners();
  }

  void clear() {
    _devices.clear();
    notifyListeners();
  }

  void _onResults(List<ScanResult> results) {
    for (final r in results) {
      final ad = r.advertisementData;
      final id = r.device.remoteId.str;
      final name = ad.advName.isNotEmpty
          ? ad.advName
          : r.device.platformName.isNotEmpty
          ? r.device.platformName
          : '(no name)';
      final serviceData = {
        for (final e in ad.serviceData.entries) e.key.str: e.value,
      };

      final beacon = IBeaconReading.parse(
        manufacturerData: ad.manufacturerData,
        serviceData: serviceData,
        rssi: r.rssi,
        deviceId: id,
        deviceName: name,
      );

      final previous = _devices[id];
      _devices[id] = BleObservation(
        deviceId: id,
        name: name,
        rssi: r.rssi,
        txPowerLevel: ad.txPowerLevel,
        serviceUuids: ad.serviceUuids.map((u) => u.str).toList(),
        manufacturerData: ad.manufacturerData,
        serviceData: serviceData,
        beacon: beacon,
        seenAt: DateTime.now(),
        packetCount: (previous?.packetCount ?? 0) + 1,
      );

      if (logEveryPacket || previous == null) {
        _logDevice(_devices[id]!);
      }
    }
    notifyListeners();
  }

  void _logDevice(BleObservation d) {
    final beacon = d.beacon;
    if (beacon != null) {
      _log(
        'BEACON[${beacon.formatLabel}] ${d.deviceId} "${d.name}" '
        'uuid=${beacon.uuid} major=${beacon.major} minor=${beacon.minor} '
        'txPower=${beacon.txPower} rssi=${beacon.rssi} '
        'd≈${beacon.distance().toStringAsFixed(2)}m '
        'packets=${d.packetCount}',
      );
      return;
    }
    if (d.hasUndecodedAppleData) {
      _log(
        'APPLE-NOT-IBEACON ${d.deviceId} "${d.name}" rssi=${d.rssi} '
        'payload=${d.manufacturerHex.replaceAll('\n', ' | ')} '
        '(expected it to start with 02 15)',
      );
      return;
    }
    _log(
      'DEVICE ${d.deviceId} "${d.name}" rssi=${d.rssi} '
      'txPowerLevel=${d.txPowerLevel} '
      'services=${d.serviceUuids.isEmpty ? '-' : d.serviceUuids.join(',')} '
      'mfg=${d.manufacturerData.isEmpty ? '-' : d.manufacturerHex.replaceAll('\n', ' | ')} '
      'svcData=${d.serviceData.isEmpty ? '-' : d.serviceDataHex.replaceAll('\n', ' | ')}',
    );
  }

  void _fail(String message) {
    _error = message;
    _scanning = false;
    _log('ERROR $message');
    notifyListeners();
  }

  void _log(String message) => debugPrint('[ble] $message');

  @override
  void dispose() {
    _scanSub?.cancel();
    _stateSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }
}
