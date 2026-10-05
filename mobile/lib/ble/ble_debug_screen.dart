import 'package:flutter/material.dart';

import '../map/map_data.dart';
import 'beacon_scanner.dart';
import 'ibeacon.dart';

/// Live list of every BLE advertisement in range, with iBeacon frames decoded
/// and matched against the beacons declared in the map asset.
class BleDebugScreen extends StatefulWidget {
  const BleDebugScreen({super.key, required this.map});

  final MapData map;

  @override
  State<BleDebugScreen> createState() => _BleDebugScreenState();
}

class _BleDebugScreenState extends State<BleDebugScreen> {
  final _scanner = BeaconScanner();
  bool _beaconsOnly = false;

  @override
  void initState() {
    super.initState();
    _scanner.addListener(_onUpdate);
    _scanner.start();
  }

  void _onUpdate() => setState(() {});

  @override
  void dispose() {
    _scanner.removeListener(_onUpdate);
    _scanner.dispose();
    super.dispose();
  }

  Beacon? _known(IBeaconReading reading) {
    if (reading.uuid.toLowerCase() != widget.map.beaconUuid.toLowerCase()) {
      return null;
    }
    for (final b in widget.map.beacons) {
      if (b.major == reading.major && b.minor == reading.minor) return b;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = _scanner.devices;
    final list = _beaconsOnly ? _scanner.beacons : all;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE scanner'),
        actions: [
          IconButton(
            tooltip: 'Clear',
            onPressed: _scanner.clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: _scanner.isScanning ? 'Stop' : 'Scan',
            onPressed: _scanner.isScanning ? _scanner.stop : _scanner.start,
            icon: Icon(_scanner.isScanning ? Icons.stop : Icons.play_arrow),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                if (_scanner.isScanning)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (_scanner.isScanning) const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${all.length} device(s) • '
                    '${_scanner.beacons.length} iBeacon(s)',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                FilterChip(
                  label: const Text('Beacons only'),
                  selected: _beaconsOnly,
                  onSelected: (v) => setState(() => _beaconsOnly = v),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_scanner.error != null)
            MaterialBanner(
              content: Text(_scanner.error!),
              leading: const Icon(Icons.error_outline),
              actions: [
                TextButton(
                  onPressed: _scanner.start,
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(
            child: list.isEmpty
                ? _EmptyState(
                    scanning: _scanner.isScanning,
                    beaconsOnly: _beaconsOnly,
                    otherDevices: all.length,
                    suspicious: all.where((d) => d.hasUndecodedAppleData).length,
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _DeviceTile(
                      observation: list[i],
                      known: list[i].beacon == null
                          ? null
                          : _known(list[i].beacon!),
                      expectedUuid: widget.map.beaconUuid,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.scanning,
    required this.beaconsOnly,
    required this.otherDevices,
    required this.suspicious,
  });

  final bool scanning;
  final bool beaconsOnly;
  final int otherDevices;
  final int suspicious;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final hints = <String>[
      if (suspicious > 0)
        '$suspicious device(s) broadcast Apple manufacturer data that is not an '
            'iBeacon frame. Turn off "Beacons only" and open them to see the raw bytes.',
      'The transmitter must advertise iBeacon, AltBeacon or Eddystone-UID. '
          'A plain "BLE advertiser" with a custom service UUID will not be decoded.',
      'iPhones cannot advertise iBeacon to non-Apple scanners. Use an Android phone '
          'as the transmitter.',
      'On the transmitter, keep the advertising app in the foreground with the '
          'screen on, and check it reports "advertising started".',
      'Some Android chipsets do not support BLE peripheral mode at all — the app '
          'will silently fail to advertise.',
    ];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(
          scanning ? Icons.sensors : Icons.sensors_off,
          size: 44,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text(
          beaconsOnly
              ? 'No beacons decoded'
              : scanning
              ? 'Listening…'
              : 'Nothing found yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          '$otherDevices BLE device(s) visible in total.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        for (final hint in hints)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(
                  child: Text(hint, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {  const _DeviceTile({
    required this.observation,
    required this.known,
    required this.expectedUuid,
  });

  final BleObservation observation;
  final Beacon? known;
  final String expectedUuid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final beacon = observation.beacon;
    final mapped = known;
    final matches =
        beacon != null &&
        beacon.uuid.toLowerCase() == expectedUuid.toLowerCase();

    return ExpansionTile(
      leading: Icon(
        beacon == null
            ? Icons.bluetooth
            : matches
            ? Icons.sensors
            : Icons.sensors_off,
        color: matches
            ? Colors.teal
            : beacon != null
            ? Colors.orange
            : theme.colorScheme.outline,
      ),
      title: Text(
        beacon == null
            ? observation.name
            : '${beacon.formatLabel}  •  major ${beacon.major} • minor ${beacon.minor}'
                  '${mapped == null ? '' : '  (${mapped.id})'}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        beacon == null
            ? '${observation.deviceId}   rssi ${observation.rssi} dBm'
            : 'rssi ${beacon.rssi} dBm • tx ${beacon.txPower} • '
                  'd≈${beacon.distance().toStringAsFixed(2)} m',
      ),
      trailing: Text(
        '${observation.packetCount}',
        style: theme.textTheme.labelSmall,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row('Address', observation.deviceId),
        _row('Adv name', observation.name),
        _row('RSSI', '${observation.rssi} dBm'),
        _row('Adv TX power', '${observation.txPowerLevel ?? '-'}'),
        if (beacon != null) ...[
          _row('Format', beacon.formatLabel),
          _row('UUID', beacon.uuid),
          _row('Matches map UUID', matches ? 'yes' : 'NO — check the UUID'),
          _row('Major / Minor', '${beacon.major} / ${beacon.minor}'),
          _row('Calibrated TX', '${beacon.txPower} dBm @ 1 m'),
          _row(
            'Mapped to',
            mapped == null
                ? 'unknown — add major/minor to home_map.json'
                : '${mapped.id} in ${mapped.room ?? '-'} '
                      '@ (${mapped.position.dx}, ${mapped.position.dy}) m',
          ),
        ],
        if (observation.serviceUuids.isNotEmpty)
          _row('Services', observation.serviceUuids.join('\n')),
        if (observation.manufacturerData.isNotEmpty)
          _row('Manufacturer data', observation.manufacturerHex),
        if (observation.serviceData.isNotEmpty)
          _row('Service data', observation.serviceDataHex),
        if (observation.hasUndecodedAppleData)
          _row(
            'Diagnosis',
            'Apple manufacturer data present but the payload does not '
                'start with 02 15, so it is not an iBeacon frame.',
          ),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ],
    ),
  );
}
