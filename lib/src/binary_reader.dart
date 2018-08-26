import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Reads data in from a stream of bytes, which may or may not be continuous.
class BinaryReader extends StreamConsumer<List<int>> {
  final Queue<_BinaryReaderAwaiter> _awaiterQueue =
      new Queue<_BinaryReaderAwaiter>();
  final Queue<Uint8List> _byteQueue = new Queue<Uint8List>();

  static Uint8List coerceUint8List(List<int> list) {
    return list is Uint8List ? list : new Uint8List.fromList(list);
  }

  Future<Uint8List> read(int length) {
    var trace = StackTrace.current;
    // First, check if the top of the byte queue has enough bytes.
    if (_byteQueue.isNotEmpty) {
      var top = _byteQueue.first;

      // If the number of bytes is the *exact* amount, pop it and return.
      if (top.length == length) {
        _byteQueue.removeFirst();
        return new Future<Uint8List>.value(top);
      }

      // Or, if there is an excess of bytes,
      // return it, but only keep the remainder on the stack.
      else if (top.length > length) {
        var remainder =
            new Uint8List.view(top.buffer, top.offsetInBytes + length);
        var out = new Uint8List.view(top.buffer, top.offsetInBytes, length);
        _byteQueue.removeFirst();
        if (remainder.isNotEmpty) _byteQueue.addFirst(remainder);
        return new Future<Uint8List>.value(out);
      }
    }

    // Otherwise, create an awaiter, and try to fill it up.
    var awaiter = new _BinaryReaderAwaiter(trace, length);

    // Ideally, we will have enough bytes available.
    //
    // Remove buffers from the top of the queue until we have enough bytes.
    while (_byteQueue.isNotEmpty && awaiter.remaining > 0) {
      var top = _byteQueue.first;

      // If the amount is exactly the same, AND there are no bytes in the buffer,
      // just return the buffer itself.
      if (top.length == awaiter.remaining && awaiter.builder.isEmpty) {
        return new Future<Uint8List>.value(_byteQueue.removeFirst());
      }

      // If the buffer has less than or equal to the required number of bytes,
      // add it all and remove it.
      else if (top.length <= awaiter.remaining) {
        awaiter.builder.add(_byteQueue.removeFirst());
      }

      // Otherwise, add the necessary amount, and only leave
      // the remainder on the queue.
      else {
        var remainder =
            new Uint8List.view(top.buffer, top.offsetInBytes + length);
        var out = new Uint8List.view(top.buffer, top.offsetInBytes, length);
        _byteQueue.removeFirst();
        if (remainder.isNotEmpty) _byteQueue.addFirst(remainder);
        return new Future<Uint8List>.value(out);
      }
    }

    // If the awaiter is full, just return its value.
    if (awaiter.remaining <= 0) {
      return new Future<Uint8List>.value(
          coerceUint8List(awaiter.builder.takeBytes()));
    }

    // Otherwise, enqueue it until further notice.
    _awaiterQueue.addLast(awaiter);
    return awaiter.completer.future;
  }

  @override
  Future addStream(Stream<List<int>> stream) {
    return stream.map(coerceUint8List).forEach((buf) {
      int index = 0;

      // Complete any possible awaiters.
      while (_awaiterQueue.isNotEmpty && index < buf.length - 1) {
        var top = _awaiterQueue.first;

        // If this is the first entry being added, and it is the exact size, add it.
        if (top.remaining == buf.length && top.builder.isEmpty) {
          _awaiterQueue.removeFirst();
          top.completer.complete(buf);
          return;
        }

        // If the buffer has >= the size, add the whole thing.
        else if (top.remaining >= buf.length) {
          top.builder.add(buf);

          // Remove the awaiter if it's completed.
          if (top.remaining == 0) {
            _awaiterQueue.removeFirst();
            top.completer.complete(coerceUint8List(top.builder.toBytes()));
          }

          return;
        }

        // Otherwise, only add what is necessary.
        else {
          top.builder.add(new Uint8List.view(buf.buffer, 0, top.remaining));
          index = top.remaining;

          // Remove the awaiter if it's completed.
          if (top.remaining == 0) {
            _awaiterQueue.removeFirst();
            top.completer.complete(coerceUint8List(top.builder.toBytes()));
          }
        }
      }

      // Enqueue all leftover data.
      _byteQueue.addLast(new Uint8List.view(buf.buffer, index));
    });
  }

  @override
  Future close() async {
    while (_awaiterQueue.isNotEmpty) {
      var awaiter = _awaiterQueue.removeFirst();
      awaiter.completer.completeError(
          new StateError(
              'Stream was closed before ${awaiter.fillLength} byte(s) could be read.'),
          awaiter.stackTrace);
    }
  }
}

class _BinaryReaderAwaiter {
  final Completer<Uint8List> completer = new Completer<Uint8List>();
  final StackTrace stackTrace;
  final BytesBuilder builder = new BytesBuilder();
  final int fillLength;

  _BinaryReaderAwaiter(this.stackTrace, this.fillLength);

  int get remaining => fillLength - builder.length;
}
