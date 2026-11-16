/// Developer Options: the Settings toggle for the QoE log / debug info.
///
/// The design preview shows Developer Options as a gold toggle in
/// Settings > App Data & Developer (OFF by default), not as a screen of
/// its own. The toggle drives the same flag the Developer Options screen
/// already uses: [QoeLog.writeToAppLog] (persisted as `dev_qoe_log`).
/// Enabling it shows the QoE stats overlay in the player and writes QoE
/// events to the app log; the Developer Options screen still holds the
/// rest of the debug tools.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/settings_repository.dart';
import '../../player/domain/qoe_log.dart';

part 'developer_options_provider.g.dart';

@Riverpod(keepAlive: true)
class DeveloperOptions extends _$DeveloperOptions {
  late SettingsRepository _repository;

  @override
  bool build() {
    _repository = ref.watch(settingsRepositoryProvider);
    return _repository.getDevQoeLog();
  }

  Future<void> setEnabled(bool enabled) async {
    if (state == enabled) return;
    state = enabled;
    QoeLog.writeToAppLog = enabled;
    await _repository.setDevQoeLog(enabled);
  }
}
