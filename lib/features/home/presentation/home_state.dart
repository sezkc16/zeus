import '../../../../core/domain/entity/multimedia_item.dart';

sealed class HomeState {
  const HomeState();
}

class HomeLoading extends HomeState {
  const HomeLoading();
}

class HomeNoProvider extends HomeState {
  const HomeNoProvider();
}

class HomeOffline extends HomeState {
  const HomeOffline();
}

class HomeError extends HomeState {
  final String message;
  const HomeError(this.message);
}

class HomeSuccess extends HomeState {
  final Map<String, List<MultimediaItem>> data;

  /// The plugin Home fell back from. The fallback feed was removed in
  /// build 92 — Home stays blank when a plugin's home fails or has no
  /// main page — so this is always null now. The field stays so the
  /// screen's toast and row-prefs plumbing keep compiling unchanged.
  final String? fellBackFrom;

  const HomeSuccess(this.data, {this.fellBackFrom});
}
