import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart';

/// Asks for the runtime permissions beacon scanning needs. Returns true if all were granted.
Future<bool> requestBlePermissions() async {
  // iOS prompts for Bluetooth/location itself when scanning starts.
  if (!Platform.isAndroid) return true;

  final results = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.locationWhenInUse,
  ].request();

  return results.values.every((s) => s.isGranted);
}
