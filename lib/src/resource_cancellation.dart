class ResourceCancellationRegistry {
  final Set<String> _registered = {};
  final Set<String> _canceled = {};
  void register(String id) {
    _registered.add(id);
    _canceled.remove(id);
  }

  void unregister(String id) {
    _registered.remove(id);
    _canceled.remove(id);
  }

  void requestCancellation(String id) {
    if (_registered.contains(id)) _canceled.add(id);
  }

  bool isCancellationRequested(String id) => _canceled.contains(id);
}
