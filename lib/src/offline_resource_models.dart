import 'package:path/path.dart' as p;

enum OfflineResourceKind {
  speechAsr,
  speechTts,
  speechSpeakerEmbedding,
  speechLanguageIdentification,
  ocr,
  translation,
}

enum OfflineResourceInstallPhase {
  queued,
  downloading,
  validating,
  installing,
  completed,
  failed,
  canceled,
}

enum OfflineResourceSourceType { bundled, remote, localImport, verify }

enum OfflineResourceRuntimeBindingKind {
  ocr,
  speechAsr,
  speechTts,
  speechSpeakerEmbedding,
  speechLanguageIdentification,
}

class OfflineResourceRuntimeBinding {
  const OfflineResourceRuntimeBinding({
    required this.kind,
    this.options = const <String, Object?>{},
    this.automatic = true,
  });

  final OfflineResourceRuntimeBindingKind kind;
  final Map<String, Object?> options;
  final bool automatic;

  factory OfflineResourceRuntimeBinding.fromJson(Map<String, dynamic> json) {
    final rawKind = _requiredString(json, 'kind');
    final kind = OfflineResourceRuntimeBindingKind.values.where(
      (candidate) => candidate.name == rawKind,
    );
    if (kind.isEmpty) {
      throw FormatException(
        'Unsupported offline resource runtime binding kind "$rawKind".',
      );
    }
    final rawOptions = json['options'];
    if (rawOptions != null && rawOptions is! Map) {
      throw const FormatException(
        'Offline resource runtime binding options must be an object.',
      );
    }
    final options = rawOptions is Map ? rawOptions : const {};

    return OfflineResourceRuntimeBinding(
      kind: kind.first,
      options: options.isEmpty
          ? const <String, Object?>{}
          : Map<String, Object?>.unmodifiable({
              for (final entry in options.entries)
                entry.key.toString(): entry.value,
            }),
      automatic: json['automatic'] is bool ? json['automatic'] as bool : true,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'kind': kind.name,
      if (options.isNotEmpty) 'options': options,
      'automatic': automatic,
    };
  }
}

class OfflineResourceCatalogDocument {
  static const int currentSchemaVersion = 2;

  const OfflineResourceCatalogDocument({
    required this.schemaVersion,
    required this.resources,
    this.source = 'bundled',
    this.priority = 0,
    this.signature,
    this.conflicts = const [],
  });

  final int schemaVersion;
  final List<OfflineResourceManifest> resources;
  final String source;
  final int priority;
  final OfflineResourceCatalogSignature? signature;
  final List<OfflineResourceCatalogConflict> conflicts;

  factory OfflineResourceCatalogDocument.empty() {
    return const OfflineResourceCatalogDocument(
      schemaVersion: currentSchemaVersion,
      resources: [],
    );
  }

  factory OfflineResourceCatalogDocument.fromJson(Map<String, dynamic> json) {
    final schemaVersion = (json['schemaVersion'] as num?)?.toInt();
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Offline resource catalog schemaVersion must be $currentSchemaVersion.',
      );
    }
    final currentSchemaVersionValue = schemaVersion!;
    final resourcesJson = _jsonObjectList(
      json['resources'] ?? json['packages'],
      'resources',
    );
    final resources = resourcesJson
        .map(OfflineResourceManifest.fromJson)
        .toList(growable: false);
    _ensureUniqueResourceStoragePaths(resources);

    return OfflineResourceCatalogDocument(
      schemaVersion: currentSchemaVersionValue,
      source: _optionalString(json['source']) ?? 'catalog',
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      signature: OfflineResourceCatalogSignature.tryParse(json['signature']),
      resources: resources,
      conflicts: json['conflicts'] == null
          ? const []
          : _jsonObjectList(json['conflicts'], 'conflicts')
                .map(OfflineResourceCatalogConflict.fromJson)
                .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'source': source,
      'priority': priority,
      if (signature != null) 'signature': signature!.toJson(),
      'resources': resources
          .map((resource) => resource.toJson())
          .toList(growable: false),
      if (conflicts.isNotEmpty)
        'conflicts': conflicts
            .map((conflict) => conflict.toJson())
            .toList(growable: false),
    };
  }
}

class OfflineResourceCatalogSignature {
  const OfflineResourceCatalogSignature({
    required this.algorithm,
    required this.keyId,
    required this.value,
  });

  final String algorithm;
  final String keyId;
  final String value;

