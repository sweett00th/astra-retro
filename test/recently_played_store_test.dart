import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/services/recently_played_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late RecentlyPlayedStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RecentlyPlayedStore(await SharedPreferences.getInstance());
  });

  test('starts empty', () {
    expect(store.load(), isEmpty);
  });

  test('newest launch comes first', () async {
    await store.record('gc', 'Sunshine.ciso', at: DateTime(2026, 1, 1));
    await store.record('n64', 'Paper Mario.z64', at: DateTime(2026, 1, 2));
    final entries = store.load();
    expect(entries.map((e) => e.filename), ['Paper Mario.z64', 'Sunshine.ciso']);
    expect(entries.first.systemId, 'n64');
    expect(entries.first.playedAt, DateTime(2026, 1, 2));
  });

  test('playing a game again moves it to the front without duplicating',
      () async {
    await store.record('gc', 'Sunshine.ciso');
    await store.record('n64', 'Paper Mario.z64');
    await store.record('gc', 'Sunshine.ciso');
    expect(store.load().map((e) => e.filename),
        ['Sunshine.ciso', 'Paper Mario.z64']);
  });

  test('the same filename on two systems is two entries', () async {
    await store.record('gb', 'Tetris.zip');
    await store.record('nes', 'Tetris.zip');
    expect(store.load().map((e) => e.systemId), ['nes', 'gb']);
  });

  test('keeps only the most recent entries', () async {
    for (var i = 0; i < RecentlyPlayedStore.maxEntries + 5; i++) {
      await store.record('gc', 'Game $i.iso');
    }
    final entries = store.load();
    expect(entries.length, RecentlyPlayedStore.maxEntries);
    expect(entries.first.filename,
        'Game ${RecentlyPlayedStore.maxEntries + 4}.iso');
  });

  test('unreadable saved data is treated as empty', () async {
    SharedPreferences.setMockInitialValues({'recently_played': 'not json'});
    final prefs = await SharedPreferences.getInstance();
    expect(RecentlyPlayedStore(prefs).load(), isEmpty);
  });
}
