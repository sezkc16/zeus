/// Build 77: the bytes of one film, kept on disk in a bounded ring.
///
/// The stream cache proxy (see `stream_cache_proxy.dart`) writes every
/// byte it passes to the player through this store, so a later request
/// for a region it still holds is answered from the file instead of
/// from the host.
///
/// The store holds ONE contiguous window of the film, `[start, end)` in
/// the film's own byte offsets. Appending past [capacity] drops the
/// oldest bytes (the window's start moves up); it never grows the file
/// past [capacity]. Byte `o` of the film lives at file position
/// `o % capacity`, so nothing is ever moved.
///
/// The file is the only place the bytes live: the store keeps no copy
/// in memory, so its cost in RAM is a few integers however long the
/// film is.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class RingStore {
  RingStore(this._file, this.capacity) : assert(capacity > 0);

  /// Opens (creating or truncating) the ring's file at [path].
  factory RingStore.open(String path, int capacity) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return RingStore(file.openSync(mode: FileMode.write), capacity);
  }

  final RandomAccessFile _file;

  /// The most bytes the window — and the file — ever holds.
  final int capacity;

  int _start = 0;
  int _end = 0;
  bool _closed = false;

  /// The first film offset still held.
  int get start => _start;

  /// One past the last film offset held: where the next append lands.
  int get end => _end;

  /// How many bytes are held.
  int get length => _end - _start;

  bool get isClosed => _closed;

  /// Whether a read starting at [offset] can be answered: the offset is
  /// inside the window, or exactly at its end (nothing to read yet, but
  /// the next append continues from there).
  bool covers(int offset) => offset >= _start && offset <= _end;

  /// Forgets everything and starts a new window at [offset].
  void reset(int offset) {
    _start = offset;
    _end = offset;
  }

  /// Adds [data] at the window's end, dropping the oldest bytes when
  /// the window would pass [capacity]. Throws a [FileSystemException]
  /// when the disk refuses the write (full, gone) — the window is then
  /// unchanged up to the bytes already written, and the caller stops
  /// using the store.
  void append(List<int> data) {
    if (_closed) throw StateError('RingStore is closed');
    final bytes = data;
    var skip = 0;
    // More than the ring can hold in one go: only the tail survives.
    if (bytes.length > capacity) {
      skip = bytes.length - capacity;
      _end += skip;
      _start = _end;
    }
    var remaining = bytes.length - skip;
    var from = skip;
    while (remaining > 0) {
      final at = _end % capacity;
      final run = math.min(remaining, capacity - at);
      _file.setPositionSync(at);
      _file.writeFromSync(bytes, from, from + run);
      _end += run;
      from += run;
      remaining -= run;
    }
    if (_end - _start > capacity) _start = _end - capacity;
  }

  /// Reads up to [max] bytes starting at film offset [offset] into
  /// [into], and returns how many were read: fewer than asked when the
  /// window ends first or the ring wraps (ask again for the rest), and
  /// 0 when [offset] is not held.
  int read(int offset, Uint8List into, [int? max]) {
    if (_closed) throw StateError('RingStore is closed');
    if (offset < _start || offset >= _end) return 0;
    final at = offset % capacity;
    final want = math.min(
      math.min(max ?? into.length, into.length),
      math.min(_end - offset, capacity - at),
    );
    if (want <= 0) return 0;
    _file.setPositionSync(at);
    return _file.readIntoSync(into, 0, want);
  }

  /// Closes the file. The caller deletes it.
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _file.closeSync();
    } catch (_) {}
  }
}
