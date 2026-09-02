// Regression test for the callback-ownership fix described in
// mediasoup/src/transport.dart's produce()/consume()/produceData()/
// consumeData() (see the "legacy shared-state callbacks" doc comment on
// Transport's producerCallback/consumerCallback/dataProducerCallback/
// dataConsumerCallback fields).
//
// FlexQueue (mediasoup/src/FlexQueue/flex_queue.dart) genuinely serializes
// task EXECUTION - confirmed by the second test below - so the bug was never
// in FlexQueue itself. It was in the CALLING code: a callback stored on a
// mutable field, read only once a queued task actually ran, could be
// reassigned by a second call before the first call's task got there,
// silently rerouting the first call's result to the second call's callback.
//
// This is a real unit test against the actual FlexQueue class (it has no
// WebRTC/native dependencies, so no stub is needed) rather than against
// Transport itself, which can't be constructed without a live
// RTCPeerConnection. It reproduces both halves: the OLD shared-field pattern
// genuinely misroutes a callback under this exact sequence, and the NEW
// per-call-captured-local pattern (what transport.dart now does) does not.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringopus_remote_producer/mediasoup/src/FlexQueue/flex_queue.dart';

void main() {
  group('FlexQueue callback ownership', () {
    test(
      'sanity check: FlexQueue serializes task EXECUTION correctly (not the bug)',
      () async {
        final queue = FlexQueue();
        final order = <String>[];
        final aStarted = Completer<void>();
        final bAllowedToFinish = Completer<void>();

        queue.addTask(
          FlexTaskAdd(
            id: 'a',
            execFun: () async {
              order.add('a-start');
              aStarted.complete();
              // Task B is enqueued (see below) while this await is pending -
              // if FlexQueue let it run concurrently, 'b-start' would appear
              // in `order` before this line resumes.
              await bAllowedToFinish.future;
              order.add('a-end');
            },
          ),
        );

        await aStarted.future;
        queue.addTask(
          FlexTaskAdd(
            id: 'b',
            execFun: () async {
              order.add('b-start');
            },
          ),
        );

        // Give any (incorrect) concurrent execution a chance to interleave
        // before letting task A finish.
        await Future<void>.delayed(Duration.zero);
        bAllowedToFinish.complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(order, ['a-start', 'a-end', 'b-start']);
      },
    );

    test(
      'OLD shared-field pattern: a second call can steal the first call\'s callback (documents the bug)',
      () async {
        final queue = FlexQueue();
        final received = <String, String>{};

        // Mirrors Transport.dataConsumerCallback before this fix: a single
        // mutable field, reassigned synchronously at call time, read only
        // when the queued task actually executes.
        void Function(String)? sharedCallback;

        void oldStyleCall(String label, {required bool holdBeforeRead}) {
          sharedCallback = (result) => received[label] = result;
          queue.addTask(
            FlexTaskAdd(
              id: label,
              execFun: () async {
                if (holdBeforeRead) {
                  // Simulates real async work between the task starting
                  // (transport.dart's actual awaits: _handler.sendDataChannel/
                  // receiveDataChannel, safeEmitAsFuture) and the point where
                  // the callback is finally invoked.
                  await Future<void>.delayed(Duration.zero);
                }
                // THE BUG: reads whatever is on the field NOW, not what was
                // on it when this call was made.
                sharedCallback?.call('result-for-$label');
              },
            ),
          );
        }

        oldStyleCall('A', holdBeforeRead: true);
        // Call B lands while A's task is mid-flight (during A's internal
        // await above) - exactly the "second consume request arrives before
        // the first's queued task finishes" scenario from live production
        // logs (a customer's second clipboard push / an agent's
        // Paste-to-Customer racing the plain input/keyboard consumers).
        oldStyleCall('B', holdBeforeRead: false);

        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // Demonstrates the failure mode this fix closes: A's callback slot
        // is NEVER populated at all - A's own result gets misrouted into B's
        // slot (immediately overwritten there by B's own correct write), so
        // A's caller (in real code: A's Completer) never learns A succeeded.
        // This is precisely the observed production symptom: signaling
        // resolves server-side, but the earlier caller's own wait hangs.
        expect(received.containsKey('A'), isFalse);
        expect(received['B'], 'result-for-B');
      },
    );

    test(
      'NEW per-call captured-local pattern: each call\'s own callback always fires with its own result',
      () async {
        final queue = FlexQueue();
        final received = <String, String>{};

        // Mirrors the fix: `callback` is a per-call parameter, captured into
        // a local (`onResult`) at call time - before the task is even
        // enqueued - and that local, not any shared field, is what the
        // closure invokes.
        void newStyleCall(
          String label,
          void Function(String) callback, {
          required bool holdBeforeRead,
        }) {
          final onResult = callback; // captured NOW, at call time
          queue.addTask(
            FlexTaskAdd(
              id: label,
              execFun: () async {
                if (holdBeforeRead) {
                  await Future<void>.delayed(Duration.zero);
                }
                onResult('result-for-$label');
              },
            ),
          );
        }

        newStyleCall(
          'A',
          (result) => received['A'] = result,
          holdBeforeRead: true,
        );
        newStyleCall(
          'B',
          (result) => received['B'] = result,
          holdBeforeRead: false,
        );

        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // The property the fix guarantees: a queued operation always invokes
        // the callback that belongs to that specific call, regardless of
        // what other calls happen in the meantime.
        expect(received['A'], 'result-for-A');
        expect(received['B'], 'result-for-B');
      },
    );
  });
}
