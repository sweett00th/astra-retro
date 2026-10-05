import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/romdrop_models.dart';
import '../../providers/romdrop_providers.dart';
import '../../services/romdrop/romdrop_api_service.dart';
import '../../services/romdrop/romdrop_controller.dart';
import '../../utils/friendly_error.dart';
import 'romdrop_connection_screen.dart';
import 'system_assets_screen.dart';
import 'system_destinations_screen.dart';
import 'system_transfers_screen.dart';
import 'widgets/system_screen.dart';

/// Home > System Files: the platforms RomDrop holds BIOS, firmware or keys
/// for. Support files only; none of this is a game or enters the library.
class SystemFilesScreen extends ConsumerStatefulWidget {
  const SystemFilesScreen({super.key});

  @override
  ConsumerState<SystemFilesScreen> createState() => _SystemFilesScreenState();
}

Widget platformIcon(SystemPlatform platform) {
  final system = platform.system;
  if (system == null) {
    return const Icon(Icons.memory_rounded, color: Colors.white54, size: 28);
  }
  return SvgPicture.asset(
    system.iconAssetPath,
    fit: BoxFit.contain,
    colorFilter: ColorFilter.mode(system.iconColor, BlendMode.srcIn),
    placeholderBuilder: (_) =>
        const Icon(Icons.memory_rounded, color: Colors.white54, size: 28),
  );
}

