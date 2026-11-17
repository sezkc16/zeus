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

  /// The plugin Home fell back from, when that plugin's home page failed
  /// (or had no main page) and the key-free For You feed is showing
  /// instead. Null for a normal feed — the screen shows a toast only
  /// while this is set.
  final String? fellBackFrom;

  const HomeSuccess(this.data, {this.fellBackFrom});
}