  static OfflineResourceCatalogSignature? tryParse(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is Map<String, dynamic>) {
      return OfflineResourceCatalogSignature(
        algorithm: _requiredString(value, 'algorithm'),
        keyId: _requiredString(value, 'keyId'),
        value: _requiredString(value, 'value'),
      );
    }
    throw const FormatException(
      'Offline resource catalog signature is invalid.',
    );
  }

  Map<String, Object?> toJson() {
    return {'algorithm': algorithm, 'keyId': keyId, 'value': value};
  }
}

class OfflineResourceCatalogConflict {
  const OfflineResourceCatalogConflict({
    required this.resourceId,
    required this.keptSource,
    required this.skippedSource,
    required this.keptVersion,
    required this.skippedVersion,
    required this.reason,
  });

  final String resourceId;
  final String keptSource;
  final String skippedSource;
  final String keptVersion;
  final String skippedVersion;
  final String reason;

  factory OfflineResourceCatalogConflict.fromJson(Map<String, dynamic> json) {
    return OfflineResourceCatalogConflict(
      resourceId: _requiredString(json, 'resourceId'),
      keptSource: _requiredString(json, 'keptSource'),
      skippedSource: _requiredString(json, 'skippedSource'),
      keptVersion: _requiredString(json, 'keptVersion'),
      skippedVersion: _requiredString(json, 'skippedVersion'),
      reason: _requiredString(json, 'reason'),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'resourceId': resourceId,
      'keptSource': keptSource,
      'skippedSource': skippedSource,
      'keptVersion': keptVersion,
      'skippedVersion': skippedVersion,
      'reason': reason,
    };
  }
}

class OfflineResourceManifest {
  const OfflineResourceManifest({
    required this.resourceId,
    required this.kind,
    required this.title,
    required this.version,
    required this.directoryName,
    required this.languageCodes,
    required this.files,
    this.description = '',
    this.provider = '',
    this.sourceUrl,
    this.licenses = const <String>[],
    this.licenseUrl,
    this.supportedPlatforms = const <String>{},
    this.minAppVersion,
    this.entryFile,
    this.runtimeBindings = const <OfflineResourceRuntimeBinding>[],
    this.deprecatedResourceIds = const [],
    this.deprecatedDirectoryNames = const [],
  });

  final String resourceId;
  final OfflineResourceKind kind;
  final String title;
  final String version;
  final String directoryName;
  final Set<String> languageCodes;
  final List<OfflineResourceFileManifest> files;
  final String description;
  final String provider;
  final Uri? sourceUrl;
  final List<String> licenses;
  final Uri? licenseUrl;
  final Set<String> supportedPlatforms;
  final String? minAppVersion;
  final String? entryFile;
  final List<OfflineResourceRuntimeBinding> runtimeBindings;
  final List<String> deprecatedResourceIds;
  final List<String> deprecatedDirectoryNames;

  int get sizeBytes {
    return files.fold<int>(0, (sum, file) => sum + file.sizeBytes);
  }

  bool supportsOperatingSystem(String operatingSystem) {
    if (supportedPlatforms.isEmpty) {
      return true;
    }
    return supportedPlatforms.contains(operatingSystem.trim().toLowerCase());
  }

