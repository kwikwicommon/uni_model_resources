import 'dart:async';

typedef SpeechRuntimeResourceDisposer = FutureOr<void> Function();
typedef SpeechRuntimeResourceReleaser = FutureOr<void> Function();

class SpeechRuntimeResourceRegistration {
  const SpeechRuntimeResourceRegistration({
    required this.name,
    required this.dispose,
    required this.release,
  });

  final String name;
  final SpeechRuntimeResourceDisposer dispose;
  final SpeechRuntimeResourceReleaser release;
}

class SpeechRuntimeResourceRegistry {
  SpeechRuntimeResourceRegistry._();

  SpeechRuntimeResourceRegistry.test();

  static final SpeechRuntimeResourceRegistry instance =
      SpeechRuntimeResourceRegistry._();

  final Map<Object, SpeechRuntimeResourceRegistration> _registrations =
      <Object, SpeechRuntimeResourceRegistration>{};
  Future<void>? _releaseAllFlight;
  Future<void>? _disposeAllFlight;

  Object register({
    required String name,
    required SpeechRuntimeResourceDisposer dispose,
    SpeechRuntimeResourceReleaser? release,
  }) {
    final token = Object();
    _registrations[token] = SpeechRuntimeResourceRegistration(
      name: name,
      dispose: dispose,
      release: release ?? () {},
    );
    return token;
  }

  void unregister(Object token) {
    _registrations.remove(token);
  }

  Future<void> releaseAll() {
    final existingFlight = _releaseAllFlight;
    if (existingFlight != null) {
      return existingFlight;
    }
    late final Future<void> flight;
    flight = _releaseAllInternal().whenComplete(() {
      if (identical(_releaseAllFlight, flight)) {
        _releaseAllFlight = null;
      }
    });
    _releaseAllFlight = flight;
    return flight;
  }

  Future<void> disposeAll() {
    final existingFlight = _disposeAllFlight;
    if (existingFlight != null) {
      return existingFlight;
    }
    late final Future<void> flight;
    flight = _disposeAllInternal().whenComplete(() {
      if (identical(_disposeAllFlight, flight)) {
        _disposeAllFlight = null;
      }
    });
    _disposeAllFlight = flight;
    return flight;
  }

  Future<void> _releaseAllInternal() async {
    Object? pendingError;
    StackTrace? pendingStackTrace;

    final entries =
        List<MapEntry<Object, SpeechRuntimeResourceRegistration>>.from(
          _registrations.entries,
        );
    for (final entry in entries) {
      try {
        await entry.value.release();
      } catch (error, stackTrace) {
        pendingError ??= error;
        pendingStackTrace ??= stackTrace;
      }
    }

    if (pendingError != null) {
      Error.throwWithStackTrace(pendingError, pendingStackTrace!);
    }
  }

  Future<void> _disposeAllInternal() async {
    Object? pendingError;
    StackTrace? pendingStackTrace;

    final entries =
        List<MapEntry<Object, SpeechRuntimeResourceRegistration>>.from(
          _registrations.entries,
        );
    for (final entry in entries) {
      try {
        await entry.value.dispose();
      } catch (error, stackTrace) {
        pendingError ??= error;
        pendingStackTrace ??= stackTrace;
      } finally {
        _registrations.remove(entry.key);
      }
    }

    if (pendingError != null) {
      Error.throwWithStackTrace(pendingError, pendingStackTrace!);
    }
  }

  int get registeredCount => _registrations.length;
}
