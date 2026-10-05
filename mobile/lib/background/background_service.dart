import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

@pragma('vm:entry-point')
void backgroundServiceCallback() =>
    FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());

/// The live WebSocket runs in the main isolate; the service only keeps the process alive.
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Android foreground service that keeps the app connected while it is in the background.
abstract final class BackgroundService {
  static const _idle = 'Connected to the control room';

  static void init() {
    if (!_supported) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'home_nav_background',
        channelName: 'Background connection',
        channelDescription: 'Keeps emergency alerts working while the app is closed.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start() async {
    if (!_supported) return;
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 4101,
      notificationTitle: 'Home navigation',
      notificationText: _idle,
      callback: backgroundServiceCallback,
    );
  }

  static Future<void> stop() async {
    if (!_supported) return;
    await FlutterForegroundTask.stopService();
  }

  static Future<void> showEmergency(String? by) async {
    if (!_supported || !await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'EMERGENCY',
      notificationText: by == null ? 'Head to the safe zone' : '$by raised an emergency',
    );
  }

  static Future<void> clearEmergency() async {
    if (!_supported || !await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Home navigation',
      notificationText: _idle,
    );
  }
}