  factory OfflineResourceManifest.fromJson(Map<String, dynamic> json) {
    final resourceId =
        _optionalString(json['resourceId']) ?? _requiredString(json, 'id');
    final licenseList = json['licenses'] is List
        ? _safeStringList(json['licenses'], 'licenses')
        : (_optionalString(json['license']) == null
              ? const <String>[]
              : <String>[_optionalString(json['license'])!]);
    final languagesJson = json['languageCodes'] ?? json['languages'];
    final files = _jsonObjectList(
      json['files'],
      'files',
      allowEmpty: false,
    ).map(OfflineResourceFileManifest.fromJson).toList(growable: false);
    _ensureUniqueFilePaths(files, resourceId);

    final directoryName = _requiredSafeRelativePath(json, 'directoryName');
    if (!_isSafeRelativePath(directoryName)) {
      throw FormatException(
        'Offline resource "$resourceId" must use a safe directoryName value.',
      );
    }
    final entryFile = _optionalSafeRelativePath(json['entryFile'], 'entryFile');
    if (entryFile != null) {
      if (!_isSafeRelativePath(entryFile)) {
        throw FormatException(
          'Offline resource "$resourceId" entryFile must use a safe relative path.',
        );
      }
      if (!files.any((file) => file.path == entryFile)) {
        throw FormatException(
          'Offline resource "$resourceId" entryFile is not listed in files.',
        );
      }
    }

    return OfflineResourceManifest(
      resourceId: resourceId,
      kind: parseOfflineResourceKind(json['kind']),
      title: _optionalString(json['title']) ?? resourceId,
      version: _requiredString(json, 'version'),
      directoryName: directoryName,
      languageCodes: languagesJson is List
          ? languagesJson
                .whereType<String>()
                .map((item) => item.trim())
                .where((item) => item.isNotEmpty)
                .toSet()
          : <String>{},
      files: files,
      description: _optionalString(json['description']) ?? '',
      provider: _optionalString(json['provider']) ?? '',
      sourceUrl: _optionalDownloadUri(json['sourceUrl']),
      licenses: List<String>.unmodifiable(licenseList),
      licenseUrl: _optionalDownloadUri(json['licenseUrl']),
      supportedPlatforms: _safeStringList(
        json['supportedPlatforms'],
        'supportedPlatforms',
      ).map((item) => item.toLowerCase()).toSet(),
      minAppVersion: _optionalString(json['minAppVersion']),
      entryFile: entryFile,
      runtimeBindings: json['runtimeBindings'] == null
          ? const <OfflineResourceRuntimeBinding>[]
          : _jsonObjectList(json['runtimeBindings'], 'runtimeBindings')
                .map(OfflineResourceRuntimeBinding.fromJson)
                .toList(growable: false),
      deprecatedResourceIds: _safeStringList(
        json['deprecatedResourceIds'],
        'deprecatedResourceIds',
      ),
      deprecatedDirectoryNames: _safeStringList(
        json['deprecatedDirectoryNames'],
        'deprecatedDirectoryNames',
      ),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'resourceId': resourceId,
      'kind': kind.name,
      'title': title,
      'description': description,
      'provider': provider,
      'version': version,
      'directoryName': directoryName,
      'languageCodes': languageCodes.toList(growable: false)..sort(),
      'sizeBytes': sizeBytes,
      'files': files.map((file) => file.toJson()).toList(growable: false),
      if (sourceUrl != null) 'sourceUrl': sourceUrl.toString(),
      if (licenses.isNotEmpty) 'licenses': licenses,
      if (licenseUrl != null) 'licenseUrl': licenseUrl.toString(),
      if (supportedPlatforms.isNotEmpty)
        'supportedPlatforms': supportedPlatforms.toList(growable: false)
          ..sort(),
      if (minAppVersion != null) 'minAppVersion': minAppVersion,
      if (entryFile != null) 'entryFile': entryFile,
      if (runtimeBindings.isNotEmpty)
        'runtimeBindings': runtimeBindings
            .map((binding) => binding.toJson())
            .toList(growable: false),
      if (deprecatedResourceIds.isNotEmpty)
        'deprecatedResourceIds': deprecatedResourceIds,
      if (deprecatedDirectoryNames.isNotEmpty)
        'deprecatedDirectoryNames': deprecatedDirectoryNames,
    };
  }
}

class OfflineResourceFileManifest {
  const OfflineResourceFileManifest({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    this.url,
  });

  final String path;
  final int sizeBytes;
  final String sha256;
  final Uri? url;

  factory OfflineResourceFileManifest.fromJson(Map<String, dynamic> json) {
    final path = _requiredSafeRelativePath(json, 'path');
    final sha256 = _requiredString(json, 'sha256').toLowerCase();
    final sizeBytes = (json['sizeBytes'] as num?)?.toInt();
    if (sizeBytes == null || sizeBytes < 0) {
      throw FormatException(
        'Offline resource file "$path" must contain a valid sizeBytes value.',
      );
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw FormatException(
        'Offline resource file "$path" must contain a SHA-256 hash.',
      );
    }
    if (!_isSafeRelativePath(path)) {
      throw FormatException(
        'Offline resource file "$path" must use a safe relative path.',
      );
    }

    return OfflineResourceFileManifest(
      path: path,
      sizeBytes: sizeBytes,
      sha256: sha256,
      url: _optionalDownloadUri(json['url']),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'path': path,
      'sizeBytes': sizeBytes,
      'sha256': sha256,
      if (url != null) 'url': url.toString(),
    };
  }
}

