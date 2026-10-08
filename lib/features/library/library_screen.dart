import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/input/input.dart';
import '../../core/responsive/responsive.dart';
import '../../core/util/source_color.dart';
import '../../l10n/app_localizations.dart';
import '../../models/config/app_config.dart';
import '../../models/config/provider_config.dart';
import '../../models/config/source.dart';
import '../../models/custom_shelf.dart';
import '../../models/game_item.dart';
import '../../models/system_model.dart';
import '../../providers/app_providers.dart';
import '../../providers/download_providers.dart';
import '../../providers/installed_files_provider.dart';
import '../../models/ra_models.dart';
import '../../providers/game_providers.dart';
import '../../providers/library_providers.dart';
import '../../providers/rom_status_providers.dart';
import '../../providers/shelf_providers.dart';
import '../../services/config_bootstrap.dart';
import '../../services/database_service.dart';
import '../../services/input_debouncer.dart';
import '../../services/recently_played_store.dart';
import '../../services/rom_manager.dart';
import '../../services/thumbnail_service.dart';
import '../../utils/game_metadata.dart';
import '../../utils/image_helper.dart';
import '../game_detail/game_detail_screen.dart';
import '../../widgets/base_game_card.dart';
import '../../widgets/console_hud.dart';
import '../../widgets/console_notification.dart';
import '../../widgets/download_overlay.dart';
import '../../widgets/exit_confirmation_overlay.dart';
import '../../widgets/quick_menu.dart';
import '../../widgets/selection_aware_item.dart';
import 'library_layout.dart';
import 'shelf_edit_screen.dart';
import 'widgets/library_entry.dart';
import 'widgets/library_section_header.dart';
import 'widgets/library_tabs.dart';
import 'widgets/reorderable_card_wrapper.dart';
import 'widgets/shelf_picker_dialog.dart';

enum ReorderState { none, selecting, grabbed }

