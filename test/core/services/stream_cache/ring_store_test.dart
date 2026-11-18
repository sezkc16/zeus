// Build 77: the ring the stream cache proxy keeps a film's bytes in.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/services/stream_cache/ring_store.dart';

int filmByte(int offset) => (offset * 31 + (offset >> 8) * 7 + 3) & 0xFF;

Uint8List film(int from, int count) {
  final out = Uint8List(count);
  for (var i = 0; i < count; i++) {
    out[i] = filmByte(from + i);
  }
  return out;
}

void main() {
  late Directory dir;
  late RingStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ring_store_test');
  });

  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  Uint8List readAll(int offset, int count) {
    final out = BytesBuilder();
    final buffer = Uint8List(4096);
    var at = offset;
    while (out.length < count) {
      final got = store.read(at, buffer, count - out.length);
      if (got == 0) break;
      out.add(Uint8List.sublistView(buffer, 0, got));
      at += got;
    }
    return out.toBytes();
  }

  test('holds what was appended and reads any part of it back', () {
    store = RingStore.open('${dir.path}/a.ring', 1000);
    store.append(film(0, 600));
    expect(store.start, 0);
    expect(store.end, 600);
    expect(store.length, 600);
    expect(readAll(0, 600), film(0, 600));
    expect(readAll(123, 77), film(123, 77));
  });

  test('a window can start anywhere in the film', () {
    store = RingStore.open('${dir.path}/a.ring', 1000);
    store.reset(5000000000);
    store.append(film(5000000000, 900));
    expect(store.start, 5000000000);
    expect(store.end, 5000000900);
    expect(readAll(5000000100, 800), film(5000000100, 800));
  });

  test('never holds more than its capacity: the oldest bytes go', () {
    store = RingStore.open('${dir.path}/a.ring', 1000);
    for (var at = 0; at < 10000; at += 300) {
      store.append(film(at, 300));
      expect(store.length, lessThanOrEqualTo(1000));
    }
    expect(store.end, 10200);
    expect(store.start, 9200);
    expect(readAll(9200, 1000), film(9200, 1000));
    // The file itself is the ring: it never grows past the capacity.
    expect(File('${dir.path}/a.ring').lengthSync(), lessThanOrEqualTo(1000));
  });

  test('a read outside the window answers nothing', () {
    store = RingStore.open('${dir.path}/a.ring', 1000);
    store.reset(2000);
    store.append(film(2000, 500));
    final buffer = Uint8List(100);
    expect(store.read(1999, buffer), 0);
    expect(store.read(2500, buffer), 0);
    expect(store.read(9999, buffer), 0);
    expect(store.covers(1999), isFalse);
    expect(store.covers(2000), isTrue);
    // The end itself is "covered": the next append continues there.
    expect(store.covers(2500), isTrue);
    expect(store.covers(2501), isFalse);
  });

  test('a read stops at the window end and at the wrap, never past', () {
    store = RingStore.open('${dir.path}/a.ring', 1000);
    store.append(film(0, 1500)); // window 500..1500, wraps at 1000
    final buffer = Uint8List(4096);
    final first = store.read(900, buffer);
    expect(first, 100); // up to the wrap
    expect(Uint8List.sublistView(buffer, 0, first), film(900, 100));
    final second = store.read(1000, buffer);
    expect(second, 500); // up to the end
    expect(Uint8List.sublistView(buffer, 0, second), film(1000, 500));
  });

  test('one append bigger than the ring keeps its tail', () {
    store = RingStore.open('${dir.path}/a.ring', 1000);
    store.append(film(0, 3500));
    expect(store.end, 3500);
    expect(store.start, 2500);
    expect(readAll(2500, 1000), film(2500, 1000));
  });

  test('reset forgets everything', () {
    store = RingStore.open('${dir.path}/a.ring', 1000);
    store.append(film(0, 800));
    store.reset(70000);
    expect(store.length, 0);
    expect(store.read(100, Uint8List(10)), 0);
    store.append(film(70000, 50));
    expect(readAll(70000, 50), film(70000, 50));
  });

  test('a closed store refuses work', () {
    store = RingStore.open('${dir.path}/a.ring', 1000);
    store.append(film(0, 10));
    store.close();
    expect(store.isClosed, isTrue);
    expect(() => store.append(film(10, 10)), throwsStateError);
    expect(() => store.read(0, Uint8List(10)), throwsStateError);
  });
}