class OfflineResourceFileStatus {
  const OfflineResourceFileStatus({
    required this.file,
    required this.path,
    required this.exists,
    required this.sizeMatches,
    required this.hashMatches,
    this.actualSizeBytes = 0,
  });

  final OfflineResourceFileManifest file;
  final String path;
  final bool exists;
  final bool sizeMatches;
  final bool hashMatches;
  final int actualSizeBytes;

  bool get isValid => exists && sizeMatches && hashMatches;
}

class OfflineResourceStatus {
  const OfflineResourceStatus({
    required this.manifest,
    required this.directoryPath,
    required this.files,
    this.installedVersion,
    this.lastUsedAt,
    this.lastVerifiedAt,
  });

  final OfflineResourceManifest manifest;
  final String directoryPath;
  final List<OfflineResourceFileStatus> files;
  final String? installedVersion;
  final DateTime? lastUsedAt;
  final DateTime? lastVerifiedAt;

  bool get isInstalled =>
      files.isNotEmpty && files.every((status) => status.isValid);

  bool get hasUpdate {
    final version = installedVersion;
    return isInstalled && version != null && version != manifest.version;
  }

  int get installedBytes {
    return files
        .where((status) => status.isValid)
        .fold<int>(0, (sum, status) => sum + status.file.sizeBytes);
  }

  int get occupiedBytes =>
      files.fold(0, (sum, file) => sum + file.actualSizeBytes);

  List<String> get missingPaths {
    return files
        .where((status) => !status.exists)
        .map((status) => status.path)
        .toList(growable: false);
  }

  List<String> get invalidPaths {
    return files
        .where((status) => status.exists && !status.isValid)
        .map((status) => status.path)
        .toList(growable: false);
  }
}

class OfflineResourceInstallJob {
  const OfflineResourceInstallJob({
    required this.jobId,
    required this.resourceId,
    required this.kind,
    required this.phase,
    required this.receivedBytes,
    required this.totalBytes,
    required this.sourceType,
    required this.startedAt,
    this.resourceVersion,
    this.sourceUri,
    this.updatedAt,
    this.downloadDirectoryPath,
    this.retryCount = 0,
    this.canResume = false,
    this.message,
    this.completedAt,
  });

  final String jobId;
  final String resourceId;
  final OfflineResourceKind kind;
  final OfflineResourceInstallPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final OfflineResourceSourceType sourceType;
  final DateTime startedAt;
  final String? resourceVersion;
  final String? sourceUri;
  final DateTime? updatedAt;
  final String? downloadDirectoryPath;
  final int retryCount;
  final bool canResume;
  final String? message;
  final DateTime? completedAt;

  double? get progress {
    if (totalBytes <= 0) {
      return null;
    }
    return receivedBytes.clamp(0, totalBytes) / totalBytes;
  }

  bool get isFinished {
    return phase == OfflineResourceInstallPhase.completed ||
        phase == OfflineResourceInstallPhase.failed ||
        phase == OfflineResourceInstallPhase.canceled;
  }

