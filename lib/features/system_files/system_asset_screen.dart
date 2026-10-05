import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/romdrop_models.dart';
import '../../providers/romdrop_providers.dart';
import '../../services/romdrop/romdrop_api_service.dart';
import '../../services/romdrop/romdrop_controller.dart';
import '../../services/romdrop/system_file_download_manager.dart';
import '../../services/romdrop/system_file_storage.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/console_notification.dart';
import '../emulators/emulator_steps_screen.dart';
import 'system_destinations_screen.dart';
import 'widgets/system_screen.dart';

List<SystemBadge> versionBadges(SystemAssetVersion version) => [
      if (version.preferred) SystemBadge.preferred,
      if (version.pinned) SystemBadge.pinned,
      if (version.deprecated) SystemBadge.deprecated,
    ];

/// System Files > … > asset: what it is, and its versions. The preferred
/// version is listed first; older ones stay selectable.
class SystemAssetScreen extends ConsumerStatefulWidget {
  const SystemAssetScreen({super.key, required this.assetId, this.summary});

  final String assetId;

  /// The asset as the list knew it, shown until the versions arrive.
  final SystemAsset? summary;

  @override
  ConsumerState<SystemAssetScreen> createState() => _SystemAssetScreenState();
}

class _SystemAssetScreenState extends ConsumerState<SystemAssetScreen> {
  SystemAsset? _asset;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _asset = widget.summary;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = await ref.read(romDropControllerProvider.future);
      final api = controller.api;
      if (api == null) {
        throw const RomDropException(RomDropErrorKind.notConfigured,
            'Connect to RomDrop first (Settings > RomDrop).');
      }
      final asset = await api.asset(widget.assetId);
      if (!mounted) return;
      setState(() {
        _asset = asset;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = getUserFriendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = _asset;
    final saved = ref.watch(romDropControllerProvider).valueOrNull?.saved;
    final versions = [
      ...?asset?.versions.where((v) => v.preferred),
      ...?asset?.versions.where((v) => !v.preferred),
    ];
    return SystemScreen(
      title: asset?.name ?? 'System file',
      subtitle: asset == null
          ? null
          : '${asset.platformName} · ${asset.kind.label}',
      loading: _loading && versions.isEmpty,
      message: _error == null
          ? null
          : SystemMessage(Icons.error_outline, 'Could not load this file',
              _error, Colors.redAccent),
      selectLabel: 'Open',
      x: SystemHudAction('Refresh', _load),
      details: asset == null
          ? null
          : SystemFacts([
              ('About', asset.notes),
              ('Region', asset.region),
              ('Model', asset.model),
              if (asset.sensitive)
                ('Sensitive', 'Yes. Keep it private; only devices you allowed can get it.'),
              ('After downloading', asset.afterDownload),
            ]),
      rows: [
        for (final version in versions)
          SystemRow(
            title: version.displayLabel,
            badges: [
              ...versionBadges(version),
              if (saved != null &&
                  version.files.isNotEmpty &&
                  version.files.every((file) => saved[file.id] != null))
                SystemBadge.onDevice,
            ],
            subtitle: [
              if (version.files.length == 1)
                version.files.first.filename
              else
                '${version.files.length} files',
              formatSystemFileSize(version.size),
              if (version.addedOn.isNotEmpty) 'added ${version.addedOn}',
            ].join(' · '),
            onSelect: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) =>
                      SystemVersionScreen(asset: asset!, version: version)));
              if (mounted) setState(() {});
            },
          ),
        if (_error != null)
          SystemRow(
            title: 'Try again',
            leading: const Icon(Icons.refresh_rounded, color: Colors.white),
            onSelect: _load,
          ),
      ],
    );
  }
}

/// System Files > … > asset > version: its files, with the download action.
///
/// A finished download means "saved in the folder you chose". It never means
/// the emulator has the file: that is a separate step the user does in the
/// emulator and can tick off here. There is nothing to launch.
class SystemVersionScreen extends ConsumerStatefulWidget {
  const SystemVersionScreen(
      {super.key, required this.asset, required this.version});

  final SystemAsset asset;
  final SystemAssetVersion version;

  @override
  ConsumerState<SystemVersionScreen> createState() =>
      _SystemVersionScreenState();
}

class _SystemVersionScreenState extends ConsumerState<SystemVersionScreen> {
  RomDropController? _controller;
  final Map<String, LocalFileState> _local = {};

