import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/romdrop_models.dart';
import '../../providers/romdrop_providers.dart';
import '../../services/romdrop/romdrop_api_service.dart';
import '../../utils/friendly_error.dart';
import 'system_asset_screen.dart';
import 'widgets/system_screen.dart';

/// System Files > platform: BIOS, Firmware, Keys, Other.
class SystemKindsScreen extends StatelessWidget {
  const SystemKindsScreen({super.key, required this.platform});

  final SystemPlatform platform;

  @override
  Widget build(BuildContext context) {
    final hidden = platform.hiddenSensitiveCount;
    return SystemScreen(
      title: platform.name,
      subtitle: 'System files',
      selectLabel: 'Open',
      message: hidden > 0
          ? SystemMessage(
              Icons.visibility_off_outlined,
              '$hidden sensitive ${hidden == 1 ? 'file is' : 'files are'} hidden',
              'This device is not allowed sensitive files such as keys. Allow it in RomDrop under Devices.',
              Colors.amber)
          : null,
      rows: [
        for (final kind in SystemFileKind.values)
          if (platform.count(kind) > 0)
            SystemRow(
              title: kind.label,
              leading: Icon(kind.icon, color: Colors.white70),
              trailing: '${platform.count(kind)}',
              onSelect: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) =>
                      SystemAssetsScreen(platform: platform, kind: kind))),
            ),
      ],
    );
  }
}

/// System Files > platform > kind: the assets, each with its preferred
/// version summarised.
class SystemAssetsScreen extends ConsumerStatefulWidget {
  const SystemAssetsScreen(
      {super.key, required this.platform, required this.kind});

  final SystemPlatform platform;
  final SystemFileKind kind;

  @override
  ConsumerState<SystemAssetsScreen> createState() => _SystemAssetsScreenState();
}

class _SystemAssetsScreenState extends ConsumerState<SystemAssetsScreen> {
  List<SystemAsset>? _assets;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
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
      final assets =
          await api.assets(platform: widget.platform.id, kind: widget.kind);
      if (!mounted) return;
      setState(() {
        _assets = assets;
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
    final saved = ref.watch(romDropControllerProvider).valueOrNull?.saved;
    final assets = _assets;
    SystemMessage? message;
    if (_error != null) {
      message = SystemMessage(Icons.error_outline,
          'Could not load ${widget.kind.label}', _error, Colors.redAccent);
    } else if (assets != null && assets.isEmpty) {
      message = SystemMessage(Icons.inbox_outlined,
          'No ${widget.kind.label} files for ${widget.platform.name}');
    }
    return SystemScreen(
      title: '${widget.platform.name} · ${widget.kind.label}',
      loading: _loading && assets == null,
      message: message,
      selectLabel: 'Open',
      x: SystemHudAction('Refresh', _load),
      rows: [
        for (final asset in assets ?? const <SystemAsset>[])
          SystemRow(
            title: asset.name,
            subtitle: [
              if (asset.preferredVersion != null) ...[
                asset.preferredVersion!.displayLabel,
                if (asset.preferredVersion!.files.length == 1)
                  asset.preferredVersion!.files.first.filename
                else
                  '${asset.preferredVersion!.files.length} files',
                formatSystemFileSize(asset.preferredVersion!.size),
              ],
              if (asset.detailLine.isNotEmpty) asset.detailLine,
            ].join(' · '),
            leading: Icon(asset.kind.icon, color: Colors.white70),
            badges: [
              if (asset.sensitive) SystemBadge.sensitive,
              if (saved != null &&
                  (asset.preferredVersion?.files ?? const [])
                      .any((file) => saved[file.id] != null))
                SystemBadge.onDevice,
            ],
            trailing: asset.versionCount > 1
                ? '${asset.versionCount} versions'
                : null,
            onSelect: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => SystemAssetScreen(assetId: asset.id, summary: asset)));
              if (mounted) setState(() {}); // saved-on-device badge may have changed
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
