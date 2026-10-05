import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/romdrop_models.dart';
import '../../providers/romdrop_providers.dart';
import '../../services/romdrop/romdrop_controller.dart';
import '../../services/romdrop/system_file_download_manager.dart';
import 'widgets/system_screen.dart';

/// System-file downloads from RomDrop onto this device. Game downloads have
/// their own queue; nothing here is a game.
class SystemTransfersScreen extends ConsumerStatefulWidget {
  const SystemTransfersScreen({super.key});

  @override
  ConsumerState<SystemTransfersScreen> createState() =>
      _SystemTransfersScreenState();
}

class _SystemTransfersScreenState extends ConsumerState<SystemTransfersScreen> {
  RomDropController? _controller;

  @override
  void dispose() {
    _controller?.downloads.removeListener(_changed);
    super.dispose();
  }

  void _attach(RomDropController controller) {
    if (identical(controller, _controller)) return;
    _controller?.downloads.removeListener(_changed);
    _controller = controller..downloads.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  SystemRow _row(SystemFileDownloadManager downloads, SystemFileTask task) {
    final file = task.request.file;
    final title = '${task.request.assetName} · ${task.request.versionLabel}';
    final size = formatSystemFileSize(file.size);
    return switch (task.status) {
      SystemFileTaskStatus.completed => SystemRow(
          title: title,
          subtitle: '${file.filename} · $size · ${task.statusText}\nSelect to remove from this list',
          leading: const Icon(Icons.check_circle_outline, color: Colors.greenAccent),
          onSelect: () => downloads.dismiss(task.id),
        ),
      SystemFileTaskStatus.failed => SystemRow(
          title: title,
          subtitle: '${file.filename} · $size · ${task.statusText}\nSelect to continue',
          leading: const Icon(Icons.error_outline, color: Colors.redAccent),
          onSelect: () => downloads.retry(task.id),
        ),
      SystemFileTaskStatus.cancelled => SystemRow(
          title: title,
          subtitle: '${file.filename} · $size · Cancelled\nSelect to remove from this list',
          leading: const Icon(Icons.cancel_outlined, color: Colors.white54),
          onSelect: () => downloads.dismiss(task.id),
        ),
      _ => SystemRow(
          title: title,
          subtitle: '${file.filename} · $size · ${task.statusText}\nSelect to cancel',
          leading: const Icon(Icons.downloading_rounded, color: Colors.white),
          progress: task.status == SystemFileTaskStatus.queued ? null : task.progress,
          onSelect: () => downloads.cancel(task.id),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(romDropControllerProvider).valueOrNull;
    if (controller == null) {
      return const SystemScreen(title: 'Transfers', loading: true);
    }
    _attach(controller);
    final downloads = controller.downloads;
    final tasks = downloads.tasks;
    final finished = tasks.where((t) => t.status.finished &&
        t.status != SystemFileTaskStatus.failed).toList();
    return SystemScreen(
      title: 'Transfers',
      subtitle: 'System files being downloaded from RomDrop to this device.',
      message: tasks.isEmpty
          ? const SystemMessage(Icons.inbox_outlined, 'Nothing here',
              'Downloads you start under System Files show up here.')
          : null,
      x: finished.isEmpty
          ? null
          : SystemHudAction('Clear finished', () {
              for (final task in finished) {
                downloads.dismiss(task.id);
              }
            }),
      rows: [for (final task in tasks) _row(downloads, task)],
    );
  }
}
