import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class RecentlyPlayedEntry {
  final String systemId;
  final String filename;
  final DateTime playedAt;

  const RecentlyPlayedEntry(this.systemId, this.filename, this.playedAt);
}

/// Games launched from R-Shop, newest first. Emulators do not report play
/// sessions back, so "played" means "started from here".
class RecentlyPlayedStore {
  RecentlyPlayedStore(this._prefs);
  final SharedPreferences _prefs;

  static const _key = 'recently_played';
  static const maxEntries = 20;

  List<RecentlyPlayedEntry> load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          RecentlyPlayedEntry(
            (e as Map)['s'] as String,
            e['f'] as String,
            DateTime.fromMillisecondsSinceEpoch(e['t'] as int),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> record(String systemId, String filename, {DateTime? at}) {
    final entries = [
      RecentlyPlayedEntry(systemId, filename, at ?? DateTime.now()),
      ...load().where((e) => e.systemId != systemId || e.filename != filename),
    ].take(maxEntries);
    return _prefs.setString(
        _key,
        jsonEncode([
          for (final e in entries)
            {
              's': e.systemId,
              'f': e.filename,
              't': e.playedAt.millisecondsSinceEpoch
            },
        ]));
  }
}