  OfflineResourceInstallJob copyWith({
    OfflineResourceInstallPhase? phase,
    int? receivedBytes,
    int? totalBytes,
    String? resourceVersion,
    String? sourceUri,
    DateTime? updatedAt,
    String? downloadDirectoryPath,
    int? retryCount,
    bool? canResume,
    String? message,
    DateTime? completedAt,
  }) {
    return OfflineResourceInstallJob(
      jobId: jobId,
      resourceId: resourceId,
      kind: kind,
      phase: phase ?? this.phase,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      sourceType: sourceType,
      startedAt: startedAt,
      resourceVersion: resourceVersion ?? this.resourceVersion,
      sourceUri: sourceUri ?? this.sourceUri,
      updatedAt: updatedAt ?? this.updatedAt,
      downloadDirectoryPath:
          downloadDirectoryPath ?? this.downloadDirectoryPath,
      retryCount: retryCount ?? this.retryCount,
      canResume: canResume ?? this.canResume,
      message: message ?? this.message,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  factory OfflineResourceInstallJob.fromJson(Map<String, dynamic> json) {
    return OfflineResourceInstallJob(
      jobId: _requiredString(json, 'jobId'),
      resourceId: _requiredString(json, 'resourceId'),
      kind: parseOfflineResourceKind(json['kind']),
      phase: parseOfflineResourceInstallPhase(json['phase']),
      receivedBytes: ((json['receivedBytes'] as num?)?.toInt() ?? 0)
          .clamp(0, 1 << 62)
          .toInt(),
      totalBytes: ((json['totalBytes'] as num?)?.toInt() ?? 0)
          .clamp(0, 1 << 62)
          .toInt(),
      sourceType: parseOfflineResourceSourceType(
        json['sourceType'] ?? 'remote',
      ),
      startedAt:
          _optionalDateTime(json['startedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      resourceVersion: _optionalString(json['resourceVersion']),
      sourceUri: _optionalString(json['sourceUri']),
      updatedAt: _optionalDateTime(json['updatedAt']),
      downloadDirectoryPath: _optionalString(json['downloadDirectoryPath']),
      retryCount: ((json['retryCount'] as num?)?.toInt() ?? 0)
          .clamp(0, 1 << 20)
          .toInt(),
      canResume: json['canResume'] == true,
      message: _optionalString(json['message']),
      completedAt: _optionalDateTime(json['completedAt']),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'jobId': jobId,
      'resourceId': resourceId,
      'kind': kind.name,
      'phase': phase.name,
      'receivedBytes': receivedBytes,
      'totalBytes': totalBytes,
      'sourceType': sourceType.name,
      'startedAt': startedAt.toIso8601String(),
      if (resourceVersion != null) 'resourceVersion': resourceVersion,
      if (sourceUri != null) 'sourceUri': sourceUri,
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      if (downloadDirectoryPath != null)
        'downloadDirectoryPath': downloadDirectoryPath,
      'retryCount': retryCount,
      'canResume': canResume,
      if (message != null) 'message': message,
      if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    };
  }
}

class OfflineResourceUsageRecord {
  const OfflineResourceUsageRecord({
    required this.resourceId,
    required this.lastUsedAt,
  });

  final String resourceId;
  final DateTime lastUsedAt;

  factory OfflineResourceUsageRecord.fromJson(Map<String, dynamic> json) {
    return OfflineResourceUsageRecord(
      resourceId: _requiredString(json, 'resourceId'),
      lastUsedAt: DateTime.parse(_requiredString(json, 'lastUsedAt')),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'resourceId': resourceId,
      'lastUsedAt': lastUsedAt.toIso8601String(),
    };
  }
}

OfflineResourceKind parseOfflineResourceKind(Object? value) {
  final normalizedValue = (value as String?)?.trim();
  switch (normalizedValue) {
    case 'speechAsr':
    case 'speech_asr':
      return OfflineResourceKind.speechAsr;
    case 'speechTts':
    case 'speech_tts':
      return OfflineResourceKind.speechTts;
    case 'speechSpeakerEmbedding':
    case 'speech_speaker_embedding':
      return OfflineResourceKind.speechSpeakerEmbedding;
    case 'speechLanguageIdentification':
    case 'speech_language_identification':
      return OfflineResourceKind.speechLanguageIdentification;
    case 'ocr':
      return OfflineResourceKind.ocr;
    case 'translation':
      return OfflineResourceKind.translation;
    default:
      throw FormatException('Unsupported offline resource kind: $value');
  }
}

OfflineResourceInstallPhase parseOfflineResourceInstallPhase(Object? value) {
  final normalizedValue = (value as String?)?.trim();
  switch (normalizedValue) {
    case 'queued':
      return OfflineResourceInstallPhase.queued;
    case 'downloading':
      return OfflineResourceInstallPhase.downloading;
    case 'validating':
      return OfflineResourceInstallPhase.validating;
    case 'installing':
      return OfflineResourceInstallPhase.installing;
    case 'completed':
      return OfflineResourceInstallPhase.completed;
    case 'failed':
      return OfflineResourceInstallPhase.failed;
    case 'canceled':
    case 'cancelled':
      return OfflineResourceInstallPhase.canceled;
    default:
      throw FormatException(
        'Unsupported offline resource install phase: $value',
      );
  }
}

OfflineResourceSourceType parseOfflineResourceSourceType(Object? value) {
  final normalizedValue = (value as String?)?.trim();
  switch (normalizedValue) {
    case 'bundled':
      return OfflineResourceSourceType.bundled;
    case 'remote':
      return OfflineResourceSourceType.remote;
    case 'localImport':
    case 'local_import':
      return OfflineResourceSourceType.localImport;
    case 'verify':
      return OfflineResourceSourceType.verify;
    default:
      throw FormatException('Unsupported offline resource source type: $value');
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException(
      'Offline resource field "$key" must be a non-empty string.',
    );
  }
  return value.trim();
}

String _requiredSafeRelativePath(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException(
      'Offline resource field "$key" must be a non-empty string.',
    );
  }
  if (!_isSafeRelativePath(value)) {
    throw FormatException(
      'Offline resource field "$key" must use a safe relative path.',
    );
  }
  return value;
}

String? _optionalSafeRelativePath(Object? value, String fieldName) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException(
      'Offline resource field "$fieldName" must be a string.',
    );
  }
  if (value.trim().isEmpty) {
    return null;
  }
  if (!_isSafeRelativePath(value)) {
    throw FormatException(
      'Offline resource field "$fieldName" must use a safe relative path.',
    );
  }
  return value;
}

String? _optionalString(Object? value) {
  if (value is! String) {
    return null;
  }
  final normalizedValue = value.trim();
  return normalizedValue.isEmpty ? null : normalizedValue;
}

Uri? _optionalDownloadUri(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme) {
    throw FormatException('Offline resource URL is invalid: $value');
  }
  if (uri.scheme != 'https' && uri.scheme != 'http' && uri.scheme != 'file') {
    throw FormatException(
      'Offline resource URL scheme is not supported: ${uri.scheme}',
    );
  }
  return uri;
}

