import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/romdrop_providers.dart';
import '../../services/romdrop/romdrop_controller.dart';
import '../../services/romdrop/system_file_storage.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/console_notification.dart';
import 'widgets/system_screen.dart';

/// Where system files are saved on this device: one default folder and,
/// optionally, a folder of its own for a platform.
///
/// Every folder is picked with Android's folder picker, which is what grants
/// R-Shop access to it. Android does not offer another app's Android/data
/// folder there, so files go to a shared folder and are imported from it.
class SystemDestinationsScreen extends ConsumerStatefulWidget {
  const SystemDestinationsScreen({super.key, this.platformId, this.platformName});

  /// When opened from a platform's file, that platform's override is shown.
  final String? platformId;
  final String? platformName;

  @override
  ConsumerState<SystemDestinationsScreen> createState() =>
      _SystemDestinationsScreenState();
}

class _SystemDestinationsScreenState
    extends ConsumerState<SystemDestinationsScreen> {
  RomDropController? _controller;
  final Map<String, bool> _writable = {};

  @override
  void dispose() {
    _controller?.destinations.removeListener(_refresh);
    super.dispose();
  }

  void _attach(RomDropController controller) {
    if (identical(controller, _controller)) return;
    _controller?.destinations.removeListener(_refresh);
    _controller = controller..destinations.addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  /// Re-checks each folder's grant, which Android can withdraw at any time.
  Future<void> _refresh() async {
    final controller = _controller;
    if (controller == null) return;
    for (final uri in controller.destinations.uris) {
      bool ok;
      try {
        ok = await controller.storage.canWrite(uri);
      } catch (e) {
        ok = false;
      }
      if (!mounted) return;
      _writable[uri] = ok;
    }
    setState(() {});
  }

  Future<void> _pick({required bool forPlatform}) async {
    final controller = _controller!;
    final destinations = controller.destinations;
    final current = forPlatform
        ? destinations.platformOverride(widget.platformId!)
        : destinations.defaultFolder;
    try {
      final picked =
          await controller.storage.pickFolder(initialUri: current?.uri);
      if (picked == null) return;
      if (forPlatform) {
        await destinations.setPlatform(widget.platformId!, picked);
      } else {
        await destinations.setDefault(picked);
      }
      await _releaseUnused(current);
    } catch (e) {
      if (mounted) {
        showConsoleNotification(context,
            message:
                'Could not use that folder: ${getUserFriendlyError(e, returnRawOnNoMatch: true)}');
      }
    }
  }

  /// Hands back a folder grant nothing refers to any more.
  Future<void> _releaseUnused(SystemFileFolder? folder) async {
    final controller = _controller!;
    if (folder == null || controller.destinations.uris.contains(folder.uri)) {
      return;
    }
    try {
      await controller.storage.release(folder.uri);
    } catch (e) {
      debugPrint('SystemDestinations: release failed: $e');
    }
  }

  Future<void> _clearPlatform() async {
    final controller = _controller!;
    final current = controller.destinations.platformOverride(widget.platformId!);
    await controller.destinations.setPlatform(widget.platformId!, null);
    await _releaseUnused(current);
  }

  String _describe(SystemFileFolder? folder, String whenUnset) {
    if (folder == null) return whenUnset;
    return _writable[folder.uri] == false
        ? '${folder.name}  (access lost; choose it again)'
        : folder.name;
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(romDropControllerProvider).valueOrNull;
    if (controller == null) {
      return const SystemScreen(title: 'Destinations', loading: true);
    }
    _attach(controller);
    final destinations = controller.destinations;
    final platformId = widget.platformId;
    final override =
        platformId == null ? null : destinations.platformOverride(platformId);
    final lost = destinations.uris.any((uri) => _writable[uri] == false);

    return SystemScreen(
      title: 'Destinations',
      subtitle:
          'Folders on this device where system files are saved. Pick a folder your emulator reads, or one you import from. '
          'Android does not let apps write into another app\'s Android/data folder.',
      message: lost
          ? const SystemMessage(
              Icons.folder_off_outlined,
              'Access to a folder was lost',
              'Android withdrew access, or the folder was moved or deleted. Choose it again to keep saving there.',
              Colors.amber)
          : null,
      selectLabel: 'Choose',
      x: override == null ? null : SystemHudAction('Use default', _clearPlatform),
      rows: [
        SystemRow(
          title: 'Default folder',
          subtitle: _describe(destinations.defaultFolder, 'Not chosen yet'),
          leading: const Icon(Icons.folder_rounded, color: Colors.white70),
          onSelect: () => _pick(forPlatform: false),
        ),
        if (platformId != null)
          SystemRow(
            title: '${widget.platformName ?? platformId} folder',
            subtitle: _describe(override, 'Uses the default folder'),
            leading:
                const Icon(Icons.folder_special_rounded, color: Colors.white70),
            onSelect: () => _pick(forPlatform: true),
          ),
        if (override != null)
          SystemRow(
            title: 'Use the default folder for ${widget.platformName ?? platformId}',
            leading: const Icon(Icons.undo_rounded, color: Colors.white54),
            onSelect: _clearPlatform,
          ),
      ],
    );
  }
}
