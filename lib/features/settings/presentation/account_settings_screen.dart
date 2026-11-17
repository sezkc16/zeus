import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/router/app_router.dart';

import 'package:zorox/l10n/generated/app_localizations.dart';

import 'widgets/settings_widgets.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/tracking_auth_dialog.dart';
import 'player_settings_provider.dart';
import 'general_settings_provider.dart';
import '../../../core/network/doh_service.dart';

import '../../../core/logger/app_logger.dart';
import '../../../core/config/tmdb_config.dart';
import '../../tracking/presentation/tracking_auth_provider.dart';
import '../../tracking/data/simkl_service.dart';
import '../../tracking/data/trakt_service.dart';
import '../../tracking/data/wetrakr_service.dart';
import '../../tracking/data/mal_service.dart';
import '../../tracking/data/anilist_service.dart';
import '../../tracking/sign_in/sign_in_runner.dart';
import '../../tracking/sign_in/tracker_sign_in.dart';
import '../../../core/providers/device_info_provider.dart';
import '../../../core/storage/settings_repository.dart';
import '../../../core/services/notification_service.dart';
import '../../account/presentation/zorox_account_section.dart';

class AccountSettingsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;

  const AccountSettingsScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<AccountSettingsScreen> createState() =>
      _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends ConsumerState<AccountSettingsScreen> {
  final FocusNode _simklFocusNode = FocusNode();
  final FocusNode _traktFocusNode = FocusNode();
  final FocusNode _wetrakrFocusNode = FocusNode();
  final FocusNode _malFocusNode = FocusNode();
  final FocusNode _anilistFocusNode = FocusNode();

  @override
  void dispose() {
    _simklFocusNode.dispose();
    _traktFocusNode.dispose();
    _wetrakrFocusNode.dispose();
    _malFocusNode.dispose();
    _anilistFocusNode.dispose();
    super.dispose();
  }

  /// Signs in to [provider] in ZoroX's own browser, in the check sheet.
  /// See lib/features/tracking/sign_in/.
  Future<SignInResult> _signIn(
    BuildContext context,
    String provider,
    Future<SignInResult> Function(TrackerSignIn signIn) start,
  ) async {
    final tv = ref.read(deviceProfileProvider).value?.isTv ?? false;
    try {
      return await start(
        TrackerSignIn(
          run: SignInRunner(context, provider: provider, tv: tv).call,
        ),
      );
    } catch (e, stack) {
      talker.error('AccountSettingsScreen: $provider sign-in threw', e, stack);
      return SignInResult.failed;
    }
  }

  Future<bool> _confirmDisconnect(
    BuildContext context,
    String providerName,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect $providerName'),
        content: Text(
          'Are you sure you want to disconnect your $providerName account?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Disconnect',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playerSettings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    final generalSettings = ref.watch(generalSettingsProvider);
    final settingsRepo = ref.watch(settingsRepositoryProvider);

    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: ListView(
            // The shell hides the nav pill on the Settings branch, so the
            // list ends with the safe area plus a small gap; if the pill is
            // ever shown over this route the helper clears it instead.
            padding: EdgeInsets.only(
              bottom: LayoutConstants.pillFreeBottomContentPadding(context),
            ),
            children: [
              const SizedBox(height: LayoutConstants.spacingXs),
              const ZoroxAccountSection(),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                title: 'Subtitle Accounts',
                children: [
                  SettingsTile(
                    reicon: Reicon.subtitles,
                    title: l10n.openSubtitles,
                    // A stored username is not a session: with no API key the
                    // provider returns nothing before it sends a request, so
                    // nothing has ever logged in with it.
                    subtitle: !playerSettings.hasOpenSubtitlesKey
                        ? l10n.keyNotSet
                        : playerSettings.osUsername.isNotEmpty
                        ? l10n.loggedInAs(playerSettings.osUsername)
                        : l10n.notLoggedIn,
                    value: playerSettings.hasOpenSubtitlesKey
                        ? 'Active'
                        : 'Connect',
                    onTap: () => showOpenSubtitlesAuthDialog(
                      context,
                      ref,
                      playerSettings,
                    ),
                  ),
                  SettingsTile(
                    reicon: Reicon.subtitles,
                    title: l10n.subDl,
                    subtitle: playerSettings.subdlApiKey.isNotEmpty
                        ? l10n.apiKeyConfigured
                        : l10n.keyNotSet,
                    value: playerSettings.subdlApiKey.isNotEmpty
                        ? 'Active'
                        : 'Connect',
                    onTap: () =>
                        showSubDlAuthDialog(context, ref, playerSettings),
                  ),
                  SettingsTile(
                    reicon: Reicon.subtitles,
                    title: l10n.subSource,
                    subtitle: playerSettings.subsourceApiKey.isNotEmpty
                        ? l10n.apiKeyConfigured
                        : l10n.keyNotSet,
                    value: playerSettings.subsourceApiKey.isNotEmpty
                        ? 'Active'
                        : 'Connect',
                    isLast: true,
                    onTap: () =>
                        showSubSourceAuthDialog(context, ref, playerSettings),
                  ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                title: 'Tracking & Sync',
                children: [
                  Consumer(
                    builder: (context, ref, _) {
                      final trackingAuthAsync = ref.watch(trackingAuthProvider);
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SettingsTile(
                            focusNode: _simklFocusNode,
                            reicon: Reicon.chart,
                            title: 'Simkl',
                            subtitle: trackingAuthAsync.when(
                              data: (state) => state['simkl'] == true
                                  ? 'Connected · sync on'
                                  : l10n.notLoggedIn,
                              loading: () => l10n.loading,
                              error: (_, _) => l10n.unknown,
                            ),
                            value: trackingAuthAsync.value?['simkl'] == true
                                ? 'Active'
                                : 'Connect',
                            onTap: () async {
                              final state = trackingAuthAsync.value ?? {};
                              if (state['simkl'] == true) {
                                final confirm = await _confirmDisconnect(
                                  context,
                                  'Simkl',
                                );
                                if (confirm) {
                                  await ref.read(simklServiceProvider).logout();
                                  ref.invalidate(trackingAuthProvider);
                                  if (context.mounted) {
                                    FocusScope.of(context).requestFocus();
                                  }
                                }
                              } else {
                                bool isCancelled = false;
                                bool isDialogShowing = false;
                                BuildContext? dialogContext;
                                bool success = false;
                                try {
                                  success = await ref
                                      .read(simklServiceProvider)
                                      .login(
                                        isCancelled: () => isCancelled,
                                        onDeviceCodeGenerated:
                                            (url, code) async {
                                              if (context.mounted) {
                                                isDialogShowing = true;
                                                unawaited(
                                                  showDialog<void>(
                                                    context: context,
                                                    barrierDismissible: true,
                                                    builder: (ctx) {
                                                      dialogContext = ctx;
                                                      return TrackingAuthDialog(
                                                        providerName: 'Simkl',
                                                        verificationUrl: url,
                                                        userCode: code,
                                                      );
                                                    },
                                                  ).then((_) {
                                                    isCancelled = true;
                                                    isDialogShowing = false;
                                                    if (context.mounted) {
                                                      FocusScope.of(context)
                                                          .requestFocus();
                                                    }
                                                  }),
                                                );
                                              }
                                            },
                                      );
                                } catch (error, stackTrace) {
                                  talker.error(
                                    'AccountSettingsScreen: Simkl login threw',
                                    error,
                                    stackTrace,
                                  );
                                }
                                if (success && context.mounted) {
                                  ref
                                      .read(notificationServiceProvider)
                                      .showSuccess(
                                        'Successfully connected to Simkl!',
                                        title: 'Simkl',
                                        icon: Icons.sync_rounded,
                                      );
                                } else if (!isCancelled && context.mounted) {
                                  // A device-code login that times out, is denied, or
                                  // throws all land here. Without this branch the tile
                                  // just falls back to "Not logged in" and the viewer
                                  // is told nothing at all. A dialog the viewer
                                  // dismissed is not a failure, hence the isCancelled
                                  // guard.
                                  ref
                                      .read(notificationServiceProvider)
                                      .showError(
                                        l10n.connectionFailed,
                                        title: 'Simkl',
                                        icon: Icons.sync_problem_rounded,
                                      );
                                }
                                if (isDialogShowing &&
                                    dialogContext != null &&
                                    dialogContext!.mounted) {
                                  Navigator.of(dialogContext!).pop();
                                }
                              }
                              ref.invalidate(trackingAuthProvider);
                            },
                          ),
                          SettingsTile(
                            focusNode: _traktFocusNode,
                            reicon: Reicon.tv,
                            title: 'Trakt',
                            subtitle: trackingAuthAsync.when(
                              data: (state) => state['trakt'] == true
                                  ? 'Connected · sync on'
                                  : l10n.notLoggedIn,
                              loading: () => l10n.loading,
                              error: (_, _) => l10n.unknown,
                            ),
                            value: trackingAuthAsync.value?['trakt'] == true
                                ? 'Active'
                                : 'Connect',
                            onTap: () async {
                              final state = trackingAuthAsync.value ?? {};
                              if (state['trakt'] == true) {
                                final confirm = await _confirmDisconnect(
                                  context,
                                  'Trakt',
                                );
                                if (confirm) {
                                  await ref.read(traktServiceProvider).logout();
                                  ref.invalidate(trackingAuthProvider);
                                  if (context.mounted) {
                                    _traktFocusNode.requestFocus();
                                  }
                                }
                              } else {
                                bool isCancelled = false;
                                bool isDialogShowing = false;
                                BuildContext? dialogContext;
                                bool success = false;
                                try {
                                  success = await ref
                                      .read(traktServiceProvider)
                                      .login(
                                        isCancelled: () => isCancelled,
                                        onDeviceCodeGenerated:
                                            (url, code) async {
                                              if (context.mounted) {
                                                isDialogShowing = true;
                                                unawaited(
                                                  showDialog<void>(
                                                    context: context,
                                                    barrierDismissible: true,
                                                    builder: (ctx) {
                                                      dialogContext = ctx;
                                                      return TrackingAuthDialog(
                                                        providerName: 'Trakt',
                                                        verificationUrl: url,
                                                        userCode: code,
                                                      );
                                                    },
                                                  ).then((_) {
                                                    isCancelled = true;
                                                    isDialogShowing = false;
                                                    if (context.mounted) {
                                                      _traktFocusNode
                                                          .requestFocus();
                                                    }
                                                  }),
                                                );
                                              }
                                            },
                                      );
                                } catch (error, stackTrace) {
                                  talker.error(
                                    'AccountSettingsScreen: Trakt login threw',
                                    error,
                                    stackTrace,
                                  );
                                }
                                if (success && context.mounted) {
                                  ref
                                      .read(notificationServiceProvider)
                                      .showSuccess(
                                        'Successfully connected to Trakt!',
                                        title: 'Trakt',
                                        icon: Icons.sync_rounded,
                                      );
                                } else if (!isCancelled && context.mounted) {
                                  // A device-code login that times out, is denied, or
                                  // throws all land here. Without this branch the tile
                                  // just falls back to "Not logged in" and the viewer
                                  // is told nothing at all. A dialog the viewer
                                  // dismissed is not a failure, hence the isCancelled
                                  // guard.
                                  ref
                                      .read(notificationServiceProvider)
                                      .showError(
                                        l10n.connectionFailed,
                                        title: 'Trakt',
                                        icon: Icons.sync_problem_rounded,
                                      );
                                }
                                if (isDialogShowing &&
                                    dialogContext != null &&
                                    dialogContext!.mounted) {
                                  Navigator.of(dialogContext!).pop();
                                }
                              }
                              ref.invalidate(trackingAuthProvider);
                            },
                          ),
                          if (ref.watch(wetrakrConfiguredProvider))
                            SettingsTile(
                              key: const ValueKey('account-wetrakr'),
                              focusNode: _wetrakrFocusNode,
                              reicon: Reicon.tv,
                              title: 'WeTrakr',
                              subtitle: trackingAuthAsync.when(
                                data: (state) => state['wetrakr'] == true
                                    ? 'Connected · sync on'
                                    : l10n.notLoggedIn,
                                loading: () => l10n.loading,
                                error: (_, _) => l10n.unknown,
                              ),
                              value: trackingAuthAsync.value?['wetrakr'] == true
                                  ? 'Active'
                                  : 'Connect',
                              onTap: () async {
                                final state = trackingAuthAsync.value ?? {};
                                if (state['wetrakr'] == true) {
                                  final confirm = await _confirmDisconnect(
                                    context,
                                    'WeTrakr',
                                  );
                                  if (confirm) {
                                    await ref
                                        .read(wetrakrServiceProvider)
                                        .logout();
                                    ref.invalidate(trackingAuthProvider);
                                    if (context.mounted) {
                                      _wetrakrFocusNode.requestFocus();
                                    }
                                  }
                                } else {
                                  bool isCancelled = false;
                                  bool isDialogShowing = false;
                                  BuildContext? dialogContext;
                                  bool success = false;
                                  try {
                                    success = await ref
                                        .read(wetrakrServiceProvider)
                                        .login(
                                          isCancelled: () => isCancelled,
                                          onDeviceCodeGenerated: (url, code) async {
                                            if (context.mounted) {
                                              isDialogShowing = true;
                                              unawaited(
                                                showDialog<void>(
                                                  context: context,
                                                  barrierDismissible: true,
                                                  builder: (ctx) {
                                                    dialogContext = ctx;
                                                    return TrackingAuthDialog(
                                                      providerName: 'WeTrakr',
                                                      verificationUrl: url,
                                                      userCode: code,
                                                    );
                                                  },
                                                ).then((_) {
                                                  isCancelled = true;
                                                  isDialogShowing = false;
                                                  if (context.mounted) {
                                                    _wetrakrFocusNode
                                                        .requestFocus();
                                                  }
                                                }),
                                              );
                                            }
                                          },
                                        );
                                  } catch (error, stackTrace) {
                                    talker.error(
                                      'AccountSettingsScreen: WeTrakr login threw',
                                      error,
                                      stackTrace,
                                    );
                                  }
                                  if (success && context.mounted) {
                                    ref
                                        .read(notificationServiceProvider)
                                        .showSuccess(
                                          'Successfully connected to WeTrakr!',
                                          title: 'WeTrakr',
                                          icon: Icons.sync_rounded,
                                        );
                                  } else if (!isCancelled && context.mounted) {
                                    // A device-code login that times out, is denied, or
                                    // throws all land here. Without this branch the tile
                                    // just falls back to "Not logged in" and the viewer
                                    // is told nothing at all. A dialog the viewer
                                    // dismissed is not a failure, hence the isCancelled
                                    // guard.
                                    ref
                                        .read(notificationServiceProvider)
                                        .showError(
                                          l10n.connectionFailed,
                                          title: 'WeTrakr',
                                          icon: Icons.sync_problem_rounded,
                                        );
                                  }
                                  if (isDialogShowing &&
                                      dialogContext != null &&
                                      dialogContext!.mounted) {
                                    Navigator.of(dialogContext!).pop();
                                  }
                                }
                                ref.invalidate(trackingAuthProvider);
                              },
                            ),
                          SettingsTile(
                            focusNode: _malFocusNode,
                            reicon: Reicon.listCheck,
                            title: 'MyAnimeList',
                            subtitle: trackingAuthAsync.when(
                              data: (state) => state['mal'] == true
                                  ? 'Connected · sync on'
                                  : l10n.notLoggedIn,
                              loading: () => l10n.loading,
                              error: (_, _) => l10n.unknown,
                            ),
                            value: trackingAuthAsync.value?['mal'] == true
                                ? 'Active'
                                : 'Connect',
                            onTap: () async {
                              final state = trackingAuthAsync.value ?? {};
                              if (state['mal'] == true) {
                                final confirm = await _confirmDisconnect(
                                  context,
                                  'MyAnimeList',
                                );
                                if (confirm) {
                                  await ref.read(malServiceProvider).logout();
                                  ref.invalidate(trackingAuthProvider);
                                  if (context.mounted) {
                                    _malFocusNode.requestFocus();
                                  }
                                }
                              } else {
                                final result = await _signIn(
                                  context,
                                  'MyAnimeList',
                                  (signIn) => signIn.myAnimeList(
                                    ref.read(malServiceProvider),
                                  ),
                                );
                                if (context.mounted) {
                                  if (result == SignInResult.signedIn) {
                                    ref
                                        .read(notificationServiceProvider)
                                        .showSuccess(
                                          'Successfully connected to MyAnimeList!',
                                          title: 'MyAnimeList',
                                          icon: Icons.sync_rounded,
                                        );
                                  } else if (result == SignInResult.failed) {
                                    ref
                                        .read(notificationServiceProvider)
                                        .showError(
                                          'Failed to connect to MyAnimeList',
                                          title: 'MyAnimeList',
                                          icon: Icons.sync_problem_rounded,
                                        );
                                  }
                                  _malFocusNode.requestFocus();
                                }
                              }
                              ref.invalidate(trackingAuthProvider);
                            },
                          ),
                          SettingsTile(
                            focusNode: _anilistFocusNode,
                            reicon: Reicon.bookOpen,
                            title: 'AniList',
                            subtitle: trackingAuthAsync.when(
                              data: (state) => state['anilist'] == true
                                  ? 'Connected · sync on'
                                  : l10n.notLoggedIn,
                              loading: () => l10n.loading,
                              error: (_, _) => l10n.unknown,
                            ),
                            value: trackingAuthAsync.value?['anilist'] == true
                                ? 'Active'
                                : 'Connect',
                            isLast: true,
                            onTap: () async {
                              final state = trackingAuthAsync.value ?? {};
                              if (state['anilist'] == true) {
                                final confirm = await _confirmDisconnect(
                                  context,
                                  'AniList',
                                );
                                if (confirm) {
                                  await ref
                                      .read(aniListServiceProvider)
                                      .logout();
                                  ref.invalidate(trackingAuthProvider);
                                  if (context.mounted) {
                                    _anilistFocusNode.requestFocus();
                                  }
                                }
                              } else {
                                final result = await _signIn(
                                  context,
                                  'AniList',
                                  (signIn) => signIn.aniList(
                                    ref.read(aniListServiceProvider),
                                  ),
                                );
                                if (context.mounted) {
                                  if (result == SignInResult.signedIn) {
                                    ref
                                        .read(notificationServiceProvider)
                                        .showSuccess(
                                          'Successfully connected to AniList!',
                                          title: 'AniList',
                                          icon: Icons.sync_rounded,
                                        );
                                  } else if (result == SignInResult.failed) {
                                    ref
                                        .read(notificationServiceProvider)
                                        .showError(
                                          'Failed to connect to AniList',
                                          title: 'AniList',
                                          icon: Icons.sync_problem_rounded,
                                        );
                                  }
                                  _anilistFocusNode.requestFocus();
                                }
                              }
                              ref.invalidate(trackingAuthProvider);
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                title: 'Integrations & Metadata',
                children: [
                  SettingsTile(
                    reicon: Reicon.key,
                    title: 'TMDB API key',
                    subtitle: 'Posters, logos & metadata',
                    value: generalSettings.tmdbApiKey.isNotEmpty
                        ? 'Custom key'
                        : (TmdbConfig.buildTimeApiKey.isNotEmpty
                              ? 'Built-in key'
                              : 'Not set'),
                    onTap: () => showTmdbApiKeyDialog(context, ref),
                  ),
                  SettingsTile(
                    reicon: Reicon.skipNext,
                    title: 'AnimeSkip',
                    isBeta: true,
                    subtitle: 'Skip segments for Anime',
                    trailing: Switch(
                      value: settingsRepo.isAnimeSkipIntegrationEnabled(),
                      onChanged: (val) {
                        settingsRepo.setAnimeSkipIntegrationEnabled(val);
                        // Trigger a rebuild
                        ref.invalidate(settingsRepositoryProvider);
                      },
                    ),
                    onTap: () {
                      final current = settingsRepo
                          .isAnimeSkipIntegrationEnabled();
                      settingsRepo.setAnimeSkipIntegrationEnabled(!current);
                      ref.invalidate(settingsRepositoryProvider);
                    },
                  ),
                  SettingsTile(
                    reicon: Reicon.skipNext,
                    title: 'IntroDB',
                    isBeta: true,
                    subtitle: 'Skip segments for TV Shows',
                    isLast: true,
                    trailing: Switch(
                      value: settingsRepo.isIntroDbIntegrationEnabled(),
                      onChanged: (val) {
                        settingsRepo.setIntroDbIntegrationEnabled(val);
                        ref.invalidate(settingsRepositoryProvider);
                      },
                    ),
                    onTap: () {
                      final current = settingsRepo
                          .isIntroDbIntegrationEnabled();
                      settingsRepo.setIntroDbIntegrationEnabled(!current);
                      ref.invalidate(settingsRepositoryProvider);
                    },
                  ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                title: l10n.network,
                children: [
                  Consumer(
                    builder: (context, ref, _) {
                      final dohState =
                          ref.watch(dohSettingsProvider).asData?.value ??
                          const DohSettings();
                      final generalSettings = ref.watch(
                        generalSettingsProvider,
                      );
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SettingsTile(
                            reicon: Reicon.shieldLock,
                            title: l10n.dnsOverHttps,
                            subtitle: 'Encrypt DNS lookups',
                            trailing: Switch(
                              value: dohState.enabled,
                              onChanged: (val) {
                                ref
                                    .read(dohSettingsProvider.notifier)
                                    .setEnabled(val);
                              },
                            ),
                            onTap: () {
                              ref
                                  .read(dohSettingsProvider.notifier)
                                  .setEnabled(!dohState.enabled);
                            },
                          ),
                          if (dohState.enabled)
                            SettingsTile(
                              reicon: Reicon.globe,
                              title: l10n.dohProvider,
                              value: getDohProviderLabel(
                                dohState.provider,
                                dohState.customUrl,
                                l10n,
                              ),
                              onTap: () => showDohProviderDialog(context, ref),
                            ),
                          // GitHub Proxy is a choice — None, jsDelivr,
                          // ghproxy, or a custom base URL — not a switch:
                          // the old toggle only ever meant jsDelivr, which
                          // is one of the choices now.
                          SettingsTile(
                            reicon: Reicon.serverPath,
                            title: l10n.githubProxy,
                            subtitle: 'For repo & extension downloads',
                            value: githubProxyLabel(generalSettings),
                            isLast: true,
                            onTap: () => showGithubProxyDialog(context, ref),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                title: l10n.downloads,
                children: [
                  SettingsTile(
                    reicon: Reicon.folder,
                    title: 'Download location',
                    value:
                        generalSettings.downloadDirectory ??
                        'On My iPhone › ZoroX',
                    onTap: () => showDownloadLocationDialog(
                      context,
                      ref,
                      generalSettings,
                    ),
                  ),
                  SettingsTile(
                    reicon: Reicon.download,
                    title: 'Parallel downloads',
                    value: '${generalSettings.downloadConcurrency}',
                    onTap: () => showDownloadConcurrencyDialog(
                      context,
                      ref,
                      generalSettings,
                    ),
                  ),
                  SettingsTile(
                    reicon: Reicon.layers,
                    title: 'Download segments per file',
                    value: generalSettings.downloadChunks == 1
                        ? 'Off'
                        : '${generalSettings.downloadChunks}',
                    isLast: true,
                    onTap: () =>
                        showDownloadChunksDialog(context, ref, generalSettings),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.isEmbedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              const SettingsRoute().go(context);
            }
          },
        ),
        title: Text('${l10n.accounts}, ${l10n.network} & ${l10n.downloads}'),
      ),
      body: content,
    );
  }
}
