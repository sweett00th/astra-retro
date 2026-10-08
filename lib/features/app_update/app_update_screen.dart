import 'package:flutter/material.dart';

import '../../models/romdrop_models.dart' show formatSystemFileSize;
import '../../services/app_update_service.dart';
import '../system_files/widgets/system_screen.dart';
import 'app_update_controller.dart';

/// Settings > About > App update: installs the newest build the fork's
/// repository has published, without a cable or a browser.
class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key, this.controller});

  /// Supplied by tests; the screen makes its own otherwise.
  final AppUpdateController? controller;

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen>
    with WidgetsBindingObserver {
  late final AppUpdateController _controller =
      widget.controller ?? AppUpdateController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_changed);
    _controller.check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Android's "install unknown apps" page.
    if (state == AppLifecycleState.resumed) _controller.recheckPermission();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _published(AppRelease release) {
    final at = release.publishedAt?.toLocal();
    if (at == null) return '';
    return 'published ${at.day} ${_months[at.month - 1]} ${at.year}';
  }

  String get _installedLine {
    final installed = _controller.installed;
    if (installed == null) return 'Builds come from this app\'s GitHub releases.';
    final build = installed.build == null ? '' : ' (build ${installed.build})';
    return 'Installed: ${installed.version}$build';
  }

  SystemRow get _checkAgain => SystemRow(
        title: 'Check again',
        leading: const Icon(Icons.refresh_rounded, color: Colors.white70),
        onSelect: _controller.check,
      );

  @override
  Widget build(BuildContext context) {
    final release = _controller.release;
    switch (_controller.stage) {
      case AppUpdateStage.checking:
        return SystemScreen(
            title: 'App update', subtitle: _installedLine, loading: true);

      case AppUpdateStage.upToDate:
        return SystemScreen(
          title: 'App update',
          subtitle: _installedLine,
          message: SystemMessage(
              Icons.check_circle_outline_rounded,
              'This is the latest build',
              release == null
                  ? 'No build has been published yet.'
                  : 'The newest one is ${release.label}, ${_published(release)}.',
              Colors.greenAccent),
          rows: [_checkAgain],
        );

      case AppUpdateStage.available:
        return SystemScreen(
          title: 'App update',
          subtitle: _installedLine,
          details: release!.notes.isEmpty ? null : _Notes(release.notes),
          selectLabel: 'Choose',
          rows: [
            SystemRow(
              title: 'Download and install ${release.label}',
              subtitle: [
                formatSystemFileSize(release.apkSize),
                _published(release),
              ].where((part) => part.isNotEmpty).join(' · '),
              leading: const Icon(Icons.system_update_rounded,
                  color: Colors.white70),
              onSelect: _controller.download,
            ),
            _checkAgain,
          ],
        );

      case AppUpdateStage.downloading:
        return SystemScreen(
          title: 'App update',
          subtitle: _installedLine,
          x: SystemHudAction('Cancel', _controller.cancelDownload),
          rows: [
            SystemRow(
              title: 'Downloading ${release!.label}',
              subtitle: '${formatSystemFileSize(_controller.receivedBytes)} '
                  'of ${formatSystemFileSize(release.apkSize)}',
              leading: const Icon(Icons.downloading_rounded,
                  color: Colors.white70),
              progress: _controller.progress,
            ),
          ],
        );

      case AppUpdateStage.needsPermission:
        return SystemScreen(
          title: 'App update',
          subtitle: _installedLine,
          message: const SystemMessage(
              Icons.lock_outline_rounded,
              'Android needs your permission first',
              'Allow this app to install apps on the next page, then come back. The update carries on from here.',
              Colors.amber),
          selectLabel: 'Choose',
          rows: [
            SystemRow(
              title: 'Open Android settings',
              leading: const Icon(Icons.settings_rounded, color: Colors.white70),
              onSelect: _controller.openInstallPermission,
            ),
            SystemRow(
              title: 'Install ${release!.label}',
              leading: const Icon(Icons.system_update_rounded,
                  color: Colors.white70),
              onSelect: _controller.install,
            ),
          ],
        );

      case AppUpdateStage.readyToInstall:
        return SystemScreen(
          title: 'App update',
          subtitle: _installedLine,
          message: SystemMessage(
              Icons.download_done_rounded,
              '${release!.label} is downloaded and verified',
              'Android asks you to confirm the update, then restarts the app. Settings and downloads are kept.'),
          selectLabel: 'Choose',
          rows: [
            SystemRow(
              title: 'Install ${release.label}',
              leading: const Icon(Icons.system_update_rounded,
                  color: Colors.white70),
              onSelect: _controller.install,
            ),
          ],
        );

      case AppUpdateStage.failed:
        return SystemScreen(
          title: 'App update',
          subtitle: _installedLine,
          message: SystemMessage(Icons.error_outline_rounded,
              'The update did not go through', _controller.error, Colors.redAccent),
          rows: [
            SystemRow(
              title: 'Try again',
              leading: const Icon(Icons.refresh_rounded, color: Colors.white70),
              onSelect: _controller.check,
            ),
          ],
        );
    }
  }
}

/// What the release says about itself, as plain text.
class _Notes extends StatelessWidget {
  const _Notes(this.notes);
  final String notes;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        notes,
        maxLines: 16,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
      ),
    );
  }
}
