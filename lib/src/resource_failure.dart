enum ResourceFailureType {
  validation,
  configuration,
  capability,
  network,
  service,
  permission,
  resourceMissing,
  userCancelled,
  internal,
}

enum ResourceFailureModule {
  settings,
  translation,
  ocr,
  dictionary,
  speech,
  desktop,
  storage,
  task,
  document,
  sync,
  offlineResource,
}

enum ResourceFailureAction {
  none,
  configure,
  retry,
  grantPermission,
  installResource,
}

class ResourceFailure implements Exception {
  const ResourceFailure({
    required this.type,
    required this.module,
    required this.message,
    required this.retryable,
    required this.action,
    this.code,
    this.cause,
  });

  final ResourceFailureType type;
  final ResourceFailureModule module;
  final String message;
  final bool retryable;
  final ResourceFailureAction action;
  final String? code;
  final Object? cause;

  factory ResourceFailure.fromJson(Map<String, dynamic> json) {
    return ResourceFailure(
      type: _readEnum(
        ResourceFailureType.values,
        json['type'],
        ResourceFailureType.internal,
      ),
      module: _readEnum(
        ResourceFailureModule.values,
        json['module'],
        ResourceFailureModule.task,
      ),
      message: json['message']?.toString() ?? 'Task failed.',
      retryable: _readBool(json['retryable']),
      action: _readEnum(
        ResourceFailureAction.values,
        json['action'],
        ResourceFailureAction.none,
      ),
      code: json['code']?.toString(),
    );
  }

  ResourceFailure copyWith({
    ResourceFailureType? type,
    ResourceFailureModule? module,
    String? message,
    bool? retryable,
    ResourceFailureAction? action,
    String? code,
    Object? cause,
  }) {
    return ResourceFailure(
      type: type ?? this.type,
      module: module ?? this.module,
      message: message ?? this.message,
      retryable: retryable ?? this.retryable,
      action: action ?? this.action,
      code: code ?? this.code,
      cause: cause ?? this.cause,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'type': type.name,
      'module': module.name,
      'message': message,
      'retryable': retryable,
      'action': action.name,
      if (code != null) 'code': code,
    };
  }

  @override
  String toString() {
    return message;
  }
}

T _readEnum<T extends Enum>(List<T> values, Object? value, T fallback) {
  final normalized = value?.toString().trim();
  if (normalized == null || normalized.isEmpty) {
    return fallback;
  }
  for (final item in values) {
    if (item.name == normalized) {
      return item;
    }
  }
  return fallback;
}

bool _readBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    return value.trim().toLowerCase() == 'true';
  }
  return false;
}
