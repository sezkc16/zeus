import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/notification_service.dart';
import '../../account/data/zorox_account_notifier.dart';
import '../data/zeus_profile.dart';

/// The §9-case-3 prompt (Build 2): the account has profiles and this
/// device still has legacy (pre-profile) watch history / My List.
///
/// [Move] merges the legacy data into [targetProfile] (newest wins, the
/// same rule as a backup restore), uploads that profile's backup so the
/// cloud gets the merged data, then clears the legacy boxes. [Skip]
/// leaves everything alone — the prompt asks again on the next app
/// start while the legacy boxes are non-empty. Settings → Accounts also
/// offers the same move, plus "Delete this device's data".
///
/// Returns true when the data was moved, false when skipped, null when
/// the dialog was dismissed.
Future<bool?> showZeusLegacyMoveDialog(
  BuildContext context,
  WidgetRef ref, {
  required ZeusProfile targetProfile,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _LegacyMoveDialog(targetProfile: targetProfile),
  );
}

class _LegacyMoveDialog extends ConsumerStatefulWidget {
  const _LegacyMoveDialog({required this.targetProfile});

  final ZeusProfile targetProfile;

  @override
  ConsumerState<_LegacyMoveDialog> createState() => _LegacyMoveDialogState();
}

class _LegacyMoveDialogState extends ConsumerState<_LegacyMoveDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _move() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref
        .read(zoroxAccountProvider.notifier)
        .moveLegacyDataIntoZeusProfile(widget.targetProfile.id);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error =
            ref.read(zoroxAccountProvider).error ??
            'Could not move the data. Try again.';
      });
      return;
    }
    ref
        .read(notificationServiceProvider)
        .showSuccess(
          'Your old history and My List moved into ${widget.targetProfile.name}.',
          title: 'Profiles',
          icon: Icons.check_circle_rounded,
        );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move this device’s data?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This device has watch history and a My List from before '
            'profiles. Move it into ${widget.targetProfile.name}?',
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: _busy ? null : _move,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Move'),
        ),
      ],
    );
  }
}