class _SystemFilesScreenState extends ConsumerState<SystemFilesScreen> {
  RomDropController? _controller;
  List<SystemPlatform>? _platforms;
  RomDropCapabilities? _capabilities;
  RomDropException? _error;
  bool _loading = false;
  int _request = 0;

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _controller?.downloads.removeListener(_onTransfersChanged);
    super.dispose();
  }

  void _attach(RomDropController controller) {
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_onControllerChanged);
    _controller?.downloads.removeListener(_onTransfersChanged);
    _controller = controller
      ..addListener(_onControllerChanged)
      ..downloads.addListener(_onTransfersChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _onControllerChanged() => _load();

  void _onTransfersChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (!mounted) return;
    final api = _controller?.api;
    final request = ++_request;
    if (api == null) {
      if (mounted) {
        setState(() {
          _platforms = null;
          _capabilities = null;
          _error = null;
          _loading = false;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final capabilities = await api.capabilities();
      final platforms = capabilities.libraryAvailable
          ? await api.platforms()
          : const <SystemPlatform>[];
      if (!mounted || request != _request) return;
      setState(() {
        _capabilities = capabilities;
        _platforms = platforms;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _platforms = null;
        _error = e is RomDropException
            ? e
            : RomDropException(
                RomDropErrorKind.server, getUserFriendlyError(e));
      });
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  SystemMessage _errorMessage(RomDropException error) {
    final (icon, title) = switch (error.kind) {
      RomDropErrorKind.offline => (Icons.wifi_off_rounded, 'RomDrop is not reachable'),
      RomDropErrorKind.unauthorized => (
          Icons.lock_outline_rounded,
          'RomDrop no longer accepts this device'
        ),
      RomDropErrorKind.certificate => (
          Icons.gpp_maybe_outlined,
          'RomDrop\'s certificate is not accepted'
        ),
      RomDropErrorKind.libraryOffline => (
          Icons.cloud_off_rounded,
          'The system-file library is offline'
        ),
      _ => (Icons.error_outline, 'Could not load system files'),
    };
    return SystemMessage(icon, title, error.message, Colors.redAccent);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(romDropControllerProvider);
    final controller = async.valueOrNull;
    if (controller == null) {
      return SystemScreen(
        title: 'System Files',
        loading: async.isLoading,
        message: async.hasError
            ? SystemMessage(Icons.error_outline, 'Could not open System Files',
                getUserFriendlyError(async.error), Colors.redAccent)
            : null,
      );
    }
    _attach(controller);

    final connectionRow = SystemRow(
      title: 'RomDrop connection',
      subtitle: controller.configured
          ? '${controller.connection!.baseUrl} as "${controller.connection!.deviceName}"'
          : 'Not connected',
      leading: const Icon(Icons.dns_outlined, color: Colors.white54),
      onSelect: () => _open(const RomDropConnectionScreen()),
    );
    const subtitle =
        'BIOS, firmware and keys from your RomDrop server. These are support files for emulators, not games.';

    if (!controller.configured) {
      return SystemScreen(
        title: 'System Files',
        subtitle: subtitle,
        message: const SystemMessage(
            Icons.link_off_rounded,
            'Not connected to RomDrop',
            'Pair this device with your RomDrop server to browse and download the system files you keep there.'),
        rows: [
          SystemRow(
            title: 'Connect to RomDrop',
            subtitle: 'Server address and a pairing code from RomDrop > Devices',
            leading: const Icon(Icons.add_link_rounded, color: Colors.white),
            onSelect: () => _open(const RomDropConnectionScreen()),
          ),
        ],
      );
    }

    final tasks = controller.downloads.tasks;
    final active = tasks.where((t) => !t.status.finished).length;
    final platforms = _platforms;
    final capabilities = _capabilities;
    final hidden = platforms == null
        ? 0
        : platforms.fold<int>(0, (sum, p) => sum + p.hiddenSensitiveCount);

    SystemMessage? message;
    if (_error != null) {
      message = _errorMessage(_error!);
    } else if (capabilities != null && !capabilities.libraryAvailable) {
      message = SystemMessage(
          Icons.cloud_off_rounded,
          'The system-file library is offline',
          capabilities.libraryReason ??
              'Check the Status page of RomDrop\'s admin site.',
          Colors.orangeAccent);
    } else if (platforms != null && platforms.isEmpty) {
      message = const SystemMessage(Icons.inbox_outlined, 'No system files yet',
          'Upload BIOS, firmware or key files in RomDrop\'s admin page; they will appear here.');
    } else if (hidden > 0) {
      message = SystemMessage(
          Icons.visibility_off_outlined,
          '$hidden sensitive ${hidden == 1 ? 'file is' : 'files are'} hidden',
          'This device is not allowed sensitive files such as keys. Allow it in RomDrop under Devices.',
          Colors.amber);
    }

    return SystemScreen(
      title: 'System Files',
      subtitle: subtitle,
      loading: _loading && platforms == null,
      message: message,
      selectLabel: 'Open',
      x: SystemHudAction('Refresh', _load),
      rows: [
        for (final platform in platforms ?? const <SystemPlatform>[])
          if (platform.assetCount > 0)
            SystemRow(
              title: platform.name,
              subtitle: [
                for (final kind in SystemFileKind.values)
                  if (platform.count(kind) > 0)
                    '${kind.label} ${platform.count(kind)}'
              ].join(' · '),
              leading: platformIcon(platform),
              trailing:
                  '${platform.assetCount} ${platform.assetCount == 1 ? 'file' : 'files'}',
              onSelect: () => _open(SystemKindsScreen(platform: platform)),
            ),
        if (_error != null)
          SystemRow(
            title: 'Try again',
            leading: const Icon(Icons.refresh_rounded, color: Colors.white),
            onSelect: _load,
          ),
        if (tasks.isNotEmpty)
          SystemRow(
            title: 'Transfers',
            subtitle: active > 0
                ? '$active in progress'
                : 'Finished and failed system-file downloads',
            leading: const Icon(Icons.swap_vert_rounded, color: Colors.white54),
            trailing: '${tasks.length}',
            onSelect: () => _open(const SystemTransfersScreen()),
          ),
        SystemRow(
          title: 'Destinations',
          subtitle: controller.destinations.defaultFolder == null
              ? 'Choose where system files are saved on this device'
              : 'Default: ${controller.destinations.defaultFolder!.name}',
          leading: const Icon(Icons.folder_open_rounded, color: Colors.white54),
          onSelect: () => _open(const SystemDestinationsScreen()),
        ),
        connectionRow,
      ],
    );
  }
}
