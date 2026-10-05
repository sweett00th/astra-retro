import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// Top-level callback required by flutter_foreground_task.
@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_DownloadTaskHandler());
}

/// Minimal TaskHandler — we don't use the repeat event or IPC.
/// The sole purpose is to keep the Dart isolate alive.
class _DownloadTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Thin wrapper around [FlutterForegroundTask] that manages a foreground
/// service while downloads are active. Keeps the process alive and shows a
/// notification with progress.
class DownloadForegroundService {
  static bool _initialized = false;
  static bool _running = false;
  static Completer<void>? _startCompleter;
  static Completer<void>? _stopCompleter;

  // Work outside the game queue (system-file transfers) that also needs the
  // process kept alive. The game queue stopping does not end the service
  // while a hold exists.
  static final Set<String> _holds = {};
  static int _gameActive = 0;
  static int _gameQueued = 0;

  static String _text(int activeCount, int queuedCount) {
    if (_holds.isEmpty) return buildNotificationText(activeCount, queuedCount);
    if (activeCount == 0 && queuedCount == 0) return 'Transferring system files';
    return '${buildNotificationText(activeCount, queuedCount)}, system files';
  }

  /// Keeps the service running for [owner] until [release].
  static Future<void> hold(String owner) async {
    if (!_holds.add(owner)) return;
    await startIfNeeded(activeCount: _gameActive, queuedCount: _gameQueued);
  }

  static Future<void> release(String owner) async {
    if (!_holds.remove(owner)) return;
    if (_gameActive == 0 && _gameQueued == 0) {
      await stop();
    } else {
      await updateProgress(activeCount: _gameActive, queuedCount: _gameQueued);
    }
  }

  /// Call once at app startup.
  static void init() {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'r_shop_download',
        channelName: 'Downloads',
        channelDescription: 'Shows progress while downloading games',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        showWhen: false,
        showBadge: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Start the foreground service if not already running.
  /// Call when a download becomes active.
  static Future<void> startIfNeeded({required int activeCount, required int queuedCount}) async {
    _gameActive = activeCount;
    _gameQueued = queuedCount;
    if (!_initialized) return;
    // Wait for any pending stop to finish first
    final pendingStop = _stopCompleter;
    if (pendingStop != null) {
      await pendingStop.future;
    }
    if (_running) {
      await updateProgress(activeCount: activeCount, queuedCount: queuedCount);
      return;
    }
    if (_startCompleter != null) return; // Already starting

    _startCompleter = Completer<void>();
    try {
      // Request notification permission on Android 13+ (required for foreground service notification).
      // If denied, we still attempt to start — the service keeps the process alive regardless.
      final notificationPermission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      // Request battery optimization bypass so OEM firmware doesn't kill the service.
      final isIgnoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!isIgnoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }

      final result = await FlutterForegroundTask.startService(
        notificationTitle: 'R-Shop',
        notificationText: _text(activeCount, queuedCount),
        callback: _startCallback,
      );

      if (result is ServiceRequestSuccess) {
        _running = true;
      }
    } finally {
      _startCompleter!.complete();
      _startCompleter = null;
    }
  }

  /// Update the notification text with current progress.
  static Future<void> updateProgress({
    required int activeCount,
    required int queuedCount,
    String? progressDetail,
  }) async {
    _gameActive = activeCount;
    _gameQueued = queuedCount;
    if (!_running) return;

    var text = _text(activeCount, queuedCount);
    if (progressDetail != null) {
      text = '$text — $progressDetail';
    }

    await FlutterForegroundTask.updateService(
      notificationTitle: 'R-Shop',
      notificationText: text,
    );
  }

  /// Stop the foreground service. Call when all downloads are finished.
  static Future<void> stop() async {
    _gameActive = 0;
    _gameQueued = 0;
    if (_holds.isNotEmpty) {
      // Something else still needs the process kept alive.
      await updateProgress(activeCount: 0, queuedCount: 0);
      return;
    }
    final pending = _startCompleter;
    if (pending != null) {
      await pending.future;
    }
    if (!_running) return;

    _stopCompleter = Completer<void>();
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('DownloadForegroundService: stop failed: $e');
    }
    _running = false;
    _stopCompleter!.complete();
    _stopCompleter = null;
  }

  @visibleForTesting
  static String buildNotificationText(int activeCount, int queuedCount) {
    if (activeCount == 0 && queuedCount == 0) {
      return 'Downloads complete';
    }
    final parts = <String>[];
    if (activeCount > 0) {
      parts.add('$activeCount active');
    }
    if (queuedCount > 0) {
      parts.add('$queuedCount queued');
    }
    return 'Downloading: ${parts.join(', ')}';
  }
}
