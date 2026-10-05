import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/romdrop/romdrop_controller.dart';
import '../services/romdrop/system_file_storage.dart';

final systemFileStorageProvider =
    Provider<SystemFileStorage>((ref) => SafSystemFileStorage());

/// RomDrop connection, destinations and system-file transfers. Loaded once;
/// kept for the life of the app so transfers continue across screens.
final romDropControllerProvider = FutureProvider<RomDropController>((ref) async {
  final controller = RomDropController(
    prefs: await SharedPreferences.getInstance(),
    storage: ref.read(systemFileStorageProvider),
  );
  ref.onDispose(controller.dispose);
  await controller.load();
  return controller;
});
