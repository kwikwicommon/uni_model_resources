import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uni_model_resources/uni_model_resources.dart';
import 'package:uni_model_resources/src/resource_cancellation.dart';

void main() {
  test(
    'OfflineResourceInstallQueue enforces concurrency without catalogs',
    () async {
      final events = <String>[];
      final firstCanFinish = Completer<void>();
      final secondStarted = Completer<void>();
      final queue = _queue(maxConcurrentInstallations: 1);

      final first = queue.enqueue<String>(
        job: _job('first'),
        onJobChanged: null,
        duplicateFailure: StateError('duplicate'),
        operation: (control) async {
          events.add('first-start');
          await firstCanFinish.future;
          events.add('first-finish');
          return 'first';
        },
      );
      final second = queue.enqueue<String>(
        job: _job('second'),
        onJobChanged: null,
        duplicateFailure: StateError('duplicate'),
        operation: (control) async {
          events.add('second-start');
          secondStarted.complete();
          return 'second';
        },
      );

      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-start']);
      firstCanFinish.complete();
      await secondStarted.future;

      expect(await Future.wait([first, second]), ['first', 'second']);
      expect(events, ['first-start', 'first-finish', 'second-start']);
    },
  );

  test(
    'OfflineResourceInstallQueue rejects duplicate active resources',
    () async {
      final queue = _queue(maxConcurrentInstallations: 1);
      final firstCanFinish = Completer<void>();

      unawaited(
        queue.enqueue<void>(
          job: _job('resource'),
          onJobChanged: null,
          duplicateFailure: StateError('duplicate'),
          operation: (control) => firstCanFinish.future,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        queue.enqueue<void>(
          job: _job('resource', jobId: 'resource-2'),
          onJobChanged: null,
          duplicateFailure: StateError('duplicate'),
          operation: (control) async {},
        ),
        throwsA(isA<StateError>()),
      );
      firstCanFinish.complete();
    },
  );

  test('OfflineResourceInstallQueue cancels queued jobs', () async {
    final canceledMessages = <String>[];
    final queue = _queue(
      maxConcurrentInstallations: 1,
      onCanceled: (job, message, onJobChanged) {
        canceledMessages.add(message);
      },
    );
    final firstCanFinish = Completer<void>();
    unawaited(
      queue.enqueue<void>(
        job: _job('first'),
        onJobChanged: null,
        duplicateFailure: StateError('duplicate'),
        operation: (control) => firstCanFinish.future,
      ),
    );
    final queued = queue.enqueue<void>(
      job: _job('queued'),
      onJobChanged: null,
      duplicateFailure: StateError('duplicate'),
      operation: (control) async {
        fail('Canceled queued job should not start.');
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(queue.cancel('queued', message: 'Canceled by test.'), isTrue);

    await expectLater(queued, throwsA(isA<StateError>()));
    expect(canceledMessages, ['Canceled by test.']);
    firstCanFinish.complete();
  });
}

OfflineResourceInstallQueue _queue({
  required int maxConcurrentInstallations,
  OfflineResourceInstallCanceledEmitter? onCanceled,
}) {
  return OfflineResourceInstallQueue(
    maxConcurrentInstallations: maxConcurrentInstallations,
    taskCancellationRegistry: ResourceCancellationRegistry(),
    emitJob: (job, onJobChanged) => onJobChanged?.call(job),
    emitCanceledJob:
        onCanceled ?? (job, message, onJobChanged) => onJobChanged?.call(job),
    canceledFailureFor: (job, message) => StateError(message),
  );
}

OfflineResourceInstallJob _job(String resourceId, {String? jobId}) {
  return OfflineResourceInstallJob(
    jobId: jobId ?? resourceId,
    resourceId: resourceId,
    kind: OfflineResourceKind.translation,
    phase: OfflineResourceInstallPhase.queued,
    receivedBytes: 0,
    totalBytes: 1,
    sourceType: OfflineResourceSourceType.remote,
    startedAt: DateTime.utc(2026, 1, 1),
  );
}
