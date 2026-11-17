import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:uni_model_resources/src/offline_resource_models.dart';
import 'resource_cancellation.dart';

typedef OfflineResourceJobCallback =
    void Function(OfflineResourceInstallJob job);
typedef OfflineResourceInstallOperation<T> =
    Future<T> Function(OfflineResourceJobControl control);
typedef OfflineResourceInstallJobEmitter =
    void Function(
      OfflineResourceInstallJob job,
      OfflineResourceJobCallback? onJobChanged,
    );
typedef OfflineResourceInstallCanceledEmitter =
    void Function(
      OfflineResourceInstallJob job,
      String message,
      OfflineResourceJobCallback? onJobChanged,
    );
typedef OfflineResourceCanceledFailureFactory =
    Object Function(OfflineResourceInstallJob job, String message);

class OfflineResourceInstallQueue {
  OfflineResourceInstallQueue({
    required int maxConcurrentInstallations,
    required ResourceCancellationRegistry taskCancellationRegistry,
    required OfflineResourceInstallJobEmitter emitJob,
    required OfflineResourceInstallCanceledEmitter emitCanceledJob,
    required OfflineResourceCanceledFailureFactory canceledFailureFor,
  }) : _maxConcurrentInstallations = maxConcurrentInstallations < 1
           ? 1
           : maxConcurrentInstallations,
       _taskCancellationRegistry = taskCancellationRegistry,
       _emitJob = emitJob,
       _emitCanceledJob = emitCanceledJob,
       _canceledFailureFor = canceledFailureFor;

  final int _maxConcurrentInstallations;
  final ResourceCancellationRegistry _taskCancellationRegistry;
  final OfflineResourceInstallJobEmitter _emitJob;
  final OfflineResourceInstallCanceledEmitter _emitCanceledJob;
  final OfflineResourceCanceledFailureFactory _canceledFailureFor;
  final Map<String, OfflineResourceJobControl> _controlsByResourceId = {};
  final Map<String, OfflineResourceJobControl> _controlsByJobId = {};
  final Queue<OfflineResourceQueueEntry<dynamic>> _queue = Queue();
  int _runningInstallations = 0;

  Iterable<OfflineResourceJobControl> get controls =>
      List.unmodifiable(_controlsByResourceId.values);

  OfflineResourceJobControl? controlFor(String resourceIdOrJobId) {
    return _controlsByResourceId[resourceIdOrJobId] ??
        _controlsByJobId[resourceIdOrJobId];
  }

  bool hasActiveResource(String resourceId) {
    final control = _controlsByResourceId[resourceId];
    return control != null && !control.isCanceled;
  }

  void updateLatestJob(OfflineResourceInstallJob job) {
    final control = _controlsByResourceId[job.resourceId];
    if (control != null) {
      control.latestJob = job;
    }
  }

  Future<T> enqueue<T>({
    required OfflineResourceInstallJob job,
    required OfflineResourceJobCallback? onJobChanged,
    required OfflineResourceInstallOperation<T> operation,
    required Object duplicateFailure,
  }) {
    final existingControl = _controlsByResourceId[job.resourceId];
    if (existingControl != null && !existingControl.isCanceled) {
      return Future<T>.error(duplicateFailure);
    }
    final control = OfflineResourceJobControl(
      latestJob: job,
      onJobChanged: onJobChanged,
      cancelToken: CancelToken(),
    );
    final entry = OfflineResourceQueueEntry<T>(
      control: control,
      operation: operation,
    );
    control.queueEntry = entry;
    _controlsByResourceId[job.resourceId] = control;
    _controlsByJobId[job.jobId] = control;
    _taskCancellationRegistry.register(job.jobId);
    _queue.add(entry);
    _emitJob(job, onJobChanged);
    _pump();
    return entry.completer.future.whenComplete(() {
      _removeControl(control);
    });
  }

  bool cancel(String resourceIdOrJobId, {required String message}) {
    final control = controlFor(resourceIdOrJobId);
    if (control == null || control.isCanceled) {
      return false;
    }

    control.cancel(message);
    _taskCancellationRegistry.requestCancellation(control.latestJob.jobId);
    final queuedEntry = control.queueEntry;
    if (queuedEntry != null && !control.hasStarted) {
      _queue.remove(queuedEntry);
      _emitCanceledJob(control.latestJob, message, control.onJobChanged);
      queuedEntry.completeError(
        _canceledFailureFor(control.latestJob, message),
      );
      _removeControl(control);
    }
    return true;
  }

  void _pump() {
    while (_runningInstallations < _maxConcurrentInstallations &&
        _queue.isNotEmpty) {
      final entry = _queue.removeFirst();
      final control = entry.control;
      control.queueEntry = null;

      if (control.isCanceled) {
        const message = 'Offline resource install was canceled.';
        _emitCanceledJob(control.latestJob, message, control.onJobChanged);
        entry.completeError(_canceledFailureFor(control.latestJob, message));
        continue;
      }

      control.hasStarted = true;
      _runningInstallations += 1;
      unawaited(
        Future<void>(() async {
          try {
            final result = await entry.run();
            entry.complete(result);
          } catch (error, stackTrace) {
            entry.completeError(error, stackTrace);
          } finally {
            _runningInstallations -= 1;
            _pump();
          }
        }),
      );
    }
  }

  void _removeControl(OfflineResourceJobControl control) {
    if (_controlsByResourceId[control.latestJob.resourceId] == control) {
      _controlsByResourceId.remove(control.latestJob.resourceId);
    }
    if (_controlsByJobId[control.latestJob.jobId] == control) {
      _controlsByJobId.remove(control.latestJob.jobId);
    }
    _taskCancellationRegistry.unregister(control.latestJob.jobId);
  }
}

class OfflineResourceJobControl {
  OfflineResourceJobControl({
    required this.latestJob,
    required this.onJobChanged,
    required this.cancelToken,
  });

  OfflineResourceInstallJob latestJob;
  final OfflineResourceJobCallback? onJobChanged;
  final CancelToken cancelToken;
  OfflineResourceQueueEntry<dynamic>? queueEntry;
  bool hasStarted = false;
  bool isCanceled = false;

  void cancel(String message) {
    isCanceled = true;
    if (!cancelToken.isCancelled) {
      cancelToken.cancel(message);
    }
  }
}

class OfflineResourceQueueEntry<T> {
  OfflineResourceQueueEntry({
    required this.control,
    required OfflineResourceInstallOperation<T> operation,
  }) : _operation = operation;

  final OfflineResourceJobControl control;
  final OfflineResourceInstallOperation<T> _operation;
  final Completer<T> completer = Completer<T>();

  Future<T> run() {
    return _operation(control);
  }

  void complete(Object? value) {
    if (!completer.isCompleted) {
      completer.complete(value as T);
    }
  }

  void completeError(Object error, [StackTrace? stackTrace]) {
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }
}

class OfflineResourceInstallCanceled implements Exception {
  const OfflineResourceInstallCanceled(this.message);

  final String message;
}