class LibraryScreen extends ConsumerStatefulWidget {
  final bool openSearch;
  const LibraryScreen({super.key, this.openSearch = false});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with ConsoleScreenMixin, SearchableScreenMixin {
  // Fixed tabs: All, Installed, Available, Favorites; shelves follow.
  static const _tabAll = 0;
  static const _tabInstalled = 1;
  static const _tabAvailable = 2;
  static const _tabFavorites = 3;
  static const _fixedTabCount = 4;

  /// Covers are portrait box art; tiles match so the art fills them.
  static const _tileAspect = 0.72;
  static const _columnsKey = 'library_covers';
  static const _minColumns = 3;
  static const _maxColumns = 8;

  /// Tile width the default zoom level aims for.
  static const _autoTileWidth = 145.0;

  /// Part of one more tile shown at the right edge of a strip, as a sign
  /// that the row scrolls.
  static const _peek = 0.35;
  static const _maxRecents = 12;
  static const _headerGap = 10.0;
  static const _sectionGap = 18.0;
  static const _recentsGap = 18.0;

  /// Tile outline: on the device and ready to play, or on a source only.
  static const _installedGlow = Colors.greenAccent;
  static const _remoteGlow = Colors.lightBlueAccent;

  static final Map<String, SystemModel> _systemsById = {
    for (final s in SystemModel.supportedSystems) s.id: s,
  };

  int _selectedTab = _tabAll; // fixed tabs, then shelves
  List<CustomShelf> _shelves = [];

  // Reorder mode
  ReorderState _reorderState = ReorderState.none;
  int _grabbedIndex = -1;
  int? _reorderClaimToken;

  // Controller cursor: a recents tile, a platform header or a game tile.
  LibraryCursor _cursor = const LibraryCursor.header(0);
  final ValueNotifier<int> _selectedIdNotifier =
      ValueNotifier(const LibraryCursor.header(0).id);
  int _preferredColumn = 0;
  int _recentMemory = 0;

  /// Tile each platform strip was left on, so returning to a row lands on
  /// the same game.
  final Map<String, int> _stripMemory = {};
  DateTime? _lastMove;

  /// 0 until the first build fits the default to the screen width.
  int _columns = 0;
  String _searchQuery = '';
  bool _isLoading = true;

  final ScrollController _scrollController = ScrollController();
  final ScrollController _recentsController = ScrollController();
  final Map<String, ScrollController> _stripControllers = {};
  final ValueNotifier<bool> _scrollSuppression = ValueNotifier(false);
  Timer? _suppressionTimer;
  bool _programmaticScroll = false;
  int _scrollToken = 0;

  late InputDebouncer _debouncer;

  ProviderSubscription? _installedFilesSubscription;
  ProviderSubscription? _syncSubscription;
  Timer? _reloadDebounce;

  // Raw data from DB
  List<LibraryEntry> _allGames = [];
  Set<String> _installedFiles = {};
  Set<String> _favoriteIds = {};
  List<RecentlyPlayedEntry> _recentlyPlayed = [];
  // Current tab: games in display order, grouped into platform sections
  List<LibraryEntry> _filteredGames = [];
  List<LibrarySection> _sections = [];
  List<LibraryEntry> _recents = [];
  Set<String> _installedKeys = {};
  int _installedCount = 0;
  int _availableCount = 0;
  final Map<int, Set<String>> _collapsedByTab = {};
  // RA match data keyed by filename
  Map<String, RaMatchResult> _raMatches = {};
  final Map<String, List<String>> _coverUrlCache = {};

  // Geometry of the last build; the layout knows where every row is.
  double _side = 0;
  double _spacing = 0;
  double _tileWidth = 0;
  double _recentsHintHeight = 0;
  LibraryMetrics _metrics = const LibraryMetrics(
      recentsHeight: 0,
      headerHeight: 0,
      tileHeight: 0,
      rowSpacing: 0,
      sectionGap: 0);
  late LibraryLayout _layout;

  // Multi-select (bulk uninstall)
  bool _selectMode = false;
  final Set<String> _marked = {};
  bool _confirmUninstall = false;
  bool _uninstalling = false;

  int get _totalTabCount => _fixedTabCount + _shelves.length;

  bool get _isShelfTab => _selectedTab >= _fixedTabCount;

  /// Fixed tabs group games by platform; shelves and search results are one
  /// plain grid.
  bool get _sectioned => !_isShelfTab && _searchQuery.isEmpty;

  bool get _showRecents =>
      _sectioned && _recents.isNotEmpty && _filteredGames.isNotEmpty;

  /// Nothing played yet: the row's place holds a line saying how it fills.
  bool get _showRecentsHint =>
      _sectioned && _recents.isEmpty && _filteredGames.isNotEmpty;

  /// Platforms start expanded; each tab remembers the ones collapsed.
  Set<String> get _collapsed =>
      _collapsedByTab.putIfAbsent(_selectedTab, () => <String>{});

  String _stripId(String sectionKey) => '$_selectedTab/$sectionKey';

  CustomShelf? get _activeShelf {
    if (!_isShelfTab) return null;
    final idx = _selectedTab - _fixedTabCount;
    if (idx < 0 || idx >= _shelves.length) return null;
    return _shelves[idx];
  }

  /// Game under the cursor, or null on a platform header.
  LibraryEntry? get _focusedEntry => switch (_cursor.kind) {
        LibraryCursorKind.game =>
          _cursor.index < _filteredGames.length
              ? _filteredGames[_cursor.index]
              : null,
        LibraryCursorKind.recent =>
          _cursor.index < _recents.length ? _recents[_cursor.index] : null,
        LibraryCursorKind.header => null,
      };

  @override
  String get routeId => 'library';

  @override
  Color get searchAccentColor => Colors.cyanAccent;

  @override
  String get searchHintText => L.of(context).library_searchHint;

  @override
  void onSearchQueryChanged(String query) {
    _searchQuery = query;
    _applyFilters(resetCursor: true);
    _scrollToTop();
  }

  @override
  void onSearchReset() {
    _searchQuery = '';
    _applyFilters();
  }

  @override
  void onSearchSelectionReset() {
    final first = _layout.firstTile;
    if (first != null) _setCursor(first);
  }

  // L1/R1 zoom and L2/R2 tabs are handled by global shortcuts.

  @override
  Map<Type, Action<Intent>> get screenActions {
    return {
        NavigateIntent: OverlayGuardedAction<NavigateIntent>(ref,
          onInvoke: (intent) { _navigate(intent.direction); return null; },
          isEnabledOverride: _reorderOrSearchOrNone,
        ),
        AdjustColumnsIntent: OverlayGuardedAction<AdjustColumnsIntent>(ref,
          onInvoke: (intent) { _adjustColumns(intent.increase); return null; },
          isEnabledOverride: searchOrNone,
        ),
        ConfirmIntent: OverlayGuardedAction<ConfirmIntent>(ref,
          onInvoke: (_) { _handleConfirm(); return null; },
          isEnabledOverride: _reorderOrSearchOrNone,
        ),
        BackIntent: OverlayGuardedAction<BackIntent>(ref,
          onInvoke: (_) { _handleBack(); return null; },
          isEnabledOverride: _reorderOrSearchOrNone,
        ),
        SearchIntent: CallbackAction<SearchIntent>(
          onInvoke: (_) {
            // Y uninstalls the marked games while multi-select is on.
            if (_selectMode) {
              _requestUninstall();
            } else {
              toggleSearch();
            }
            return null;
          },
        ),
        TabLeftIntent: TabLeftAction(ref, onTabLeft: _prevTab),
        TabRightIntent: TabRightAction(ref, onTabRight: _nextTab),
        FavoriteIntent: OverlayGuardedAction<FavoriteIntent>(ref,
          onInvoke: (_) { _handleFavorite(); return null; },
        ),
        ToggleOverlayIntent: ToggleOverlayAction(ref, onToggle: toggleQuickMenu),
      };
  }

  bool _reorderOrSearchOrNone(dynamic priority) {
    if (_reorderState != ReorderState.none) return true;
    return searchOrNone(priority);
  }

  @override
  void initState() {
    super.initState();
    _columns = ref
        .read(storageServiceProvider)
        .getGridColumns(_columnsKey, fallback: 0)
        .clamp(0, _maxColumns);
    _debouncer = ref.read(inputDebouncerProvider);
    _shelves = ref.read(customShelvesProvider);
    _layout = _newLayout();

    initSearch();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
      _installedFilesSubscription = ref.listenManual(installedFilesProvider, (prev, next) {
        if (!mounted) return;
        final data = next.value;
        if (data != null && !setEquals(data.all, _installedFiles)) {
          _installedFiles = data.all;
          _applyFilters();
        }
      });
      // The library is the landing page: pick up games as syncs finish.
      _syncSubscription = ref.listenManual(librarySyncServiceProvider, (prev, next) {
        if (prev == null) return;
        if (prev.completedSystems != next.completedSystems ||
            (prev.isSyncing && !next.isSyncing)) {
          _reloadDebounce?.cancel();
          _reloadDebounce = Timer(const Duration(milliseconds: 600), () {
            if (mounted && !_uninstalling) _loadData(silent: true);
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _exitReorderMode();
    _installedFilesSubscription?.close();
    _syncSubscription?.close();
    _reloadDebounce?.cancel();
    _suppressionTimer?.cancel();
    _debouncer.stopHold();
    _scrollController.dispose();
    _recentsController.dispose();
    for (final controller in _stripControllers.values) {
      controller.dispose();
    }
    disposeSearch();
    _scrollSuppression.dispose();
    _selectedIdNotifier.dispose();
    super.dispose();
  }

  Future<void> _refreshInstalledFiles() async {
    final appConfig =
        ref.read(bootstrappedConfigProvider).value ?? AppConfig.empty;
    final installed = <String>{};
    for (final sysConfig in appConfig.systems) {
      if (sysConfig.targetFolder.isEmpty) continue;
      final dir = Directory(sysConfig.targetFolder);
      if (await dir.exists()) {
        try {
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is File || entity is Directory) {
              installed.add(p.basename(entity.path));
            }
          }
        } catch (e) { debugPrint('LibraryScreen: dir list failed: $e'); }
      }
    }
    if (mounted) {
      setState(() => _installedFiles = installed);
    }
  }

  /// Loads the library from the DB. [silent] refreshes in place (after a
  /// sync or an uninstall) without the spinner or moving the cursor.
  Future<void> _loadData({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);

    final db = DatabaseService();

    // Load all games from DB
    final rawGames = await db.getAllGames();

    // Use centralized installed-files index (provider-driven)
    final installedData = ref.read(installedFilesProvider).value;
    if (installedData != null) {
      _installedFiles = installedData.all;
    } else {
      // Provider not ready yet — fall back to direct scan
      await _refreshInstalledFiles();
    }

    final entries = <LibraryEntry>[];
    for (final row in rawGames) {
      final systemSlug = row['systemSlug'] as String;

      ProviderConfig? providerConfig;
      final pcJson = row['provider_config'] as String?;
      if (pcJson != null) {
        try {
          providerConfig = ProviderConfig.fromJson(
              jsonDecode(pcJson) as Map<String, dynamic>);
        } catch (e) { debugPrint('LibraryScreen: provider config parse failed: $e'); }
      }

      final fname = row['filename'] as String;
      entries.add(LibraryEntry(
        filename: fname,
        displayName: GameMetadata.cleanTitle(fname),
        cardTitle: GameMetadata.fileTitle(fname),
        url: row['url'] as String,
        coverUrl: row['cover_url'] as String?,
        systemSlug: systemSlug,
        providerConfig: providerConfig,
        hasThumbnail: (row['has_thumbnail'] as int?) == 1,
      ));
    }

    if (!mounted) return;

    // Trigger deferred migration from displayName → filename favorites
    final allGameItems = entries.map((e) => GameItem(
      filename: e.filename,
      displayName: e.displayName,
      url: e.url,
    )).toList();
    ref.read(favoriteGamesProvider.notifier).migrateIfNeeded(allGameItems);
    final migratedFavorites = ref.read(favoriteGamesProvider).toSet();

    // Load RA matches for all systems represented in the library
    final raMatches = <String, RaMatchResult>{};
    final storage = ref.read(storageServiceProvider);
    if (storage.getRaEnabled()) {
      final systemSlugs = entries.map((e) => e.systemSlug).toSet();
      final db = DatabaseService();
      for (final slug in systemSlugs) {
        final matches = await db.getRaMatchesForSystem(slug);
        raMatches.addAll(matches);
      }
    }

    final recentlyPlayed = await _loadRecentlyPlayed();

    if (!mounted) return;

    setState(() {
      _allGames = entries;
      _favoriteIds = migratedFavorites;
      _raMatches = raMatches;
      _recentlyPlayed = recentlyPlayed;
      _coverUrlCache.clear();
      _isLoading = false;
    });

    _applyFilters(resetCursor: !silent);

    if (!silent && widget.openSearch) {
      openSearch();
    }
  }

  Future<List<RecentlyPlayedEntry>> _loadRecentlyPlayed() async =>
      RecentlyPlayedStore(await SharedPreferences.getInstance()).load();

  void _applyFilters({bool resetCursor = false}) {
    final previous = _cursor;
    final previousEntry = _focusedEntry?.key;
    final previousSection = previous.kind == LibraryCursorKind.header &&
            previous.index < _sections.length
        ? _sections[previous.index].key
        : null;

    final installedKeys = {
      for (final g in _allGames)
        if (_isGameInstalled(g)) g.key,
    };
    final installed = _deduplicateInstalled(
      _allGames.where((g) => installedKeys.contains(g.key)).toList(),
    );
    final available = _allGames
        .where((g) => g.isRemote && !installedKeys.contains(g.key))
        .toList();

    List<LibraryEntry> games;
    bool isManualSort = false;
    ShelfSortMode? shelfSortMode;

    if (_isShelfTab) {
      final resolved = _resolveShelfGames();
      games = resolved.games;
      isManualSort = resolved.isManualSort;
      shelfSortMode = resolved.shelfSortMode;
    } else {
      games = switch (_selectedTab) {
        _tabInstalled => installed,
        _tabAvailable => available,
        _tabFavorites =>
          _allGames.where((g) => _favoriteIds.contains(g.filename)).toList(),
        _ => List<LibraryEntry>.from(_allGames),
      };
    }

    // Search filter
    if (_searchQuery.isNotEmpty) {
      final query = GameMetadata.normalizeForSearch(_searchQuery);
      games = games
          .where((g) => GameMetadata.normalizeForSearch(g.displayName).contains(query))
          .toList();
    }

    // Sort (skip for manual-sort shelves)
    if (_sectioned) {
      // Platforms by name; within one, games on the device come first.
      games.sort((a, b) {
        final byPlatform = _comparePlatforms(a.systemSlug, b.systemSlug);
        if (byPlatform != 0) return byPlatform;
        final aInstalled = installedKeys.contains(a.key);
        if (aInstalled != installedKeys.contains(b.key)) {
          return aInstalled ? -1 : 1;
        }
        final byTitle =
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
        return byTitle != 0 ? byTitle : a.filename.compareTo(b.filename);
      });
    } else if (!isManualSort) {
      if (shelfSortMode == ShelfSortMode.bySystem) {
        games.sort((a, b) {
          final cmp = a.systemSlug.compareTo(b.systemSlug);
          if (cmp != 0) return cmp;
          return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
        });
      } else {
        games.sort(
            (a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      }
    }

    setState(() {
      _installedKeys = installedKeys;
      _installedCount = installed.length;
      _availableCount = available.length;
      _filteredGames = games;
      _marked.retainAll(installedKeys);
      _rebuildSections();
      _rebuildRecents();
      _layout = _newLayout();
      _restoreCursor(
        previous: previous,
        entryKey: previousEntry,
        sectionKey: previousSection,
        reset: resetCursor,
      );
    });
    _scrollToCursorAfterLayout(onlyIfHidden: true);
  }

  /// Platform order: by display name.
  static int _comparePlatforms(String a, String b) {
    if (a == b) return 0;
    final byName =
        _systemName(a).toLowerCase().compareTo(_systemName(b).toLowerCase());
    return byName != 0 ? byName : a.compareTo(b);
  }

  static String _systemName(String slug) =>
      _systemsById[slug]?.name ?? slug.toUpperCase();

  void _rebuildSections() {
    if (!_sectioned) {
      _sections = _filteredGames.isEmpty
          ? const []
          : [
              LibrarySection(
                  key: '',
                  start: 0,
                  count: _filteredGames.length,
                  hasHeader: false),
            ];
      return;
    }
    final collapsed = _collapsed;
    final sections = <LibrarySection>[];
    var start = 0;
    while (start < _filteredGames.length) {
      final slug = _filteredGames[start].systemSlug;
      var end = start + 1;
      while (end < _filteredGames.length &&
          _filteredGames[end].systemSlug == slug) {
        end++;
      }
      sections.add(LibrarySection(
          key: slug,
          start: start,
          count: end - start,
          expanded: !collapsed.contains(slug)));
      start = end;
    }
    _sections = sections;
  }

  /// Recently launched games that are still installed, newest first.
  void _rebuildRecents() {
    final byKey = {for (final g in _allGames) g.key: g};
    final recents = <LibraryEntry>[];
    for (final played in _recentlyPlayed) {
      final entry = byKey['${played.systemId}/${played.filename}'];
      if (entry == null || !_installedKeys.contains(entry.key)) continue;
      recents.add(entry);
      if (recents.length == _maxRecents) break;
    }
    _recents = recents;
  }

  LibraryLayout _newLayout() => LibraryLayout(
        recentCount: _showRecents ? _recents.length : 0,
        sections: _sections,
        columns: math.max(1, _columns),
        metrics: _metrics,
        leadIn: _showRecentsHint ? _recentsHintHeight : 0,
      );

  /// Keeps the cursor on the same game or platform after the list changed,
  /// or on the nearest cell when it is gone.
  void _restoreCursor({
    required LibraryCursor previous,
    String? entryKey,
    String? sectionKey,
    bool reset = false,
  }) {
    LibraryCursor? next;
    if (!reset) {
      if (previous.kind == LibraryCursorKind.game && entryKey != null) {
        final index = _filteredGames.indexWhere((g) => g.key == entryKey);
        if (index >= 0) next = _layout.resolve(LibraryCursor.game(index));
      } else if (previous.kind == LibraryCursorKind.recent &&
          entryKey != null) {
        final index = _recents.indexWhere((g) => g.key == entryKey);
        if (index >= 0) next = _layout.resolve(LibraryCursor.recent(index));
      } else if (sectionKey != null) {
        final index = _sections.indexWhere((s) => s.key == sectionKey);
        if (index >= 0) next = _layout.resolve(LibraryCursor.header(index));
      }
      next ??= _layout.resolve(previous);
    }
    // A fresh view starts on a game rather than on a platform header.
    _setCursor(next ?? _layout.firstTile ?? const LibraryCursor.header(0));
  }

  void _setCursor(LibraryCursor cursor, {bool keepColumn = false}) {
    _cursor = cursor;
    if (cursor.kind == LibraryCursorKind.recent) {
      _recentMemory = cursor.index;
    } else if (cursor.kind == LibraryCursorKind.game) {
      final row = _layout.rowOf(cursor);
      if (row != null && row.strip) {
        _stripMemory[_stripId(_sections[row.section].key)] =
            cursor.index - row.start;
      } else if (!keepColumn) {
        _preferredColumn = _layout.columnOf(cursor);
      }
    }
    _selectedIdNotifier.value = cursor.id;
  }

  /// Tile a strip was left on (the first one for a row not visited yet).
  int _stripPosition(LibraryRow row) => row.kind == LibraryCursorKind.recent
      ? _recentMemory
      : _stripMemory[_stripId(_sections[row.section].key)] ?? 0;

  ScrollController? _stripControllerOf(LibraryRow row) =>
      row.kind == LibraryCursorKind.recent
          ? _recentsController
          : _stripControllers[_stripId(_sections[row.section].key)];

  ({List<LibraryEntry> games, bool isManualSort, ShelfSortMode? shelfSortMode}) _resolveShelfGames() {
    final shelf = _activeShelf;
    if (shelf == null) return (games: <LibraryEntry>[], isManualSort: false, shelfSortMode: null);

    final allGameRecords = _allGames
        .map((g) => (
              filename: g.filename,
              displayName: g.displayName,
              systemSlug: g.systemSlug,
            ))
        .toList();

    final filenames = shelf.resolveFilenames(allGameRecords);
    final lookup = <String, LibraryEntry>{};
    for (final g in _allGames) {
      lookup[g.filename] = g;
    }

    final games = <LibraryEntry>[];
    for (final f in filenames) {
      final entry = lookup[f];
      if (entry != null) games.add(entry);
    }

    return (games: games, isManualSort: shelf.sortMode == ShelfSortMode.manual, shelfSortMode: shelf.sortMode);
  }

  List<String> _coverUrlsFor(LibraryEntry entry) =>
      _coverUrlCache.putIfAbsent(entry.key, () {
        final systemModel = _systemsById[entry.systemSlug];
        return systemModel == null
            ? const []
            : ImageHelper.getCoverUrlsForSingle(systemModel, entry.filename);
      });

  // --- Tab Navigation ---

  void _nextTab() => _selectTab((_selectedTab + 1) % _totalTabCount);

  void _prevTab() =>
      _selectTab((_selectedTab - 1 + _totalTabCount) % _totalTabCount);

  void _selectTab(int index) {
    if (index == _selectedTab) return;
    if (_reorderState != ReorderState.none || _selectMode) return;
    ref.read(feedbackServiceProvider).tick();
    _shelves = ref.read(customShelvesProvider);
    setState(() => _selectedTab = index);
    _applyFilters(resetCursor: true);
    _scrollToTop();
  }

  void _cycleShelfSortMode() {
    final shelf = _activeShelf;
    if (shelf == null) return;
    ref.read(feedbackServiceProvider).tick();
    final next = switch (shelf.sortMode) {
      ShelfSortMode.alphabetical => ShelfSortMode.bySystem,
      ShelfSortMode.bySystem => ShelfSortMode.manual,
      ShelfSortMode.manual => ShelfSortMode.alphabetical,
    };
    ref.read(customShelvesProvider.notifier).updateShelf(
      shelf.id,
      shelf.copyWith(sortMode: next),
    );
    _shelves = ref.read(customShelvesProvider);
    _applyFilters(resetCursor: true);
    _scrollToTop();
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  // --- Platform sections ---

  void _toggleSection(int index) {
    if (index < 0 || index >= _sections.length) return;
    final key = _sections[index].key;
    ref.read(feedbackServiceProvider).tick();
    setState(() {
      if (!_collapsed.remove(key)) _collapsed.add(key);
      _rebuildSections();
      _layout = _newLayout();
      // Collapsing from inside the row leaves the cursor on its header.
      _setCursor(_layout.resolve(_cursor) ?? const LibraryCursor.header(0));
    });
    _scrollToCursorAfterLayout();
  }

  void _setAllExpanded(bool expanded) {
    ref.read(feedbackServiceProvider).tick();
    setState(() {
      _collapsed.clear();
      if (!expanded) _collapsed.addAll(_sections.map((s) => s.key));
      _rebuildSections();
      _layout = _newLayout();
      _setCursor(_layout.resolve(_cursor) ?? const LibraryCursor.header(0));
    });
    _scrollToCursorAfterLayout();
  }

  // --- Navigation ---

  void _navigate(GridDirection direction) {
    if (_layout.rows.isEmpty || _uninstalling) return;

    if (_reorderState == ReorderState.grabbed) {
      _reorderMove(direction);
      return;
    }

    final vertical =
        direction == GridDirection.up || direction == GridDirection.down;
    if (_debouncer.startHold(() {
      final next = _layout.move(_cursor, direction,
          column: _preferredColumn, stripPosition: _stripPosition);
      if (next == null || next == _cursor) return;
      // A single press glides; held or rapid presses jump to keep up.
      final now = DateTime.now();
      final rapid = _lastMove != null &&
          now.difference(_lastMove!) < const Duration(milliseconds: 300);
      _lastMove = now;
      _setCursor(next, keepColumn: vertical);
      _scrollToCursor(instant: rapid);
    })) {
      ref.read(feedbackServiceProvider).tick();
    }
  }

  /// Brings the cursor's row to the middle of the screen, and its tile into
  /// view when the row is a sideways-scrolling strip.
  void _scrollToCursor({bool instant = false, bool onlyIfHidden = false}) {
    final row = _layout.rowOf(_cursor);
    if (row == null) return;
    if (row.strip) {
      _scrollStripTo(_stripControllerOf(row), _layout.columnOf(_cursor),
          instant: instant);
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;
    final viewport = position.viewportDimension;
    if (onlyIfHidden &&
        row.top >= position.pixels &&
        row.bottom <= position.pixels + viewport) {
      return;
    }
    final target = (row.top + row.height / 2 - viewport / 2)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() < 1) return;

    final token = ++_scrollToken;
    _programmaticScroll = true;
    void done() {
      if (token == _scrollToken) _programmaticScroll = false;
    }

    if (instant) {
      _scrollController.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) => done());
    } else {
      _scrollController
          .animateTo(target,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut)
          .whenComplete(done);
    }
  }

  /// For changes that alter the content height: scroll once it is laid out.
  /// A strip that was off screen is only built by that scroll, so its own
  /// sideways position is set one frame later.
  void _scrollToCursorAfterLayout({bool onlyIfHidden = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToCursor(instant: true, onlyIfHidden: onlyIfHidden);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final row = _layout.rowOf(_cursor);
        if (row != null && row.strip) {
          _scrollStripTo(_stripControllerOf(row), _layout.columnOf(_cursor),
              instant: true);
        }
      });
    });
  }

  /// Scrolls a strip just far enough to show the tile at [position] whole.
  void _scrollStripTo(ScrollController? controller, int position,
      {bool instant = false}) {
    if (controller == null || !controller.hasClients) return;
    final scroll = controller.position;
    if (!scroll.hasContentDimensions) return;
    final start = position * (_tileWidth + _spacing);
    final end = start + _tileWidth + 2 * _side - scroll.viewportDimension;
    double target;
    if (scroll.pixels > start) {
      target = start;
    } else if (scroll.pixels < end) {
      target = end;
    } else {
      return;
    }
    target = target.clamp(0.0, scroll.maxScrollExtent).toDouble();
    if (instant) {
      controller.jumpTo(target);
    } else {
      controller.animateTo(target,
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  // --- Scroll Sync ---

  bool _handleScrollNotification(ScrollNotification notification) {
    // The recents row scrolls sideways inside the page; only the page counts.
    if (notification.depth != 0) return false;
    _updateScrollSuppression(notification);
    if (notification is ScrollEndNotification && !_programmaticScroll) {
      _moveCursorIntoView();
    }
    return false;
  }

  /// Cover loading pauses while the page is flung.
  void _updateScrollSuppression(ScrollNotification notification) {
    void release(int ms) {
      _suppressionTimer?.cancel();
      _suppressionTimer = Timer(Duration(milliseconds: ms), () {
        if (mounted) _scrollSuppression.value = false;
      });
    }

    if (notification is ScrollUpdateNotification) {
      if ((notification.scrollDelta?.abs() ?? 0) > 20) {
        if (!_scrollSuppression.value) _scrollSuppression.value = true;
        release(150);
      }
    } else if (notification is ScrollEndNotification) {
      release(100);
    }
  }

  /// After a touch scroll left the cursor off screen, continue from what is
  /// visible instead of jumping back.
  void _moveCursorIntoView() {
    if (_debouncer.isHolding || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final row = _layout.rowOf(_cursor);
    if (row == null) return;
    final top = position.pixels;
    if (row.bottom > top && row.top < top + position.viewportDimension) return;
    final visible = _layout.firstVisibleRow(top, position.viewportDimension);
    if (visible == null) return;
    _setCursor(
      _layout.cellIn(visible,
          visible.strip ? _stripPosition(visible) : _preferredColumn),
      keepColumn: true,
    );
  }

  // --- Columns ---

  void _adjustColumns(bool increase) {
    final next = (increase ? _columns + 1 : _columns - 1)
        .clamp(_minColumns, _maxColumns);
    if (next == _columns) return;
    ref.read(storageServiceProvider).setGridColumns(_columnsKey, next);
    // build() recomputes the geometry and layout for the new column count.
    setState(() => _columns = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _preferredColumn = _layout.columnOf(_cursor);
      _scrollToCursor(instant: true);
    });
  }

  // --- Game Detail ---

  Future<void> _openGameDetail(LibraryEntry entry) async {
    searchFieldNode.unfocus();
    suspendSearchOverlay();
    ref.read(feedbackServiceProvider).confirm();

    final appConfig =
        ref.read(bootstrappedConfigProvider).value ?? AppConfig.empty;
    final systemModel = _systemsById[entry.systemSlug];
    if (systemModel == null) return;

    final systemConfig =
        ConfigBootstrap.configForSystem(appConfig, systemModel);
    final targetFolder = systemConfig?.targetFolder ?? '';

    final game = GameItem(
      filename: entry.filename,
      displayName: entry.displayName,
      url: entry.url,
      cachedCoverUrl: entry.coverUrl,
      providerConfig: entry.providerConfig,
    );

    final isLocalOnly = systemConfig == null || systemConfig.providers.isEmpty;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GameDetailScreen(
          game: game,
          variants: [game],
          system: systemModel,
          targetFolder: targetFolder,
          isLocalOnly: isLocalOnly,
          autoExtract: systemConfig?.autoExtract ?? false,
          packFolders: systemConfig?.packsFolderGames ?? false,
        ),
      ),
    );

    if (!mounted) return;
    // The game may have been played from its page.
    final recentlyPlayed = await _loadRecentlyPlayed();
    if (!mounted) return;

    resumeSearchOverlay();
    // Reload to pick up install/favorite/shelf changes
    _recentlyPlayed = recentlyPlayed;
    _favoriteIds = ref.read(favoriteGamesProvider).toSet();
    _shelves = ref.read(customShelvesProvider);
    final data = ref.read(installedFilesProvider).value;
    if (data != null) {
      _installedFiles = data.all;
    }
    _applyFilters();
    if (isSearchActive) {
      requestScreenFocus();
    }
  }

  void _handleConfirm() {
    if (_uninstalling) return;
    if (_reorderState == ReorderState.selecting) {
      _grabItem();
      return;
    }
    if (_reorderState == ReorderState.grabbed) {
      _dropItem();
      return;
    }
    if (_cursor.kind == LibraryCursorKind.header) {
      _toggleSection(_cursor.index);
      return;
    }
    final entry = _focusedEntry;
    if (entry == null) return;
    if (_selectMode) {
      _toggleMark(entry);
    } else {
      _openGameDetail(entry);
    }
  }

  void _handleBack() {
    if (_uninstalling) return;
    ref.read(feedbackServiceProvider).cancel();
    if (_reorderState == ReorderState.grabbed) {
      _dropItem();
      return;
    }
    if (_reorderState == ReorderState.selecting) {
      _exitReorderMode();
      return;
    }
    if (_selectMode) {
      _exitSelectMode();
      return;
    }
    if (isSearchActive) {
      handleSearchBack();
    } else {
      Navigator.pop(context);
    }
  }

  void _replaceEntry(LibraryEntry entry, {String? coverUrl, bool? hasThumbnail}) {
    final idx = _allGames.indexWhere((g) => g.key == entry.key);
    if (idx < 0) return;
    _allGames[idx] = LibraryEntry(
      filename: entry.filename,
      displayName: entry.displayName,
      cardTitle: entry.cardTitle,
      url: entry.url,
      coverUrl: coverUrl ?? entry.coverUrl,
      systemSlug: entry.systemSlug,
      providerConfig: entry.providerConfig,
      hasThumbnail: hasThumbnail ?? entry.hasThumbnail,
    );
  }

  Future<void> _onCoverFound(String url, LibraryEntry entry) async {
    await DatabaseService().updateGameCover(entry.filename, url);
    _replaceEntry(entry, coverUrl: url);
  }

  Future<void> _onThumbnailNeeded(String url, LibraryEntry entry) async {
    if (entry.hasThumbnail) return;
    final result = await ThumbnailService.generateThumbnail(url);
    if (result.success) {
      await DatabaseService().updateGameThumbnailData(
        entry.filename,
        hasThumbnail: true,
      );
      _replaceEntry(entry, hasThumbnail: true);
    }
  }

  // --- Multi-select (bulk uninstall) ---

  bool get _canUseSelectButton =>
      !isSearchActive &&
      !showQuickMenu &&
      !_confirmUninstall &&
      !_uninstalling &&
      _reorderState == ReorderState.none &&
      ref.read(overlayPriorityProvider) == OverlayPriority.none;

  /// X: start marking games; while marking, mark the game under the cursor
  /// or every installed game of the platform under it.
  void _handleSelectButton() {
    if (!_selectMode) {
      _enterSelectMode(mark: _focusedEntry);
      return;
    }
    if (_cursor.kind == LibraryCursorKind.header) {
      _toggleMarkSection(_cursor.index);
    } else {
      final entry = _focusedEntry;
      if (entry != null) _toggleMark(entry);
    }
  }

  void _enterSelectMode({LibraryEntry? mark}) {
    if (_selectMode || _installedKeys.isEmpty) return;
    ref.read(feedbackServiceProvider).tick();
    setState(() {
      _selectMode = true;
      _marked.clear();
      if (mark != null && _installedKeys.contains(mark.key)) {
        _marked.add(mark.key);
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _marked.clear();
    });
  }

  void _toggleMark(LibraryEntry entry) {
    if (!_installedKeys.contains(entry.key)) {
      // Only installed games can be uninstalled.
      ref.read(feedbackServiceProvider).cancel();
      return;
    }
    ref.read(feedbackServiceProvider).tick();
    setState(() {
      if (!_marked.remove(entry.key)) _marked.add(entry.key);
    });
  }

  List<String> _installedKeysIn(LibrarySection section) => [
        for (var i = section.start; i < section.start + section.count; i++)
          if (_installedKeys.contains(_filteredGames[i].key))
            _filteredGames[i].key,
      ];

  void _toggleMarkSection(int index) {
    if (index < 0 || index >= _sections.length) return;
    final keys = _installedKeysIn(_sections[index]);
    if (keys.isEmpty) {
      ref.read(feedbackServiceProvider).cancel();
      return;
    }
    ref.read(feedbackServiceProvider).tick();
    setState(() {
      if (keys.every(_marked.contains)) {
        _marked.removeAll(keys);
      } else {
        _marked.addAll(keys);
      }
    });
  }

  void _requestUninstall() {
    if (!_selectMode || _uninstalling || _confirmUninstall) return;
    if (_marked.isEmpty) {
      showConsoleNotification(context,
          message: 'Mark at least one installed game first.');
      return;
    }
    setState(() => _confirmUninstall = true);
  }

  void _cancelUninstall() {
    setState(() => _confirmUninstall = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) requestScreenFocus();
    });
  }

  /// Deletes the marked games' files from the device. They stay in the
  /// library (on their source) and can be downloaded again.
  Future<void> _uninstallMarked() async {
    final byKey = {for (final g in _allGames) g.key: g};
    final targets = [
      for (final key in _marked)
        if (byKey[key] case final entry?) entry,
    ];
    setState(() {
      _confirmUninstall = false;
      _uninstalling = true;
    });

    try {
      // Game folders come from the config: wait for it rather than treat
      // "still loading" as "nothing to delete".
      final appConfig = await ref.read(bootstrappedConfigProvider.future);
      final romManager = RomManager();
      final db = DatabaseService();
      for (final entry in targets) {
        final system = _systemsById[entry.systemSlug];
        if (system == null) continue;
        final systemConfig =
            ConfigBootstrap.configForSystem(appConfig, system);
        final targetFolder = systemConfig?.targetFolder ?? '';
        if (systemConfig == null || targetFolder.isEmpty) continue;
        final game = GameItem(
          filename: entry.filename,
          displayName: entry.displayName,
          url: entry.url,
          providerConfig: entry.providerConfig,
        );
        await romManager.delete(game, system, targetFolder);
        // A game that only exists on the device leaves the library with
        // its file, as it does when deleted from its own page.
        if (systemConfig.providers.isEmpty &&
            !await romManager.exists(game, system, targetFolder)) {
          await db.deleteGame(system.id, entry.filename);
        }
      }
    } catch (e) {
      debugPrint('LibraryScreen: uninstall stopped early: $e');
    }
    if (!mounted) return;

    // Re-scan what is on disk and count what is really gone.
    ref.read(romChangeSignalProvider.notifier).state++;
    ref.invalidate(visibleSystemsProvider);
    try {
      _installedFiles = (await ref.read(installedFilesProvider.future)).all;
    } catch (e) {
      debugPrint('LibraryScreen: installed files refresh failed: $e');
      await _refreshInstalledFiles();
    }
    if (!mounted) return;
    final left = targets.where(_isGameInstalled).toList();
    final removed = targets.length - left.length;

    setState(() {
      _uninstalling = false;
      _selectMode = false;
      _marked.clear();
    });
    await _loadData(silent: true);
    if (!mounted) return;
    requestScreenFocus();

    if (left.isEmpty) {
      showSuccessNotification(context, ref,
          message: 'Uninstalled $removed ${removed == 1 ? 'game' : 'games'}.');
    } else {
      showErrorNotification(context, ref,
          message: 'Uninstalled $removed of ${targets.length}. Could not '
              'remove: ${left.take(3).map((g) => g.displayName).join(', ')}'
              '${left.length > 3 ? '…' : ''}');
    }
  }

  // --- Reorder Mode ---

  void _enterReorderMode() {
    final shelf = _activeShelf;
    if (shelf == null || shelf.sortMode != ShelfSortMode.manual) return;
    _reorderClaimToken = ref.read(overlayPriorityProvider.notifier).claim(OverlayPriority.dialog);
    setState(() {
      _reorderState = ReorderState.selecting;
      _grabbedIndex = -1;
    });
  }

  void _exitReorderMode() {
    if (_reorderState == ReorderState.none) return;
    final token = _reorderClaimToken;
    if (token != null) {
      _reorderClaimToken = null;
      if (!ref.read(overlayPriorityProvider.notifier).release(token)) {
        ref.read(overlayPriorityProvider.notifier).releaseByPriority(OverlayPriority.dialog);
      }
    }
    setState(() {
      _reorderState = ReorderState.none;
      _grabbedIndex = -1;
    });
  }

  void _grabItem() {
    if (_cursor.kind != LibraryCursorKind.game || _filteredGames.isEmpty) return;
    ref.read(feedbackServiceProvider).confirm();
    setState(() {
      _reorderState = ReorderState.grabbed;
      _grabbedIndex = _cursor.index;
    });
  }

  void _dropItem() {
    ref.read(feedbackServiceProvider).tick();
    setState(() {
      _reorderState = ReorderState.selecting;
      _grabbedIndex = -1;
    });
  }

  void _reorderMove(GridDirection direction) {
    final shelf = _activeShelf;
    if (shelf == null || _grabbedIndex < 0) return;

    int targetIndex;
    switch (direction) {
      case GridDirection.left:
        targetIndex = _grabbedIndex - 1;
      case GridDirection.right:
        targetIndex = _grabbedIndex + 1;
      case GridDirection.up:
        targetIndex = _grabbedIndex - _columns;
      case GridDirection.down:
        targetIndex = _grabbedIndex + _columns;
    }

    if (targetIndex < 0 || targetIndex >= _filteredGames.length) return;

    ref.read(feedbackServiceProvider).tick();
    ref.read(customShelvesProvider.notifier).reorderGameInShelf(
      shelf.id,
      _grabbedIndex,
      targetIndex,
      resolvedOrder: _filteredGames.map((g) => g.filename).toList(),
    );
    _shelves = ref.read(customShelvesProvider);
    _applyFilters();
    setState(() => _grabbedIndex = targetIndex);
    _setCursor(LibraryCursor.game(targetIndex));
    _scrollToCursor(instant: true);
  }

  // --- Shelf Management ---

  Future<void> _createShelf() async {
    final allGameRecords = _allGames.map((g) => (
      filename: g.filename,
      displayName: g.displayName,
      systemSlug: g.systemSlug,
    )).toList();
    final shelf = await Navigator.push<CustomShelf>(
      context,
      MaterialPageRoute(builder: (_) => ShelfEditScreen(allGameRecords: allGameRecords)),
    );
    if (shelf != null && mounted) {
      ref.read(customShelvesProvider.notifier).addShelf(shelf);
      _shelves = ref.read(customShelvesProvider);
      setState(() {
        _selectedTab = _fixedTabCount + _shelves.length - 1;
      });
      _applyFilters(resetCursor: true);
      _scrollToTop();
    }
  }

  Future<void> _editShelf() async {
    final shelf = _activeShelf;
    if (shelf == null) return;
    final allGameRecords = _allGames.map((g) => (
      filename: g.filename,
      displayName: g.displayName,
      systemSlug: g.systemSlug,
    )).toList();
    final updated = await Navigator.push<CustomShelf>(
      context,
      MaterialPageRoute(builder: (_) => ShelfEditScreen(shelf: shelf, allGameRecords: allGameRecords)),
    );
    if (!mounted) return;
    if (updated != null) {
      ref.read(customShelvesProvider.notifier).updateShelf(shelf.id, updated);
    }
    // Always refresh — shelf may have been deleted from edit screen
    _shelves = ref.read(customShelvesProvider);
    final stillExists = _shelves.any((s) => s.id == shelf.id);
    if (!stillExists) {
      setState(() {
        _selectedTab = (_selectedTab - 1).clamp(0, _totalTabCount - 1);
      });
    }
    _applyFilters(resetCursor: true);
    _scrollToTop();
  }

  void _addCurrentGameToShelf() {
    final entry = _focusedEntry;
    if (entry == null || _shelves.isEmpty) return;
    final availableShelves = _shelves
        .where((s) => !s.containsGame(
            entry.filename, entry.displayName, entry.systemSlug))
        .toList();
    if (availableShelves.isEmpty) return;
    showShelfPickerDialog(
      context: context,
      ref: ref,
      shelves: availableShelves,
      onSelect: (shelfId) {
        ref.read(customShelvesProvider.notifier).addGameToShelf(shelfId, entry.filename);
        _shelves = ref.read(customShelvesProvider);
        _applyFilters();
      },
    );
  }

  void _removeCurrentGameFromShelf() {
    final shelf = _activeShelf;
    final entry = _focusedEntry;
    if (shelf == null || entry == null) return;
    final matchesFilter = shelf.filterRules.any(
      (r) => r.matches(entry.displayName, entry.systemSlug),
    );
    if (matchesFilter) {
      // Filter-matched: must explicitly exclude so filter doesn't re-add it
      ref.read(customShelvesProvider.notifier).excludeGameFromShelf(shelf.id, entry.filename);
    } else {
      // Truly manual: just remove from manualGameIds, no exclusion needed
      ref.read(customShelvesProvider.notifier).removeGameFromShelf(shelf.id, entry.filename);
    }
    _shelves = ref.read(customShelvesProvider);
    _applyFilters();
  }

  void _handleFavorite() {
    final entry = _focusedEntry;
    if (entry == null) return;
    ref.read(feedbackServiceProvider).tick();
    ref.read(favoriteGamesProvider.notifier).toggleFavorite(entry.filename);
    _favoriteIds = ref.read(favoriteGamesProvider).toSet();
    _applyFilters();
  }

  List<QuickMenuItem?> _buildQuickMenuItems() {
    final l = L.of(context);
    final hasDownloads = ref.read(hasQueueItemsProvider);
    final shelf = _activeShelf;
    final focused = _focusedEntry;
    final allExpanded =
        _sections.isNotEmpty && _sections.every((s) => s.expanded);
    return [
      QuickMenuItem(
        label: l.library_zoomIn,
        icon: Icons.zoom_in_rounded,
        shortcutHint: 'L',
        onSelect: () => _adjustColumns(true),
      ),
      QuickMenuItem(
        label: l.library_zoomOut,
        icon: Icons.zoom_out_rounded,
        shortcutHint: 'R',
        onSelect: () => _adjustColumns(false),
      ),
      // Y uninstalls while multi-select is on, so search waits until it ends.
      if (!_selectMode)
        QuickMenuItem(
          label: l.common_search,
          icon: Icons.search_rounded,
          shortcutHint: 'Y',
          onSelect: openSearch,
        ),
      if (focused != null)
        QuickMenuItem(
          label: _favoriteIds.contains(focused.filename)
              ? l.common_unfavorite : l.common_favorite,
          icon: _favoriteIds.contains(focused.filename)
              ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          shortcutHint: '−',
          onSelect: _handleFavorite,
        ),
      if (_sectioned && _sections.isNotEmpty)
        QuickMenuItem(
          label: allExpanded ? 'Collapse all platforms' : 'Expand all platforms',
          icon: allExpanded
              ? Icons.unfold_less_rounded
              : Icons.unfold_more_rounded,
          onSelect: () => _setAllExpanded(!allExpanded),
        ),
      if (!_selectMode &&
          _installedKeys.isNotEmpty &&
          _reorderState == ReorderState.none)
        QuickMenuItem(
          label: 'Select games to uninstall',
          icon: Icons.checklist_rounded,
          shortcutHint: 'X',
          onSelect: _enterSelectMode,
        ),
      if (shelf != null)
        QuickMenuItem(
          label: switch (shelf.sortMode) {
            ShelfSortMode.alphabetical => l.library_sortSystem,
            ShelfSortMode.bySystem => l.library_sortManual,
            ShelfSortMode.manual => l.library_sortAZ,
          },
          icon: Icons.sort_rounded,
          onSelect: _cycleShelfSortMode,
        ),
      // --- Shelf management ---
      null,
      QuickMenuItem(
        label: l.library_newShelf,
        icon: Icons.create_new_folder_rounded,
        onSelect: _createShelf,
      ),
      if (shelf != null)
        QuickMenuItem(
          label: l.library_editShelf,
          icon: Icons.edit_rounded,
          onSelect: _editShelf,
        ),
      if (focused != null && _shelves.any((s) => !s.containsGame(
          focused.filename, focused.displayName, focused.systemSlug)))
        QuickMenuItem(
          label: l.library_addToShelf,
          icon: Icons.add_rounded,
          onSelect: _addCurrentGameToShelf,
        ),
      if (shelf != null && focused != null)
        QuickMenuItem(
          label: l.library_removeFromShelf,
          icon: Icons.remove_rounded,
          onSelect: _removeCurrentGameFromShelf,
        ),
      if (shelf != null && shelf.sortMode == ShelfSortMode.manual && _filteredGames.length > 1)
        QuickMenuItem(
          label: l.library_reorderGames,
          icon: Icons.swap_vert_rounded,
          onSelect: _enterReorderMode,
        ),
      // --- Downloads ---
      if (hasDownloads) ...[
        null,
        QuickMenuItem(
          label: l.common_downloads,
          icon: Icons.download_rounded,
          onSelect: () => toggleDownloadOverlay(ref),
          highlight: true,
        ),
      ],
    ];
  }

  // --- Key Events ---

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final searchResult = handleSearchKeyEvent(event);
    if (searchResult != null) return searchResult;
    if (event is KeyUpEvent) {
      _debouncer.stopHold();
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.gameButtonX &&
        _canUseSelectButton) {
      _handleSelectButton();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- Count helpers ---

  bool _isGameInstalled(LibraryEntry entry) {
    final filename = entry.filename;
    if (_installedFiles.contains(filename)) return true;
    // Strip archive extension for extracted ROM match
    for (final ext in SystemModel.archiveExtensions) {
      if (filename.toLowerCase().endsWith(ext)) {
        final stripped = filename.substring(0, filename.length - ext.length);
        // Folder match (multi-file games)
        if (_installedFiles.contains(stripped)) return true;
        // ROM extension replacement (like RomManager.getTargetFilename)
        final system = _systemsById[entry.systemSlug];
        if (system != null) {
          for (final romExt in system.romExtensions) {
            if (_installedFiles.contains('$stripped$romExt')) return true;
          }
        }
        return false;
      }
    }
    return false;
  }

  /// Deduplicates installed entries that share the same display name and system
  /// (e.g., Mario.iso and Mario.zip both matching after archive-fallback).
  /// Prefers the entry with an exact filesystem match.
  List<LibraryEntry> _deduplicateInstalled(List<LibraryEntry> games) {
    final seen = <String, LibraryEntry>{};
    for (final game in games) {
      final key = '${game.systemSlug}::${game.displayName.toLowerCase()}';
      final existing = seen[key];
      if (existing == null) {
        seen[key] = game;
      } else {
        final gameIsExact = _installedFiles.contains(game.filename);
        final existingIsExact = _installedFiles.contains(existing.filename);
        if (gameIsExact && !existingIsExact) {
          seen[key] = game;
        }
      }
    }
    return seen.values.toList();
  }

  int get _favoritesCount =>
      _allGames.where((g) => _favoriteIds.contains(g.filename)).length;

  // --- Build ---

  /// Tile size and row heights for this screen size and zoom level.
  void _updateGeometry(Responsive rs) {
    final side = rs.spacing.lg;
    final spacing = rs.isSmall ? 10.0 : 14.0;
    if (_columns == 0) {
      // No saved zoom level: as many covers per row as fit comfortably.
      _columns = ((rs.screenWidth - 2 * side) / _autoTileWidth)
          .floor()
          .clamp(_minColumns, _maxColumns);
    }
    // A row shows [_columns] whole tiles and a slice of the next one.
    final tileWidth = math.max(1.0,
        (rs.screenWidth - side - _columns * spacing) / (_columns + _peek));
    final bottomPadding = rs.isPortrait ? 80.0 : 100.0;
    if (side == _side &&
        spacing == _spacing &&
        tileWidth == _tileWidth &&
        bottomPadding == _metrics.bottomPadding) {
      return;
    }
    _side = side;
    _spacing = spacing;
    _tileWidth = tileWidth;
    _recentsHintHeight = _recentsLabelHeight(rs) + (rs.isSmall ? 26.0 : 30.0);
    final tileHeight = tileWidth / _tileAspect;
    _metrics = LibraryMetrics(
      topPadding: rs.spacing.md,
      bottomPadding: bottomPadding,
      recentsHeight: _recentsLabelHeight(rs) + tileHeight + _recentsGap,
      headerHeight: (rs.isSmall ? 28.0 : 34.0) + _headerGap,
      tileHeight: tileHeight,
      rowSpacing: spacing,
      sectionGap: _sectionGap,
    );
    _layout = _newLayout();
  }

  /// Right inset that makes a wrapped grid's tiles the same size as the
  /// strips' (which keep room for the slice of the next tile).
  double _gridRightPadding(Responsive rs) => math.max(
      _side,
      rs.screenWidth -
          _side -
          _columns * _tileWidth -
          (_columns - 1) * _spacing);

  static double _recentsLabelHeight(Responsive rs) => rs.isSmall ? 22.0 : 26.0;

  @override
  Widget build(BuildContext context) {
    final rs = context.rs;
    _updateGeometry(rs);
    final baseTopPadding = rs.safeAreaTop + (rs.isSmall ? 72 : 96);
    final searchExtraPadding = isSearchActive ? (rs.isSmall ? 16.0 : 20.0) : 0.0;
    final topPadding = baseTopPadding + searchExtraPadding;

    return buildWithActions(
      PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _handleBack();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // Grid content (behind header)
              Padding(
                padding: EdgeInsets.only(top: topPadding),
                child: _buildContent(rs),
              ),
              // Header (over grid, with gradient fade)
              _buildHeader(rs),
              // Search bar
              if (isSearchActive) _buildSearchBar(),
              // HUD (its hints follow the cursor)
              if (!showQuickMenu && !_confirmUninstall)
                ValueListenableBuilder<int>(
                  valueListenable: _selectedIdNotifier,
                  builder: (context, _, __) => _buildHud(),
                ),
              // Quick Menu
              if (showQuickMenu)
                QuickMenuOverlay(
                  items: _buildQuickMenuItems(),
                  onClose: closeQuickMenu,
                ),
              if (_uninstalling)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Color(0x99000000),
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.cyanAccent),
                    ),
                  ),
                ),
              if (_confirmUninstall)
                ExitConfirmationOverlay(
                  icon: Icons.delete_outline_rounded,
                  title: _marked.length == 1
                      ? 'Uninstall 1 game?'
                      : 'Uninstall ${_marked.length} games?',
                  message: 'Their files are deleted from this device. They '
                      'stay in your library and can be downloaded again.',
                  confirmLabel: 'UNINSTALL',
                  onConfirm: _uninstallMarked,
                  onCancel: _cancelUninstall,
                ),
            ],
          ),
        ),
      ),
      onKeyEvent: _handleKeyEvent,
    );
  }

  Widget _buildHeader(Responsive rs) {
    final l = L.of(context);
    final fixedLabels = [
      l.library_tabAll,
      l.library_tabInstalled,
      'Available',
      l.library_tabFavorites,
    ];
    final fixedCounts = [
      _allGames.length,
      _installedCount,
      _availableCount,
      _favoritesCount,
    ];
    final shelf = _activeShelf;

    final tabs = <LibraryTab>[
      for (int i = 0; i < _fixedTabCount; i++)
        LibraryTab(label: fixedLabels[i], count: fixedCounts[i]),
      for (final shelf in _shelves)
        LibraryTab(
          label: shelf.name,
          count: _shelfGameCount(shelf),
          isCustomShelf: true,
        ),
    ];

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black,
              Color.fromRGBO(0, 0, 0, 0.9),
              Color.fromRGBO(0, 0, 0, 0.6),
              Colors.transparent,
            ],
            stops: [0.0, 0.5, 0.8, 1.0],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: rs.isSmall ? 16.0 : 24.0,
              vertical: rs.isSmall ? 8.0 : 12.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      l.library_title,
                      style: TextStyle(
                        fontSize: rs.isSmall ? 18 : 22,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 4,
                      ),
                    ),
                    const Spacer(),
                    if (_selectMode)
                      _headerChip(rs, '${_marked.length} MARKED TO UNINSTALL',
                          color: Colors.redAccent)
                    else ...[
                      // What the tile outlines mean.
                      _legendDot(rs, _installedGlow, 'Installed'),
                      SizedBox(width: rs.isSmall ? 10 : 14),
                      _legendDot(rs, _remoteGlow, 'On server'),
                      if (shelf != null) ...[
                        SizedBox(width: rs.isSmall ? 10 : 14),
                        // Sort indicator (platform tabs are always grouped)
                        _headerChip(
                          rs,
                          switch (shelf.sortMode) {
                            ShelfSortMode.alphabetical => l.library_sortIndicatorAZ,
                            ShelfSortMode.bySystem => l.library_sortIndicatorBySystem,
                            ShelfSortMode.manual => l.library_sortIndicatorManual,
                          },
                        ),
                      ],
                    ],
                  ],
                ),
                SizedBox(height: rs.isSmall ? 6 : 10),
                LibraryTabs(
                  selectedTab: _selectedTab,
                  tabs: tabs,
                  accentColor: Colors.cyanAccent,
                  onTap: _selectTab,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Responsive rs, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: color, width: 1.5),
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 5),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: rs.isSmall ? 9 : 10,
            fontWeight: FontWeight.w600,
            color: Colors.grey[400],
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }

  Widget _headerChip(Responsive rs, String label, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: (color ?? Colors.white).withValues(alpha: color == null ? 0.08 : 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: rs.isSmall ? 9 : 10,
          fontWeight: FontWeight.w600,
          color: color ?? Colors.grey[400],
          letterSpacing: 1,
        ),
      ),
    );
  }

  int _shelfGameCount(CustomShelf shelf) {
    final allGameRecords = _allGames
        .map((g) => (
              filename: g.filename,
              displayName: g.displayName,
              systemSlug: g.systemSlug,
            ))
        .toList();
    return shelf.resolveFilenames(allGameRecords).length;
  }

  Widget _buildSearchBar() {
    return buildSearchWidget(searchQuery: _searchQuery);
  }

  Widget _buildContent(Responsive rs) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.cyanAccent),
      );
    }

    if (_filteredGames.isEmpty) {
      final l = L.of(context);
      final String title;
      final String? subtitle;
      if (_searchQuery.isNotEmpty) {
        title = l.library_noResults(_searchQuery);
        subtitle = l.library_tryShorterSearch;
      } else if (_selectedTab == _tabInstalled) {
        title = l.library_noInstalledGames;
        subtitle = l.library_downloadGamesToSee;
      } else if (_selectedTab == _tabAvailable) {
        title = _allGames.isEmpty
            ? l.library_noGamesInLibrary
            : 'Nothing left to download';
        subtitle = _allGames.isEmpty
            ? l.library_gamesAfterSync
            : 'Every game from your sources is installed';
      } else if (_selectedTab == _tabFavorites) {
        title = l.library_noFavoritesYet;
        subtitle = l.library_pressFavoriteHint;
      } else if (_isShelfTab) {
        title = l.library_noGamesInShelf;
        subtitle = l.library_addGamesViaEditor;
      } else {
        title = l.library_noGamesInLibrary;
        subtitle = _allGames.isEmpty ? l.library_gamesAfterSync : null;
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_books_outlined,
                size: 64, color: Colors.grey[700]),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(color: Colors.grey[500], fontSize: 16),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ],
          ],
        ),
      );
    }

    final deviceMemory = ref.read(deviceMemoryProvider);
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth =
        (_tileWidth * dpr).round().clamp(150, deviceMemory.memCacheWidthMax);

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: RepaintBoundary(
        child: CustomScrollView(
          cacheExtent: deviceMemory.libraryCacheExtent,
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: _metrics.topPadding)),
            if (_showRecentsHint)
              SliverToBoxAdapter(child: _buildRecentsHint(rs)),
            if (_sectioned)
              // Recents, then a header and a strip per platform. Every row's
              // height is known, so only rows near the screen are built and
              // the page can jump straight to any of them.
              SliverVariedExtentList.builder(
                itemCount: _layout.rows.length,
                itemExtentBuilder: (index, _) => index < _layout.rows.length
                    ? _layout.rows[index].extent
                    : null,
                itemBuilder: (context, index) =>
                    _buildRow(rs, _layout.rows[index], cacheWidth),
              )
            else
              SliverPadding(
                padding: EdgeInsets.only(
                  left: _side,
                  right: _gridRightPadding(rs),
                  bottom: _metrics.sectionGap,
                ),
                sliver: _buildGrid(cacheWidth),
              ),
            SliverToBoxAdapter(child: SizedBox(height: _metrics.bottomPadding)),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(Responsive rs, LibraryRow row, int cacheWidth) {
    switch (row.kind) {
      case LibraryCursorKind.recent:
        return _buildRecents(rs, cacheWidth);
      case LibraryCursorKind.header:
        return _buildSectionHeader(rs, row.section);
      case LibraryCursorKind.game:
        return _buildSectionStrip(row, cacheWidth);
    }
  }

  Widget _recentsLabel(Responsive rs) {
    return SizedBox(
      height: _recentsLabelHeight(rs),
      child: Text(
        'RECENTLY PLAYED',
        style: TextStyle(
          fontSize: rs.isSmall ? 10 : 12,
          fontWeight: FontWeight.w700,
          color: Colors.grey[500],
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildRecents(Responsive rs, int cacheWidth) {
    return Column(
      key: const ValueKey('recents'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: _side),
          child: _recentsLabel(rs),
        ),
        SizedBox(
          height: _metrics.tileHeight,
          child: _buildTileStrip(
            storageKey: 'library-recents',
            controller: _recentsController,
            count: _recents.length,
            tile: (index) => _buildGameTile(
              _recents[index],
              LibraryCursor.recent(index),
              cacheWidth,
            ),
          ),
        ),
      ],
    );
  }

  /// Shown in the row's place until a game has been started from the app.
  Widget _buildRecentsHint(Responsive rs) {
    return SizedBox(
      height: _recentsHintHeight,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _side),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recentsLabel(rs),
            Text(
              'Nothing yet. Games you start from here line up in this row.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: rs.isSmall ? 10 : 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(Responsive rs, int index) {
    final section = _sections[index];
    final system = _systemsById[section.key];
    final cursor = LibraryCursor.header(index);
    final markedCount = _selectMode
        ? _installedKeysIn(section).where(_marked.contains).length
        : 0;
    // The label's own frame and padding hang outside the row's left edge,
    // so its chevron lines up with the tiles below.
    final side = _side - (rs.isSmall ? 8 : 10);
    return Padding(
      key: ValueKey('header-${section.key}'),
      padding: EdgeInsets.only(left: side, right: side, bottom: _headerGap),
      child: SelectionAwareItem(
        selectedIndexNotifier: _selectedIdNotifier,
        index: cursor.id,
        builder: (isSelected) => LibrarySectionHeader(
          title: _systemName(section.key),
          count: section.count,
          expanded: section.expanded,
          isSelected: isSelected,
          accentColor: system?.iconColor ?? Colors.grey,
          iconAsset: system == null || system.iconName.isEmpty
              ? null
              : system.iconAssetPath,
          markedCount: markedCount,
          onTap: () {
            _setCursor(cursor);
            _toggleSection(index);
          },
        ),
      ),
    );
  }

  /// A platform's games on one sideways-scrolling row.
  Widget _buildSectionStrip(LibraryRow row, int cacheWidth) {
    final section = _sections[row.section];
    final id = _stripId(section.key);
    return Align(
      key: ValueKey('strip-$id'),
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: _metrics.tileHeight,
        child: _buildTileStrip(
          storageKey: 'library-strip-$id',
          controller: _stripControllers.putIfAbsent(id, ScrollController.new),
          count: section.count,
          tile: (i) {
            final index = section.start + i;
            return _buildGameTile(
              _filteredGames[index],
              LibraryCursor.game(index),
              cacheWidth,
            );
          },
        ),
      ),
    );
  }

  Widget _buildTileStrip({
    required String storageKey,
    required ScrollController controller,
    required int count,
    required Widget Function(int index) tile,
  }) {
    return ListView.builder(
      // Keeps the row's sideways position while it is scrolled off screen.
      key: PageStorageKey<String>(storageKey),
      controller: controller,
      scrollDirection: Axis.horizontal,
      // The focused tile and the tiles' glow reach past the row's edges.
      clipBehavior: Clip.none,
      padding: EdgeInsets.symmetric(horizontal: _side),
      itemExtent: _tileWidth + _spacing,
      itemCount: count,
      itemBuilder: (context, index) => Padding(
        padding: EdgeInsets.only(right: _spacing),
        child: tile(index),
      ),
    );
  }

  /// Search results and shelves: one wrapped grid.
  Widget _buildGrid(int cacheWidth) {
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
        mainAxisSpacing: _metrics.rowSpacing,
        crossAxisSpacing: _spacing,
        mainAxisExtent: _metrics.tileHeight,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) => _buildGameTile(
          _filteredGames[index],
          LibraryCursor.game(index),
          cacheWidth,
        ),
        childCount: _filteredGames.length,
      ),
    );
  }

  Widget _buildGameTile(LibraryEntry entry, LibraryCursor cursor, int cacheWidth) {
    final isInstalled = _installedKeys.contains(entry.key);
    final systemModel = _systemsById[entry.systemSlug];
    final raMatch = _raMatches[entry.filename];
    // Platform rows already say which system a game is for.
    final inSection =
        cursor.kind == LibraryCursorKind.game && _sectioned;
    // The outline says where the game is, in place of an "installed" badge.
    final glow = isInstalled
        ? _installedGlow
        : entry.isRemote
            ? _remoteGlow
            : null;

    // Source dot lookup — entry.providerConfig is rehydrated from
    // the games DB; if it was synthesised by SourceResolver it
    // carries a sourceId we can map back to a live Source.
    final sourcesState = ref.watch(sourcesProvider);
    final entrySourceId = entry.providerConfig?.sourceId;
    Source? entrySource;
    if (entrySourceId != null) {
      for (final s in sourcesState.sources) {
        if (s.id == entrySourceId) {
          entrySource = s;
          break;
        }
      }
    }
    final entryDotColor =
        entrySource == null ? null : sourceDotColorFor(entrySource);
    final entryDotBorrowed = entrySource?.borrowed ?? false;

    // Library entries don't carry alternativeSources today (they
    // come from a flat DB row), so the extras list is always empty.
    // Wired through anyway so adding multi-source DB support later
    // only needs to populate this list.
    const List<SourceDotData> entryExtraDots = [];
    final isGrabbed = _reorderState == ReorderState.grabbed &&
        cursor.kind == LibraryCursorKind.game &&
        _grabbedIndex == cursor.index;
    final isReordering = _reorderState != ReorderState.none;

    Widget card = RepaintBoundary(
      child: SelectionAwareItem(
        selectedIndexNotifier: _selectedIdNotifier,
        index: cursor.id,
        builder: (isSelected) => BaseGameCard(
          displayName: entry.cardTitle,
          systemLabel: inSection ? null : _systemShortLabel(entry.systemSlug),
          accentColor: systemModel?.accentColor ?? Colors.grey,
          coverUrls: _coverUrlsFor(entry),
          cachedUrl: entry.coverUrl,
          hasThumbnail: entry.hasThumbnail,
          memCacheWidth: cacheWidth,
          scrollSuppression: _scrollSuppression,
          isInstalled: false,
          glowColor: glow,
          isSelected: isSelected,
          // The mark badge takes the top-right corner while selecting.
          isFavorite: !_selectMode && _favoriteIds.contains(entry.filename),
          raAchievementCount: _selectMode ? null : raMatch?.achievementCount,
          raMatchType: raMatch?.type ?? RaMatchType.none,
          isMastered: raMatch?.isMastered ?? false,
          sourceDotColor: entryDotColor,
          sourceDotBorrowed: entryDotBorrowed,
          extraSourceDots: entryExtraDots,
          onCoverFound: (url) => _onCoverFound(url, entry),
          onThumbnailNeeded: (url) => _onThumbnailNeeded(url, entry),
          onTap: () {
            if (_reorderState == ReorderState.selecting) {
              _setCursor(cursor);
              _grabItem();
              return;
            }
            if (_reorderState == ReorderState.grabbed) return;
            if (_selectMode) {
              _setCursor(cursor);
              _toggleMark(entry);
            } else if (_cursor == cursor) {
              _openGameDetail(entry);
            } else {
              _setCursor(cursor);
              ref.read(feedbackServiceProvider).tick();
            }
          },
          onTapSelect: () {
            if (_reorderState != ReorderState.none) return;
            if (_cursor != cursor) {
              _setCursor(cursor);
              ref.read(feedbackServiceProvider).tick();
            }
          },
          onLongPress: isReordering ? null : () {
            _setCursor(cursor);
            if (_isShelfTab && _activeShelf?.sortMode == ShelfSortMode.manual) {
              _enterReorderMode();
              _grabItem();
            } else if (!_selectMode && !isSearchActive) {
              _enterSelectMode(mark: entry);
            }
          },
        ),
      ),
    );

    // Multi-select: installed games get a mark, the rest fade back.
    card = Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: _selectMode && !isInstalled ? 0.35 : 1, child: card),
        if (_selectMode && isInstalled)
          Positioned(
            top: 6,
            right: 6,
            child: IgnorePointer(
              child: _MarkBadge(marked: _marked.contains(entry.key)),
            ),
          ),
      ],
    );

    if (isReordering) {
      card = ReorderableCardWrapper(
        isJiggling: _reorderState == ReorderState.selecting,
        isGrabbed: isGrabbed,
        child: card,
      );
    }

    return KeyedSubtree(
      key: ValueKey('${cursor.kind.name}-${entry.key}'),
      child: card,
    );
  }

  Widget _buildHud() {
    final l = L.of(context);
    if (_reorderState == ReorderState.grabbed) {
      return ConsoleHud(
        dpad: (label: '←↑↓→', action: l.common_move),
        a: HudAction(l.common_drop, onTap: _dropItem),
        b: HudAction(l.common_cancel, onTap: _dropItem),
      );
    }
    if (_reorderState == ReorderState.selecting) {
      return ConsoleHud(
        a: HudAction(l.common_grab, onTap: _grabItem),
        b: HudAction(l.common_done, onTap: _exitReorderMode),
      );
    }

    final onHeader = _cursor.kind == LibraryCursorKind.header &&
        _cursor.index < _sections.length;
    final headerAction = onHeader
        ? HudAction(
            _sections[_cursor.index].expanded ? 'Collapse' : 'Expand',
            onTap: _handleConfirm)
        : null;

    if (_selectMode) {
      return ConsoleHud(
        a: headerAction ?? HudAction('Mark', onTap: _handleConfirm),
        x: onHeader
            ? HudAction('Mark platform', onTap: _handleSelectButton)
            : null,
        y: HudAction('Uninstall (${_marked.length})',
            onTap: _requestUninstall, highlight: _marked.isNotEmpty),
        b: HudAction(l.common_cancel, onTap: _exitSelectMode),
      );
    }
    if (isSearchActive) {
      return buildSearchHud(
        aAction: HudAction(l.common_select, onTap: _handleConfirm),
      );
    }

    return ConsoleHud(
      a: headerAction ?? HudAction(l.common_select, onTap: _handleConfirm),
      b: HudAction(l.common_back, onTap: () => Navigator.pop(context)),
      x: _installedKeys.isEmpty
          ? null
          : HudAction('Multi-select', onTap: _handleSelectButton),
      start: HudAction(l.common_menu, onTap: toggleQuickMenu),
    );
  }

  static String _systemShortLabel(String slug) {
    const labels = {
      'nes': 'NES',
      'snes': 'SNES',
      'n64': 'N64',
      'gc': 'GCN',
      'wii': 'Wii',
      'wiiu': 'Wii U',
      'switch': 'Switch',
      'gb': 'GB',
      'gbc': 'GBC',
      'gba': 'GBA',
      'nds': 'NDS',
      'n3ds': '3DS',
      'psx': 'PS1',
      'ps2': 'PS2',
      'ps3': 'PS3',
      'psp': 'PSP',
      'psvita': 'Vita',
      'mastersystem': 'SMS',
      'megadrive': 'MD',
      'gamegear': 'GG',
      'dreamcast': 'DC',
      'saturn': 'Saturn',
      'segacd': 'SCD',
      'sega32x': '32X',
      'atari2600': '2600',
      'atari5200': '5200',
      'atari7800': '7800',
      'lynx': 'Lynx',
      'pico8': 'P-8',
    };
    return labels[slug] ?? slug.toUpperCase();
  }
}

/// Check circle on a tile while marking games to uninstall.
class _MarkBadge extends StatelessWidget {
  final bool marked;
  const _MarkBadge({required this.marked});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: marked ? Colors.redAccent : Colors.black.withValues(alpha: 0.6),
        border: Border.all(
          color: marked ? Colors.white : Colors.white.withValues(alpha: 0.7),
          width: 1.5,
        ),
      ),
      child: marked
          ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
          : null,
    );
  }
}