  SystemAsset get _asset => widget.asset;
  SystemAssetVersion get _version => widget.version;

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    _controller?.downloads.removeListener(_changed);
    _controller?.saved.removeListener(_refreshLocal);
    _controller?.destinations.removeListener(_changed);
  }

  void _attach(RomDropController controller) {
    if (identical(controller, _controller)) return;
    _detach();
    _controller = controller;
    controller.downloads.addListener(_changed);
    controller.saved.addListener(_refreshLocal);
    controller.destinations.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshLocal());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshLocal() async {
    final controller = _controller;
    if (controller == null) return;
    for (final file in _version.files) {
      final state = await controller.localState(file);
      if (!mounted) return;
      _local[file.id] = state;
    }
    setState(() {});
  }

  void _notify(String message, {bool error = false}) {
    if (mounted) showConsoleNotification(context, message: message, isError: error);
  }

  Future<bool> _confirm(String title, String detail, String action) async =>
      await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => EmulatorStepsScreen(
              title: title,
              intro: detail,
              steps: const [],
              confirmLabel: action))) ??
      false;

  /// Asks for a folder and stores it where the current one came from: the
  /// platform's own folder if it has one, otherwise the default.
  Future<SystemFileFolder?> _pickFolder({String? initialUri}) async {
    final controller = _controller!;
    try {
      final picked = await controller.storage.pickFolder(initialUri: initialUri);
      if (picked == null) return null;
      if (controller.destinations.platformOverride(_asset.platformId) != null) {
        await controller.destinations.setPlatform(_asset.platformId, picked);
      } else {
        await controller.destinations.setDefault(picked);
      }
      return picked;
    } catch (e) {
      _notify('Could not open the folder picker: ${getUserFriendlyError(e, returnRawOnNoMatch: true)}',
          error: true);
      return null;
    }
  }

  /// Starts the download of [file], asking first where a question is due.
  /// False when it did not start: the user backed out, or it cannot.
  Future<bool> _download(SystemFileInfo file) async {
    final controller = _controller!;
    if (!file.available) {
      _notify('This file is not available on the server right now. Ask for a rescan in RomDrop.',
          error: true);
      return false;
    }
    var folder = controller.destinations.resolve(_asset.platformId);
    if (folder == null) {
      final choose = await _confirm(
          'Where should system files go?',
          'Pick a folder on this device. Choose one your emulator can read, or one you will import from. '
              'Android does not let apps write into another app\'s Android/data folder.',
          'Choose folder');
      if (!choose) return false;
      folder = await _pickFolder();
      if (folder == null) return false;
    }
    try {
      var state = await controller.checkDestination(file, folder);
      if (state == DestinationState.noAccess) {
        final again = await _confirm(
            'Folder access was lost',
            'R-Shop can no longer write to "${folder.name}". That happens when the folder is moved or deleted, '
                'or access is withdrawn in Android\'s settings. Nothing was downloaded.',
            'Choose folder again');
        if (!again) return false;
        folder = await _pickFolder(initialUri: folder.uri);
        if (folder == null) return false;
        state = await controller.checkDestination(file, folder);
        if (state == DestinationState.noAccess) {
          _notify('R-Shop still has no access to that folder.', error: true);
          return false;
        }
      }
      var replace = false;
      if (state == DestinationState.sameFile) {
        await controller.adoptExisting(asset: _asset, file: file, folder: folder);
        _notify('${file.relativePath} is already in ${folder.name} with the same contents.');
        return true;
      }
      if (state == DestinationState.differentFile) {
        replace = await _confirm(
            'Replace ${file.relativePath}?',
            'A different file named "${file.relativePath}" is already in "${folder.name}". '
                'Replacing it cannot be undone. Choose another folder under Destinations to keep both.',
            'Replace');
        if (!replace) return false;
      }
      controller.downloads.enqueue(SystemFileRequest(
        file: file,
        assetId: _asset.id,
        assetName: _asset.name,
        platformId: _asset.platformId,
        versionLabel: _version.displayLabel,
        folder: folder,
        replace: replace,
      ));
      return true;
    } catch (e) {
      _notify(getUserFriendlyError(e, returnRawOnNoMatch: true), error: true);
      return false;
    }
  }

  /// Starts every file of this version that is not on the device yet. Stops
  /// asking as soon as the user backs out of a question.
  Future<void> _downloadAll() async {
    final controller = _controller!;
    for (final file in _version.files) {
      final task = controller.downloads.task(file.id);
      final running = task != null && !task.status.finished;
      final saved = controller.saved[file.id] != null &&
          _local[file.id] == LocalFileState.saved;
      if (running || saved || !file.available) continue;
      if (!await _download(file) || !mounted) return;
    }
  }

  SystemRow _fileRow(SystemFileInfo file) {
    final controller = _controller!;
    final task = controller.downloads.task(file.id);
    final record = controller.saved[file.id];
    final local = _local[file.id];
    final checksum = 'SHA-256 ${file.sha256}';
    final size = formatSystemFileSize(file.size);

    if (task != null && !task.status.finished) {
      return SystemRow(
        title: file.relativePath,
        subtitle: '$size · ${task.statusText}\nSelect to cancel',
        leading: const Icon(Icons.downloading_rounded, color: Colors.white),
        progress: task.status == SystemFileTaskStatus.queued ? null : task.progress,
        onSelect: () => controller.downloads.cancel(file.id),
      );
    }
    if (task != null && task.status == SystemFileTaskStatus.failed) {
      return SystemRow(
        title: file.relativePath,
        subtitle: '$size · ${task.error ?? 'Failed'}\nSelect to continue the download',
        leading: const Icon(Icons.error_outline, color: Colors.redAccent),
        onSelect: () => controller.downloads.retry(file.id),
      );
    }
    if (!file.available) {
      return SystemRow(
        title: file.relativePath,
        subtitle: '$size · Not available: the stored file changed or is missing on the server',
        leading: const Icon(Icons.block_rounded, color: Colors.redAccent),
      );
    }
    if (record != null && local == null) {
      // Whether it is still in the folder is being looked up.
      return SystemRow(
        title: file.relativePath,
        subtitle: '$size · Checking ${record.folderName}…\n$checksum',
        leading: const Icon(Icons.hourglass_empty_rounded, color: Colors.white54),
      );
    }
    if (record != null && local == LocalFileState.saved) {
      return SystemRow(
        title: file.relativePath,
        badges: const [SystemBadge.onDevice],
        subtitle: '$size · Saved to ${record.folderName}\n$checksum',
        leading: const Icon(Icons.check_circle_outline, color: Colors.greenAccent),
        onSelect: () => _download(file),
      );
    }
    if (record != null && local == LocalFileState.gone) {
      return SystemRow(
        title: file.relativePath,
        subtitle:
            '$size · Was saved to ${record.folderName}, but is no longer there\nSelect to download again',
        leading: const Icon(Icons.help_outline_rounded, color: Colors.amber),
        onSelect: () => _download(file),
      );
    }
    return SystemRow(
      title: file.relativePath,
      subtitle: '$size · Not on this device\n$checksum',
      leading: const Icon(Icons.download_rounded, color: Colors.white),
      onSelect: () => _download(file),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(romDropControllerProvider).valueOrNull;
    if (controller == null) {
      return SystemScreen(title: _asset.name, loading: true);
    }
    _attach(controller);
    final folder = controller.destinations.resolve(_asset.platformId);
    final files = _version.files;
    final allSaved = files.isNotEmpty &&
        files.every((file) =>
            controller.saved[file.id] != null &&
            _local[file.id] == LocalFileState.saved);
    final imported = allSaved &&
        files.every((file) => controller.saved[file.id]!.importConfirmed);

    return SystemScreen(
      title: '${_asset.name} · ${_version.displayLabel}',
      subtitle: '${_asset.platformName} · ${_asset.kind.label}',
      selectLabel: 'Select',
      x: files.length > 1 && !allSaved
          ? SystemHudAction('Download all', _downloadAll)
          : null,
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, children: [
            for (final badge in [
              ...versionBadges(_version),
              if (_asset.sensitive) SystemBadge.sensitive
            ])
              Chip(
                label: Text(badge.label,
                    style: TextStyle(color: badge.color, fontSize: 11)),
                backgroundColor: Colors.transparent,
                side: BorderSide(color: badge.color.withValues(alpha: 0.7)),
                visualDensity: VisualDensity.compact,
              ),
          ]),
          SystemFacts([
            ('Version', _version.label.isEmpty ? 'Unknown' : _version.label),
            ('Added', _version.addedOn),
            ('Region', _asset.region),
            ('Model', _asset.model),
            ('Version notes', _version.notes),
            ('About', _asset.notes),
            ('After downloading', _asset.afterDownload),
          ]),
        ],
      ),
      rows: [
        for (final file in files) _fileRow(file),
        SystemRow(
          title: folder == null ? 'Choose where to save' : 'Saves to ${folder.name}',
          subtitle: 'Change the folder for ${_asset.platformName} or for all system files',
          leading: const Icon(Icons.folder_open_rounded, color: Colors.white54),
          onSelect: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SystemDestinationsScreen(
                  platformId: _asset.platformId,
                  platformName: _asset.platformName))),
        ),
        if (allSaved)
          SystemRow(
            title: imported
                ? 'Imported in my emulator: yes'
                : 'Imported in my emulator: not yet',
            subtitle:
                'Your own note. R-Shop saved the file; it cannot see whether the emulator has taken it in.',
            leading: Icon(
                imported ? Icons.task_alt_rounded : Icons.radio_button_unchecked,
                color: imported ? Colors.greenAccent : Colors.white54),
            onSelect: () async {
              for (final file in files) {
                await controller.setImportConfirmed(file.id, !imported);
              }
            },
          ),
      ],
    );
  }
}