DateTime? _optionalDateTime(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(value.trim());
}

List<String> _safeStringList(Object? value, String fieldName) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw FormatException(
      'Offline resource field "$fieldName" must be a string list.',
    );
  }
  final items = <String>[];
  for (final item in value) {
    if (item is! String) {
      throw FormatException(
        'Offline resource field "$fieldName" must contain only strings.',
      );
    }
    final normalized = item.trim();
    if (normalized.isEmpty) {
      continue;
    }
    if (!_isSafeRelativePath(item)) {
      throw FormatException(
        'Offline resource field "$fieldName" contains an unsafe path value.',
      );
    }
    items.add(item);
  }
  return items;
}

List<Map<String, dynamic>> _jsonObjectList(
  Object? value,
  String fieldName, {
  bool allowEmpty = true,
}) {
  if (value is! List) {
    throw FormatException(
      'Offline resource field "$fieldName" must be a JSON object list.',
    );
  }
  if (!allowEmpty && value.isEmpty) {
    throw FormatException(
      'Offline resource field "$fieldName" must not be empty.',
    );
  }

  final objects = <Map<String, dynamic>>[];
  for (final item in value) {
    if (item is! Map<String, dynamic>) {
      throw FormatException(
        'Offline resource field "$fieldName" must contain JSON objects only.',
      );
    }
    objects.add(item);
  }
  return objects;
}

void _ensureUniqueFilePaths(
  List<OfflineResourceFileManifest> files,
  String resourceId,
) {
  final seenPaths = <String>{};
  for (final file in files) {
    if (!seenPaths.add(file.path)) {
      throw FormatException(
        'Offline resource "$resourceId" contains duplicate file path "${file.path}".',
      );
    }
  }
}

void _ensureUniqueResourceStoragePaths(
  List<OfflineResourceManifest> resources,
) {
  final seenPaths = <String, String>{};
  for (final resource in resources) {
    final storageKey = _resourceStorageKey(resource);
    final existingResourceId = seenPaths[storageKey];
    if (existingResourceId != null) {
      throw FormatException(
        'Offline resources "$existingResourceId" and "${resource.resourceId}" use the same storage directory.',
      );
    }
    seenPaths[storageKey] = resource.resourceId;
  }
}

String _resourceStorageKey(OfflineResourceManifest resource) {
  final rootKey = switch (resource.kind) {
    OfflineResourceKind.speechAsr ||
    OfflineResourceKind.speechTts ||
    OfflineResourceKind.speechSpeakerEmbedding ||
    OfflineResourceKind.speechLanguageIdentification => 'speech',
    OfflineResourceKind.ocr => 'ocr',
    OfflineResourceKind.translation => 'translation',
  };
  return '$rootKey/${resource.directoryName}';
}

bool _isSafeRelativePath(String value) {
  final normalized = value.trim();
  final parts = normalized.split('/');
  return normalized.isNotEmpty &&
      value == normalized &&
      !p.isAbsolute(normalized) &&
      !RegExp(r'^[A-Za-z]:').hasMatch(normalized) &&
      !normalized.contains(r'\') &&
      parts.every((part) => part.isNotEmpty && part != '.' && part != '..');
}
