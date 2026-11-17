import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import 'search_history_provider.dart';
import 'search_provider.dart';
import 'search_category.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/cloudstream/cloudstream_provider.dart';
import '../../home/presentation/widgets/home_provider_chip.dart'
    show cleanPluginName;
import 'search_source_grid_screen.dart';
import 'search_sources.dart';
import 'widgets/search_category_chips.dart';
import 'widgets/search_source_row.dart';
import 'widgets/search_header_bar.dart';
import 'widgets/search_suggestion_row.dart';
import 'widgets/bouncy_entry_animation.dart';
import 'widgets/check_section.dart';
import '../../../shared/widgets/cards_wrapper.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/focus/text_field_keys.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final FocusNode _clearButtonFocusNode = FocusNode();
  final FocusNode _moviesShowsFocusNode = FocusNode();
  final FocusNode _liveTvFocusNode = FocusNode();
  final FocusNode _firstSuggestionFocusNode = FocusNode();
  final FocusNode _firstResultFocusNode = FocusNode();
  final FocusNode _checksFocusNode = FocusNode();

  /// The results grid's own controller: the D-pad focus-wait reads it to
  /// tell whether the first result is scrolled away, and a grid — unlike
  /// the old per-provider horizontal rows — has exactly one scrollable.
  final ScrollController _resultsScrollController = ScrollController();

  /// Whether the recents-and-suggestions panel is covering the results.
  ///
  /// Tracked explicitly rather than read off [_focusNode], because on a
  /// television focus moves *into* the panel's own rows - a focus-driven gate
  /// would close the panel the moment the user pressed down into it.
  ///
  /// Opens when the field takes focus or the text changes; closes on submit.
  bool _isPanelOpen = false;

  @override
  void initState() {
    super.initState();
    // Restore any previously committed query into the text field.
    _controller.text = ref.read(searchQueryProvider);
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onSearchFieldFocusChanged);

    // The bar reads left to right now - field, clear, then the scope pill -
    // with the panel and the results underneath it. It used to be a column,
    // so down from the field meant "into the pill"; down now means "into the
    // list", and the pill is reached by going right.
    _focusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;

      // A TV IME uses all four D-pad directions to select letters. In
      // particular, moving focus to the result list on Down while the
      // keyboard is visible prevents users from typing complete searches.
      if (deferToSoftKeyboard(node)) return KeyEventResult.ignored;

      // Do NOT handle left/right here. Android TV leanback keyboards use those
      // to move between letter keys; stealing them left users stuck mid-word.
      // Clear / scope pills stay reachable via the clear icon and Up from results.
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        return _focusBelowBar();
      }
      // Select - OK on a remote - or a game controller's A brings back a
      // keyboard put away with Back. Enter still submits, through
      // TextField.onSubmitted.
      return reopenTextFieldKeyboard(node, event);
    };

    _clearButtonFocusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent) {
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _focusNode.requestFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _focusScopePill();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          return _focusBelowBar();
        }
      }
      return KeyEventResult.ignored;
    };
  }

  /// The scope pill's keys. Not on the pills' own nodes: each pill is a
  /// [CardsWrapper], whose [Focus] replaces a node's key handler with its
  /// own. Keys it leaves bubble up to here.
  KeyEventResult _pillKeys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_moviesShowsFocusNode.hasPrimaryFocus) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        // Back into the bar, at the control the pill actually sits next
        // to: the clear button when there is one, else the field.
        if (_controller.text.isNotEmpty) {
          _clearButtonFocusNode.requestFocus();
        } else {
          _focusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _liveTvFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) return _focusBelowBar();
    } else if (_liveTvFocusNode.hasPrimaryFocus) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _moviesShowsFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) return _focusBelowBar();
    }
    return KeyEventResult.ignored;
  }

  /// Up from the first result, which is a [CardsWrapper] too ([_pillKeys]).
  KeyEventResult _resultKeys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.arrowUp ||
        !_firstResultFocusNode.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    if (_checksShown) {
      _checksFocusNode.requestFocus();
    } else {
      _focusNode.requestFocus();
    }
    return KeyEventResult.handled;
  }

  /// The selected half of the scope pill, which is where a walk rightwards
  /// out of the bar should land.
  void _focusScopePill() {
    if (ref.read(searchFilterProvider) == SearchFilter.live) {
      _liveTvFocusNode.requestFocus();
    } else {
      _moviesShowsFocusNode.requestFocus();
    }
  }

  /// Leaves the bar downwards: into the panel if it has rows, else into the
  /// results. Reports whether there was anywhere to go, so a press with
  /// nothing below it falls through rather than being swallowed.
  ///
  /// Only to a target in the tree. A node out of it takes a request for the
  /// focus as one to keep, and takes the focus whenever it is put in one: a
  /// suggestion still on its way, or a first result scrolled out of its row,
  /// would pull the focus out of the field when it arrived - mid-word.
  KeyEventResult _focusBelowBar() {
    // Recents count as panel rows, so down lands on one whether the field is
    // empty or mid-query. While the panel is open its rows are what is below
    // the bar, so down waits for them rather than reaching past it.
    if (_panelHasRows()) {
      if (!_canFocusNow(_firstSuggestionFocusNode)) {
        return KeyEventResult.ignored;
      }
      _firstSuggestionFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    // The checks the search met sit between the bar and the results.
    for (final below in [_checksFocusNode, _firstResultFocusNode]) {
      if (_canFocusNow(below)) {
        below.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Whether the check section is on screen.
  bool get _checksShown => _canFocusNow(_checksFocusNode);

  /// Whether [node] is in the tree and free to take the focus. A node keeps
  /// its last context after it leaves the tree, so the context alone doesn't
  /// say: its place in the focus tree does.
  static bool _canFocusNow(FocusNode node) =>
      node.parent != null &&
      (node.context?.mounted ?? false) &&
      node.canRequestFocus;

  void _onTextChanged() {
    if (!mounted) return;
    // Typing always reopens the panel: a user editing a committed query is
    // starting a new search, and wants the recents and suggestions back.
    setState(() => _isPanelOpen = true);
  }

  /// Reopens the panel when the user returns to the field.
  ///
  /// Also re-runs the suggestion fetch for text that is already in the field.
  /// Submitting clears the suggestion controller, so without this a tap back
  /// into a committed query would show recents and nothing else until the
  /// next keystroke - which is not how the field behaved a moment earlier.
  void _onSearchFieldFocusChanged() {
    if (!mounted || !_focusNode.hasFocus) return;
    setState(() => _isPanelOpen = true);

    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final controller = ref.read(searchSuggestionControllerProvider.notifier);
    if (ref.read(searchSuggestionControllerProvider).query == text) return;
    controller.onQueryChanged(text);
  }

  /// The recents to show, given the text in the field.
  ///
  /// Empty while the panel is closed, so the key handlers and the body agree
  /// on what is on screen.
  List<String> _recentsFor(List<String> history) {
    if (!_isPanelOpen) return const [];
    final trimmed = _controller.text.trim();
    return matchingSearchHistory(
      history,
      trimmed,
      limit: trimmed.isEmpty
          ? kSearchHistoryEmptyFieldLimit
          : kSearchHistoryTypingLimit,
    );
  }

  /// Whether the panel is up with rows in it, or with suggestions on their
  /// way to it.
  ///
  /// Read by the D-pad handlers to decide whether pressing down should land
  /// in the panel - or wait for its rows - or skip past it to the results.
  bool _panelHasRows() {
    if (!_isPanelOpen) return false;
    final suggestionState = ref.read(searchSuggestionControllerProvider);
    if (suggestionState.isLoading || suggestionState.suggestions.isNotEmpty) {
      return true;
    }
    return _recentsFor(ref.read(searchHistoryProvider)).isNotEmpty;
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onSearchFieldFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    _clearButtonFocusNode.dispose();
    _moviesShowsFocusNode.dispose();
    _liveTvFocusNode.dispose();
    _firstSuggestionFocusNode.dispose();
    _firstResultFocusNode.dispose();
    _checksFocusNode.dispose();
    _resultsScrollController.dispose();
    super.dispose();
  }

  void _submitSearch(String val) {
    final trimmed = val.trim();
    _controller.value = TextEditingValue(
      text: trimmed,
      selection: TextSelection.collapsed(offset: trimmed.length),
    );
    // Recorded on the way into the search, not on the way out: a query that
    // returned nothing is still one the user made and may want back.
    unawaited(ref.read(searchHistoryProvider.notifier).add(trimmed));
    ref.read(searchSuggestionControllerProvider.notifier).clear();
    ref.read(searchQueryProvider.notifier).set(trimmed);
    // Dismiss keyboard after submitting, just like YouTube / browser.
    _focusNode.unfocus();
    // _onTextChanged reopened the panel as the value above was written; the
    // submit is what closes it, so this has to come after.
    if (mounted) setState(() => _isPanelOpen = false);
  }

  void _fillSuggestion(String suggestion) {
    _controller.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
    ref
        .read(searchSuggestionControllerProvider.notifier)
        .onQueryChanged(suggestion);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    // Size question, asked of the size: a 960 dp television clears the
    // tablet breakpoint like any other big window.
    final isWidescreen = context.isTabletOrLarger;

    final theme = Theme.of(context);

    if (isWidescreen) {
      // No backdrop photograph, no stage lighting, no Stack. The screen was
      // a cinema still under four blending gradients and a focus spotlight,
      // all of it there to make one JPEG sit on the background - and all of
      // it behind a search field and a list of text. What the user reads is
      // now what the screen paints.
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Column(
          children: [
            const SizedBox(height: 24),
            Focus(
              canRequestFocus: false,
              skipTraversal: true,
              includeSemantics: false,
              onKeyEvent: _pillKeys,
              child: SearchHeaderBar(
                textController: _controller,
                searchFocusNode: _focusNode,
                clearButtonFocusNode: _clearButtonFocusNode,
                moviesShowsFocusNode: _moviesShowsFocusNode,
                liveTvFocusNode: _liveTvFocusNode,
                isCompact: false,
                // The recents and suggestions hang under the field as a
                // flyout here rather than covering the results, which on a
                // desktop-sized window would blank most of the screen to show
                // four rows of text.
                flyout: _buildFlyout(context),
                onDismissFlyout: () {
                  if (mounted) setState(() => _isPanelOpen = false);
                },
                onSubmitted: _submitSearch,
                onChanged: (val) {
                  ref
                      .read(searchSuggestionControllerProvider.notifier)
                      .onQueryChanged(val);
                },
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 24.0),
                child: _buildResultsView(context),
              ),
            ),
          ],
        ),
      );
    }

    // Mobile layout: existing AppBar
    return _buildMobileLayout(context);
  }

  Widget _buildMobileLayout(BuildContext context) {
    final searchResultsAsync = ref.watch(searchResultsProvider);
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        // v5: the round scope button (🍿 Non Livestreams / Livestreams)
        // that sat here is gone; phone Search always searches titles.
        title: GestureDetector(
          onTap: () => _focusNode.requestFocus(),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 42,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, child) {
                final isSearching = searchResultsAsync.maybeWhen(
                  data: (state) => state.isLoading,
                  loading: () => true,
                  orElse: () => false,
                );

                Widget? suffix;
                if (isSearching) {
                  suffix = Padding(
                    padding: const EdgeInsets.all(12),
                    child: AppLoadingIndicator(
                      color: theme.colorScheme.primary,
                      constraints: BoxConstraints.tight(const Size(18, 18)),
                    ),
                  );
                } else if (value.text.isNotEmpty) {
                  suffix = IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(32, 32),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () {
                      _controller.clear();
                      ref
                          .read(searchSuggestionControllerProvider.notifier)
                          .clear();
                      ref.read(searchQueryProvider.notifier).set('');
                    },
                  );
                }

                return TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: false,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                  textAlignVertical: TextAlignVertical.center,
                  textInputAction: TextInputAction.search,
                  onChanged: (val) {
                    ref
                        .read(searchSuggestionControllerProvider.notifier)
                        .onQueryChanged(val);
                  },
                  onSubmitted: _submitSearch,
                  decoration: InputDecoration(
                    hintText: l10n.searchHint,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        LayoutConstants.radiusPill,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        LayoutConstants.radiusPill,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        LayoutConstants.radiusPill,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 42,
                    ),
                    suffixIcon: suffix,
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 42,
                      minHeight: 42,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      body: _buildBody(context),
    );
  }

  /// What belongs in the panel right now, or null when it stays shut.
  ///
  /// One answer for both surfaces: on a phone the panel takes over the body,
  /// on a desktop it is a flyout under the field, and neither may disagree
  /// with the other about whether there is anything to show.
  ({List<String> recents, List<String> suggestions, bool isLoading})?
  _panelData() {
    final suggestionState = ref.watch(searchSuggestionControllerProvider);
    final recents = _recentsFor(ref.watch(searchHistoryProvider));
    final suggestions = withoutDuplicatedHistory(
      suggestionState.suggestions,
      recents,
    );
    final typedLongEnough = suggestionState.query.trim().length >= 2;
    final hasSuggestionContent =
        typedLongEnough &&
        (suggestionState.isLoading || suggestions.isNotEmpty);

    // With nothing to put in it the panel stays shut, so an empty field and
    // an empty history still get the "search for your favourite content"
    // prompt rather than a blank screen.
    if (!_isPanelOpen || (recents.isEmpty && !hasSuggestionContent)) {
      return null;
    }
    return (
      recents: recents,
      suggestions: suggestions,
      isLoading: suggestionState.isLoading,
    );
  }

  /// The desktop flyout's contents, or null when there is no flyout.
  Widget? _buildFlyout(BuildContext context) {
    final panel = _panelData();
    if (panel == null) return null;
    return _buildSuggestionsView(
      context,
      recents: panel.recents,
      suggestions: panel.suggestions,
      isLoadingSuggestions: panel.isLoading,
      isFlyout: true,
    );
  }

  /// The phone body, where the panel covers the results outright.
  Widget _buildBody(BuildContext context) {
    final panel = _panelData();
    if (panel == null) return _buildResultsView(context);
    return _buildSuggestionsView(
      context,
      recents: panel.recents,
      suggestions: panel.suggestions,
      isLoadingSuggestions: panel.isLoading,
    );
  }

  Widget _buildResultsView(BuildContext context) {
    final state = ref.watch(searchResultsProvider).asData?.value;
    final startedAt = state?.startedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The category chips filter the results below; they sit above the
        // checks, so a chip tap never moves the list it filters.
        const SearchCategoryChips(),
        if (startedAt != null)
          CheckSection(
            since: startedAt,
            // The extensions', and the add-ons' that searched with them.
            providers: [
              ...ref.read(extensionManagerProvider.notifier).getAllProviders(),
              ...?state?.others,
            ],
            rerunning: state!.rerunning,
            focusNode: _checksFocusNode,
          ),
        Expanded(
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            includeSemantics: false,
            onKeyEvent: _resultKeys,
            child: _buildResultsList(context),
          ),
        ),
      ],
    );
  }

  /// The icon of the plugin [providerId] names, when it publishes one.
  String? _sourceIcon(String providerId) {
    final provider = ref
        .read(extensionManagerProvider.notifier)
        .getProvider(providerId);
    return provider is CloudStreamProvider
        ? provider.plugin.info.iconUrl
        : null;
  }

  Widget _buildResultsList(BuildContext context) {
    final searchResultsAsync = ref.watch(searchResultsProvider);
    final category = ref.watch(searchCategoryProvider);
    final l10n = AppLocalizations.of(context)!;

    return searchResultsAsync.when(
      data: (state) {
        // The chips filter each provider's section, and a section with
        // nothing left under the chip is hidden outright — an empty
        // section header over nothing is not a filter result.
        final sections = [
          for (final section in state.results)
            (
              section,
              section.results
                  .where((item) => matchesSearchCategory(item, category))
                  .toList(),
            ),
        ].where((entry) => entry.$2.isNotEmpty).toList();
        final allResults = sections.expand((entry) => entry.$2).toList();

        if (allResults.isEmpty && !state.isLoading) {
          return _buildEmptyState(context, category: category);
        } else if (allResults.isEmpty && state.isLoading) {
          return const Center(child: AppLoadingIndicator());
        }

        // One section per source (v5, design A "Rows"): each source that
        // answered gets its own row under its own name; plugins' rows
        // first, in the order they answered, then the Stremio add-ons'
        // and Nuvio's. A source with nothing (or an error) has no row.
        final ordered = orderSearchSections(sections);

        void open(
          BuildContext context,
          ProviderSearchResult from,
          MultimediaItem item,
        ) {
          final source = from.source;
          if (source != null) {
            unawaited(source.open(context, item));
            return;
          }
          DetailsRoute(
            $extra: DetailsRouteExtra(item: item),
          ).push<void>(context);
        }

        // RepaintBoundary isolates list repaints from the rest of the
        // screen (app bar, background) so each incremental result update
        // only repaints the list — not the entire scaffold.
        return RepaintBoundary(
          child: ListView.builder(
            controller: _resultsScrollController,
            padding: EdgeInsets.only(
              bottom: LayoutConstants.shellBottomContentPadding(context),
            ),
            itemCount: ordered.length,
            itemBuilder: (context, index) {
              final pResult = ordered[index].$1;
              final items = ordered[index].$2;
              final name = cleanPluginName(pResult.providerName);
              return SearchSourceRow(
                key: ValueKey('search-section-${pResult.providerId}'),
                sourceId: pResult.providerId,
                name: name,
                iconUrl: _sourceIcon(pResult.providerId),
                results: items,
                firstCardFocusNode: index == 0 ? _firstResultFocusNode : null,
                onOpen: (item) => open(context, pResult, item),
                onViewAll: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => SearchSourceGridScreen(
                      title: '$name · ${items.length}',
                      results: items,
                      onOpen: (context, item) => open(context, pResult, item),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
      loading: () => const Center(child: AppLoadingIndicator()),
      error: (err, stack) =>
          Center(child: Text(l10n.errorPrefix(err.toString()))),
    );
  }

  /// The recents and suggestions the user picks from.
  ///
  /// One list rather than two so the entry animation staggers across the
  /// whole panel and D-pad travel runs uninterrupted from the last recent
  /// into the first suggestion.
  Widget _buildSuggestionsView(
    BuildContext context, {
    required List<String> recents,
    required List<String> suggestions,
    required bool isLoadingSuggestions,
    bool isFlyout = false,
  }) {
    final l10n = AppLocalizations.of(context)!;

    // Up from the first row returns to the field, which is what sits
    // directly above the panel.
    void focusSearchField() => _focusNode.requestFocus();

    var index = 0;
    final rows = <Widget>[];

    Widget staggered(int position, Widget row) {
      return BouncyEntryAnimation(
        delay: Duration(milliseconds: position * 40),
        child: row,
      );
    }

    for (final query in recents) {
      final isFirst = index == 0;
      rows.add(
        staggered(
          index,
          SearchSuggestionRow(
            key: ValueKey('search-history-$query'),
            text: query,
            icon: Icons.history_rounded,
            focusNode: isFirst ? _firstSuggestionFocusNode : null,
            isFirst: isFirst,
            onFocusUp: focusSearchField,
            trailingIcon: Icons.close_rounded,
            trailingSemanticLabel: l10n.removeFromSearchHistory(query),
            onTap: () => _submitSearch(query),
            onTrailingTap: () =>
                ref.read(searchHistoryProvider.notifier).remove(query),
          ),
        ),
      );
      index++;
    }

    for (final suggestion in suggestions) {
      final isFirst = index == 0;
      rows.add(
        staggered(
          index,
          SearchSuggestionRow(
            key: ValueKey('search-suggestion-$suggestion'),
            text: suggestion,
            icon: Icons.search_rounded,
            focusNode: isFirst ? _firstSuggestionFocusNode : null,
            isFirst: isFirst,
            onFocusUp: focusSearchField,
            trailingIcon: Icons.north_west_rounded,
            onTap: () => _submitSearch(suggestion),
            onTrailingTap: () => _fillSuggestion(suggestion),
          ),
        ),
      );
      index++;
    }

    if (isLoadingSuggestions) {
      rows.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: AppLoadingIndicator()),
        ),
      );
    }

    return ListView(
      // Wrapped to its contents in the flyout so three recents make a small
      // panel and a full list makes one that scrolls at its ceiling - a
      // fixed-height box with three rows in it is a hole, not a flyout.
      shrinkWrap: isFlyout,
      padding: isFlyout
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
          : EdgeInsets.only(
              left: 8,
              right: 8,
              bottom: LayoutConstants.shellBottomContentPadding(context),
            ),
      children: [
        if (recents.isNotEmpty)
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: l10n.recentSearches,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: rows.take(recents.length).toList(),
            ),
          ),
        ...rows.skip(recents.length),
      ],
    );
  }

  Widget _buildEmptyState(
    BuildContext context, {
    SearchCategory category = SearchCategory.all,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final query = ref.watch(searchQueryProvider);
    final isInputEmpty = _controller.text.trim().isEmpty;

    if (query.isEmpty || isInputEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.movie_filter_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.65),
            ),
            const SizedBox(height: LayoutConstants.spacingMd),
            Text(
              l10n.searchFavoriteContent,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.pressSearchOrEnter,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final nativeFont = Theme.of(context).textTheme.bodyLarge?.fontFamily;
    final isWidescreen = context.isTabletOrLarger;
    final imageWidth = isWidescreen ? 320.0 : 200.0;

    // No search results found: display No Results Found text and the image grouped vertically.
    // A chip that filtered everything out names itself, so the empty screen
    // says which filter hid the results rather than that the search failed.
    final noResultsText = category == SearchCategory.all
        ? 'No Results Found'
        : 'No ${searchCategoryLabel(category)} results found';
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            noResultsText,
            style: TextStyle(
              fontFamily: nativeFont,
              fontSize: 16.0,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Image.asset(
            'assets/images/no_results.png',
            fit: BoxFit.contain,
            width: imageWidth,
            // Source is 1613x1929 — 11.9 MB decoded — for an illustration
            // shown at 320 logical px at most. 640 covers 2x density.
            cacheWidth: 640,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// The sections in the order Search shows them: plugins' first, in the
/// order they answered, then the Stremio add-ons' and Nuvio's.
@visibleForTesting
List<(ProviderSearchResult, List<MultimediaItem>)> orderSearchSections(
  List<(ProviderSearchResult, List<MultimediaItem>)> sections,
) {
  bool isPlugin((ProviderSearchResult, List<MultimediaItem>) entry) =>
      entry.$1.kind == SearchSourceKind.zorox ||
      entry.$1.kind == SearchSourceKind.cloudstream;
  return [...sections.where(isPlugin), ...sections.where((e) => !isPlugin(e))];
}
