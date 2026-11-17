import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uni_model_resources/src/resource_failure.dart';
import 'package:uni_model_resources/src/offline_resource_models.dart';
import 'package:uni_model_resources/src/sherpa_model_registry.dart';
import 'package:uni_model_resources/src/speech_runtime_resource_registry.dart';

enum SpeechModelKind { asr, tts, speakerEmbedding, languageIdentification }

class SpeechModelManifestDocument {
  const SpeechModelManifestDocument({
    required this.schemaVersion,
    required this.models,
  });

  final int schemaVersion;
  final List<SpeechModelManifest> models;

  factory SpeechModelManifestDocument.fromJson(Map<String, dynamic> json) {
    final modelsJson = json['models'];
    if (modelsJson is! List) {
      throw const FormatException(
        'Speech model manifest must contain a models list.',
      );
    }

    return SpeechModelManifestDocument(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      models: _requiredJsonObjectList(
        modelsJson,
        'models',
      ).map(SpeechModelManifest.fromJson).toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'models': models.map((model) => model.toJson()).toList(growable: false),
    };
  }
}

class SpeechModelManifest {
  const SpeechModelManifest({
    required this.id,
    required this.kind,
    required this.languageCodes,
    required this.version,
    required this.directoryName,
    required this.files,
    this.sourceUrl,
    this.deprecatedModelIds = const [],
  });

  final String id;
  final SpeechModelKind kind;
  final Set<String> languageCodes;
  final String version;
  final String directoryName;
  final List<SpeechModelFileManifest> files;
  final Uri? sourceUrl;
  final List<String> deprecatedModelIds;

  factory SpeechModelManifest.fromJson(Map<String, dynamic> json) {
    final id = _requiredString(json, 'id');
    final kindValue = _requiredString(json, 'kind');
    final languagesJson = json['languages'];
    final filesJson = json['files'];

    if (languagesJson is! List) {
      throw FormatException('Speech model "$id" must contain languages.');
    }
    if (filesJson is! List) {
      throw FormatException('Speech model "$id" must contain files.');
    }
    final languageCodes = _requiredStringSet(languagesJson, 'languages', id);
    final files = _requiredJsonObjectList(
      filesJson,
      'files',
    ).map(SpeechModelFileManifest.fromJson).toList(growable: false);
    _ensureUniqueFilePaths(files, id);

    return SpeechModelManifest(
      id: id,
      kind: _parseSpeechModelKind(kindValue),
      languageCodes: languageCodes,
      version: _requiredString(json, 'version'),
      directoryName: _safeDirectoryName(
        _requiredString(json, 'directoryName'),
        'directoryName',
      ),
      files: files,
      sourceUrl: _optionalUri(json['sourceUrl']),
      deprecatedModelIds: _optionalDirectoryNameList(
        json['deprecatedModelIds'],
        'deprecatedModelIds',
      ),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'kind': kind.name,
      'languages': languageCodes.toList(growable: false)..sort(),
      'version': version,
      'directoryName': directoryName,
      'files': files.map((file) => file.toJson()).toList(growable: false),
      if (sourceUrl != null) 'sourceUrl': sourceUrl.toString(),
      if (deprecatedModelIds.isNotEmpty)
        'deprecatedModelIds': deprecatedModelIds,
    };
  }
}

class SpeechModelFileManifest {
  const SpeechModelFileManifest({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  final String path;
  final int sizeBytes;
  final String sha256;

  factory SpeechModelFileManifest.fromJson(Map<String, dynamic> json) {
    final path = _requiredString(json, 'path');
    final sha256 = _requiredString(json, 'sha256').toLowerCase();
    final sizeBytes = (json['sizeBytes'] as num?)?.toInt();
    if (sizeBytes == null || sizeBytes < 0) {
      throw FormatException(
        'Speech model file "$path" must contain a valid sizeBytes value.',
      );
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw FormatException(
        'Speech model file "$path" must contain a SHA-256 hash.',
      );
    }
    _safeFilePath(path);
    return SpeechModelFileManifest(
      path: path,
      sizeBytes: sizeBytes,
      sha256: sha256,
    );
  }

  Map<String, Object?> toJson() {
    return {'path': path, 'sizeBytes': sizeBytes, 'sha256': sha256};
  }
}

class SpeechModelFileStatus {
  const SpeechModelFileStatus({
    required this.file,
    required this.path,
    required this.exists,
    required this.sizeMatches,
    required this.hashMatches,
  });

  final SpeechModelFileManifest file;
  final String path;
  final bool exists;
  final bool sizeMatches;
  final bool hashMatches;

  bool get isValid => exists && sizeMatches && hashMatches;
}

class SpeechModelHandle {
  const SpeechModelHandle({
    required this.manifest,
    required this.directoryPath,
    required this.files,
  });

  final SpeechModelManifest manifest;
  final String directoryPath;
  final Map<String, String> files;
}

class SpeechManagedModelStatus {
  const SpeechManagedModelStatus({
    required this.manifest,
    required this.directoryPath,
    required this.files,
    this.handle,
  });

  final SpeechModelManifest manifest;
  final String directoryPath;
  final List<SpeechModelFileStatus> files;
  final SpeechModelHandle? handle;

  bool get isInstalled => handle != null;

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

class SpeechModelImportResult {
  const SpeechModelImportResult({
    required this.status,
    required this.copiedFiles,
  });

  final SpeechManagedModelStatus status;
  final List<String> copiedFiles;

  SpeechModelHandle get handle => status.handle!;
}

class SpeechModelResourceException implements Exception {
  const SpeechModelResourceException(this.failure);

  final ResourceFailure failure;

  @override
  String toString() => failure.message;
}

class SpeechModelManager {
  SpeechModelManager({
    SherpaModelRegistry? registry,
    Future<Directory> Function()? applicationSupportDirectoryProvider,
    SpeechRuntimeResourceRegistry? runtimeResourceRegistry,
    DateTime Function()? now,
  }) : registry =
           registry ??
           SherpaModelRegistry(
             applicationSupportDirectoryProvider:
                 applicationSupportDirectoryProvider,
           ),
       _getApplicationSupportDirectory =
           applicationSupportDirectoryProvider ??
           getApplicationSupportDirectory,
       _runtimeResourceRegistry =
           runtimeResourceRegistry ?? SpeechRuntimeResourceRegistry.instance,
       _now = now ?? DateTime.now;

  final SherpaModelRegistry registry;
  final Future<Directory> Function() _getApplicationSupportDirectory;
  final SpeechRuntimeResourceRegistry _runtimeResourceRegistry;
  final DateTime Function() _now;
  static Future<void> _fileSystemMutationTail = Future<void>.value();
  static const metadataFileName = '.transli_resource.json';

  Future<SpeechModelManifestDocument> parseManifestString(String source) async {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Speech model manifest must be a JSON object.',
      );
    }
    return SpeechModelManifestDocument.fromJson(decoded);
  }

  Future<SpeechModelManifestDocument> loadManifestFile(File file) async {
    return parseManifestString(await file.readAsString());
  }

  SpeechModelManifest speechManifestFromOfflineResource(
    OfflineResourceManifest manifest,
  ) {
    if (!_isSpeechOfflineResourceKind(manifest.kind)) {
      throw const SpeechModelResourceException(
        ResourceFailure(
          type: ResourceFailureType.capability,
          module: ResourceFailureModule.offlineResource,
          message:
              'Only speech resources can be converted to a speech manifest.',
          retryable: false,
          action: ResourceFailureAction.none,
        ),
      );
    }

    return SpeechModelManifest(
      id: manifest.resourceId,
      kind: switch (manifest.kind) {
        OfflineResourceKind.speechAsr => SpeechModelKind.asr,
        OfflineResourceKind.speechTts => SpeechModelKind.tts,
        OfflineResourceKind.speechSpeakerEmbedding =>
          SpeechModelKind.speakerEmbedding,
        OfflineResourceKind.speechLanguageIdentification =>
          SpeechModelKind.languageIdentification,
        OfflineResourceKind.ocr ||
        OfflineResourceKind
            .translation => throw const SpeechModelResourceException(
          ResourceFailure(
            type: ResourceFailureType.capability,
            module: ResourceFailureModule.offlineResource,
            message:
                'Only speech resources can be converted to a speech manifest.',
            retryable: false,
            action: ResourceFailureAction.none,
          ),
        ),
      },
      languageCodes: manifest.languageCodes,
      version: manifest.version,
      directoryName: _safeDirectoryName(
        manifest.directoryName,
        'directoryName',
      ),
      files: manifest.files
          .map((file) => SpeechModelFileManifest.fromJson(file.toJson()))
          .toList(growable: false),
      sourceUrl: manifest.sourceUrl,
      deprecatedModelIds: manifest.deprecatedDirectoryNames
          .map(
            (directoryName) =>
                _safeDirectoryName(directoryName, 'deprecatedDirectoryNames'),
          )
          .toList(growable: false),
    );
  }

  Future<SpeechManagedModelStatus> inspectResourceManifest(
    OfflineResourceManifest manifest,
  ) {
    return inspectModel(speechManifestFromOfflineResource(manifest));
  }

  Future<SpeechModelImportResult> importResourceDirectory({
    required Directory sourceDirectory,
    required OfflineResourceManifest manifest,
    bool overwrite = true,
  }) {
    return importModelDirectory(
      sourceDirectory: sourceDirectory,
      manifest: speechManifestFromOfflineResource(manifest),
      overwrite: overwrite,
    );
  }

  Future<SpeechManagedModelStatus> inspectModel(
    SpeechModelManifest manifest,
  ) async {
    _validateManifestForFileSystemUse(manifest);
    final root = await _getApplicationSupportDirectory();
    final directoryPath = p.join(
      root.path,
      'sherpa_onnx',
      manifest.directoryName,
    );
    return _inspectModelDirectory(directoryPath, manifest);
  }

  Future<SpeechModelHandle> resolveModelHandle(
    SpeechModelManifest manifest,
  ) async {
    final status = await inspectModel(manifest);
    final handle = status.handle;
    if (handle != null) {
      return handle;
    }

    throw SpeechModelResourceException(
      ResourceFailure(
        type: ResourceFailureType.resourceMissing,
        module: ResourceFailureModule.offlineResource,
        message: _modelUnavailableMessage(status),
        retryable: false,
        action: ResourceFailureAction.installResource,
      ),
    );
  }

  Future<SpeechModelImportResult> importModelDirectory({
    required Directory sourceDirectory,
    required SpeechModelManifest manifest,
    bool overwrite = true,
  }) {
    return _enqueueFileSystemMutation(
      () => _importModelDirectoryUnlocked(
        sourceDirectory: sourceDirectory,
        manifest: manifest,
        overwrite: overwrite,
      ),
    );
  }

  Future<SpeechModelImportResult> _importModelDirectoryUnlocked({
    required Directory sourceDirectory,
    required SpeechModelManifest manifest,
    bool overwrite = true,
  }) async {
    _validateManifestForFileSystemUse(manifest);
    if (!await sourceDirectory.exists()) {
      throw SpeechModelResourceException(
        ResourceFailure(
          type: ResourceFailureType.resourceMissing,
          module: ResourceFailureModule.offlineResource,
          message:
              'Speech model source directory does not exist: ${sourceDirectory.path}.',
          retryable: false,
          action: ResourceFailureAction.installResource,
        ),
      );
    }

    final sourceStatus = await _inspectModelDirectory(
      sourceDirectory.path,
      manifest,
    );
    if (!sourceStatus.files.every((status) => status.isValid)) {
      throw SpeechModelResourceException(
        ResourceFailure(
          type: ResourceFailureType.resourceMissing,
          module: ResourceFailureModule.offlineResource,
          message: _modelUnavailableMessage(sourceStatus),
          retryable: false,
          action: ResourceFailureAction.installResource,
        ),
      );
    }

    final root = await _getApplicationSupportDirectory();
    final sherpaRoot = Directory(p.join(root.path, 'sherpa_onnx'));
    final destinationDirectory = Directory(
      p.join(sherpaRoot.path, manifest.directoryName),
    );

    if (overwrite) {
      await _runtimeResourceRegistry.releaseAll();
      return _importModelDirectoryWithReplacement(
        sourceDirectory: sourceDirectory,
        destinationDirectory: destinationDirectory,
        sherpaRoot: sherpaRoot,
        manifest: manifest,
      );
    }

    await destinationDirectory.create(recursive: true);

    final copiedFiles = <String>[];
    for (final manifestFile in manifest.files) {
      final sourcePath = _manifestFilePath(sourceDirectory.path, manifestFile);
      final destinationPath = _manifestFilePath(
        destinationDirectory.path,
        manifestFile,
      );
      final destinationFile = File(destinationPath);
      if (!overwrite && await destinationFile.exists()) {
        continue;
      }
      await destinationFile.parent.create(recursive: true);
      await File(sourcePath).copy(destinationPath);
      copiedFiles.add(destinationPath);
    }

    final status = await inspectModel(manifest);
    if (status.handle == null) {
      throw SpeechModelResourceException(
        ResourceFailure(
          type: ResourceFailureType.resourceMissing,
          module: ResourceFailureModule.offlineResource,
          message: _modelUnavailableMessage(status),
          retryable: false,
          action: ResourceFailureAction.installResource,
        ),
      );
    }

    return SpeechModelImportResult(status: status, copiedFiles: copiedFiles);
  }

  Future<SpeechModelImportResult> _importModelDirectoryWithReplacement({
    required Directory sourceDirectory,
    required Directory destinationDirectory,
    required Directory sherpaRoot,
    required SpeechModelManifest manifest,
  }) async {
    await sherpaRoot.create(recursive: true);
    final stagingDirectory = Directory(
      p.join(
        sherpaRoot.path,
        '.${manifest.directoryName}.staging.${_now().microsecondsSinceEpoch}',
      ),
    );
    final copiedFiles = <String>[];

    try {
      await stagingDirectory.create(recursive: true);
      for (final manifestFile in manifest.files) {
        final sourcePath = _manifestFilePath(
          sourceDirectory.path,
          manifestFile,
        );
        final stagingPath = _manifestFilePath(
          stagingDirectory.path,
          manifestFile,
        );
        final destinationPath = _manifestFilePath(
          destinationDirectory.path,
          manifestFile,
        );
        final stagingFile = File(stagingPath);
        await stagingFile.parent.create(recursive: true);
        await File(sourcePath).copy(stagingPath);
        copiedFiles.add(destinationPath);
      }

      final stagedStatus = await _inspectModelDirectory(
        stagingDirectory.path,
        manifest,
      );
      if (stagedStatus.handle == null) {
        throw SpeechModelResourceException(
          ResourceFailure(
            type: ResourceFailureType.resourceMissing,
            module: ResourceFailureModule.offlineResource,
            message: _modelUnavailableMessage(stagedStatus),
            retryable: false,
            action: ResourceFailureAction.installResource,
          ),
        );
      }

      await _replaceDirectory(
        destinationDirectory: destinationDirectory,
        replacementDirectory: stagingDirectory,
      );
    } catch (_) {
      await _deleteDirectoryIfExists(stagingDirectory);
      rethrow;
    }

    final status = await inspectModel(manifest);
    if (status.handle == null) {
      throw SpeechModelResourceException(
        ResourceFailure(
          type: ResourceFailureType.resourceMissing,
          module: ResourceFailureModule.offlineResource,
          message: _modelUnavailableMessage(status),
          retryable: false,
          action: ResourceFailureAction.installResource,
        ),
      );
    }

    return SpeechModelImportResult(status: status, copiedFiles: copiedFiles);
  }

  Future<void> _replaceDirectory({
    required Directory destinationDirectory,
    required Directory replacementDirectory,
  }) async {
    Directory? backupDirectory;
    if (await _isRealDirectory(destinationDirectory)) {
      backupDirectory = Directory(
        '${destinationDirectory.path}.backup.${_now().microsecondsSinceEpoch}',
      );
      await destinationDirectory.rename(backupDirectory.path);
    }

    try {
      await replacementDirectory.rename(destinationDirectory.path);
    } catch (_) {
      if (backupDirectory != null &&
          !await destinationDirectory.exists() &&
          await backupDirectory.exists()) {
        await backupDirectory.rename(destinationDirectory.path);
      }
      rethrow;
    }
    if (backupDirectory != null) {
      try {
        await _deleteDirectoryIfExists(backupDirectory);
      } catch (_) {}
    }
  }

  Future<void> _deleteDirectoryIfExists(Directory directory) async {
    if (await _isRealDirectory(directory)) {
      await directory.delete(recursive: true);
    }
  }

  Future<bool> _isRealDirectory(Directory directory) async {
    try {
      return await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.directory;
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _isRealFile(File file) async {
    try {
      return await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> cleanupDeprecatedModels(SpeechModelManifest manifest) {
    return _enqueueFileSystemMutation(
      () => _cleanupDeprecatedModelsUnlocked(manifest),
    );
  }

  Future<void> _cleanupDeprecatedModelsUnlocked(
    SpeechModelManifest manifest,
  ) async {
    _validateManifestForFileSystemUse(manifest);
    if (manifest.deprecatedModelIds.isEmpty) {
      return;
    }
    final root = await _getApplicationSupportDirectory();
    final sherpaRoot = Directory(p.join(root.path, 'sherpa_onnx'));
    if (!await sherpaRoot.exists()) {
      return;
    }

    await _runtimeResourceRegistry.releaseAll();
    await for (final entity in sherpaRoot.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final directoryName = p.basename(entity.path);
      if (directoryName != manifest.directoryName &&
          manifest.deprecatedModelIds.contains(directoryName)) {
        await _deleteDirectoryIfExists(entity);
      }
    }
  }

  Future<FileStat?> _statOrNull(FileSystemEntity entity) async {
    try {
      return await entity.stat();
    } on FileSystemException {
      return null;
    }
  }

  Future<Map<String, dynamic>> _readInstalledMetadata(
    String directoryPath,
  ) async {
    final metadataFile = File(p.join(directoryPath, metadataFileName));
    if (!await metadataFile.exists()) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(await metadataFile.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  Future<void> _writeInstalledMetadata({
    required String directoryPath,
    required SpeechModelManifest manifest,
    Map<String, dynamic>? existingMetadata,
    Map<String, dynamic>? fingerprints,
  }) async {
    final metadataFile = File(p.join(directoryPath, metadataFileName));
    await metadataFile.parent.create(recursive: true);
    final existing = existingMetadata ?? await _readInstalledMetadata(directoryPath);
    final nowIso = _now().toIso8601String();
    final installedAt = (existing['installedAt'] is String)
        ? existing['installedAt'] as String
        : nowIso;

    final updated = <String, dynamic>{
      ...existing,
      'modelId': manifest.id,
      'kind': manifest.kind.name,
      'version': manifest.version,
      'directoryName': manifest.directoryName,
      'installedAt': installedAt,
      'lastVerifiedAt': nowIso,
      'fileFingerprints': fingerprints ?? existing['fileFingerprints'] ?? <String, dynamic>{},
    };
    await metadataFile.writeAsString(jsonEncode(updated));
  }

  Future<(SpeechModelFileStatus, Map<String, dynamic>?)> _inspectFile(
    SpeechModelFileManifest manifestFile,
    String filePath, [
    Map<String, dynamic>? savedFingerprint,
  ]) async {
    final file = File(filePath);
    if (!await _isRealFile(file)) {
      return (
        SpeechModelFileStatus(
          file: manifestFile,
          path: filePath,
          exists: false,
          sizeMatches: false,
          hashMatches: false,
        ),
        null,
      );
    }

    final stat = await _statOrNull(file);
    if (stat == null) {
      return (
        SpeechModelFileStatus(
          file: manifestFile,
          path: filePath,
          exists: false,
          sizeMatches: false,
          hashMatches: false,
        ),
        null,
      );
    }

    final sizeMatches = stat.size == manifestFile.sizeBytes;
    if (!sizeMatches) {
      return (
        SpeechModelFileStatus(
          file: manifestFile,
          path: filePath,
          exists: true,
          sizeMatches: false,
          hashMatches: false,
        ),
        null,
      );
    }

    final currentMtime = stat.modified.millisecondsSinceEpoch;
    final recordedMtime = savedFingerprint?['modifiedMs'] as int?;
    final recordedSha256 = savedFingerprint?['sha256'] as String?;

    if (recordedMtime != null &&
        recordedMtime == currentMtime &&
        recordedSha256 != null &&
        recordedSha256.toLowerCase() == manifestFile.sha256.toLowerCase()) {
      return (
        SpeechModelFileStatus(
          file: manifestFile,
          path: filePath,
          exists: true,
          sizeMatches: true,
          hashMatches: true,
        ),
        null,
      );
    }

    final hashMatches = await _sha256Matches(file, manifestFile.sha256);
    final newFingerprint = hashMatches
        ? <String, dynamic>{
            'sizeBytes': stat.size,
            'modifiedMs': currentMtime,
            'sha256': manifestFile.sha256,
          }
        : null;

    return (
      SpeechModelFileStatus(
        file: manifestFile,
        path: filePath,
        exists: true,
        sizeMatches: true,
        hashMatches: hashMatches,
      ),
      newFingerprint,
    );
  }

  Future<SpeechManagedModelStatus> _inspectModelDirectory(
    String directoryPath,
    SpeechModelManifest manifest,
  ) async {
    final metadata = await _readInstalledMetadata(directoryPath);
    final savedFingerprints = (metadata['fileFingerprints'] is Map)
        ? Map<String, dynamic>.from(metadata['fileFingerprints'] as Map)
        : const <String, dynamic>{};

    final fileStatuses = <SpeechModelFileStatus>[];
    final handleFiles = <String, String>{};
    final updatedFingerprints = Map<String, dynamic>.from(savedFingerprints);
    var fingerprintsChanged = false;

    for (final manifestFile in manifest.files) {
      final filePath = _manifestFilePath(directoryPath, manifestFile);
      final fingerprint = savedFingerprints[manifestFile.path]
          as Map<String, dynamic>?;
      final (status, newFingerprint) = await _inspectFile(
        manifestFile,
        filePath,
        fingerprint,
      );
      fileStatuses.add(status);
      if (status.isValid) {
        handleFiles[manifestFile.path] = filePath;
        if (newFingerprint != null) {
          updatedFingerprints[manifestFile.path] = newFingerprint;
          fingerprintsChanged = true;
        }
      }
    }

    final isInstalled = fileStatuses.every((status) => status.isValid);
    if (isInstalled &&
        (fingerprintsChanged ||
            savedFingerprints.length != manifest.files.length)) {
      await _writeInstalledMetadata(
        directoryPath: directoryPath,
        manifest: manifest,
        existingMetadata: metadata,
        fingerprints: updatedFingerprints,
      );
    }

    return SpeechManagedModelStatus(
      manifest: manifest,
      directoryPath: directoryPath,
      files: fileStatuses,
      handle: isInstalled
          ? SpeechModelHandle(
              manifest: manifest,
              directoryPath: directoryPath,
              files: handleFiles,
            )
          : null,
    );
  }

  String _manifestFilePath(
    String directoryPath,
    SpeechModelFileManifest manifestFile,
  ) {
    return p.joinAll([directoryPath, ...manifestFile.path.split('/')]);
  }

  Future<bool> _sha256Matches(File file, String expectedSha256) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expectedSha256.toLowerCase();
  }

  String _modelUnavailableMessage(SpeechManagedModelStatus status) {
    final missingPaths = status.missingPaths;
    if (missingPaths.isNotEmpty) {
      return 'Speech model "${status.manifest.id}" is missing files: ${missingPaths.join(', ')}.';
    }
    return 'Speech model "${status.manifest.id}" failed file validation: ${status.invalidPaths.join(', ')}.';
  }

  Future<T> _enqueueFileSystemMutation<T>(Future<T> Function() operation) {
    final previous = _fileSystemMutationTail;
    final completer = Completer<T>();
    _fileSystemMutationTail = previous
        .catchError((Object _) {})
        .then((_) async {
          try {
            completer.complete(await operation());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .catchError((Object _) {});
    return completer.future;
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException(
      'Speech model manifest field "$key" must be a non-empty string.',
    );
  }
  return value.trim();
}

List<Map<String, dynamic>> _requiredJsonObjectList(
  List<dynamic> values,
  String key,
) {
  if (values.isEmpty) {
    throw FormatException(
      'Speech model manifest field "$key" must not be empty.',
    );
  }
  final objects = <Map<String, dynamic>>[];
  for (final value in values) {
    if (value is! Map<String, dynamic>) {
      throw FormatException(
        'Speech model manifest field "$key" must contain JSON objects only.',
      );
    }
    objects.add(value);
  }
  return objects;
}

Set<String> _requiredStringSet(
  List<dynamic> values,
  String key,
  String modelId,
) {
  final normalizedValues = <String>{};
  for (final value in values) {
    if (value is! String) {
      throw FormatException(
        'Speech model "$modelId" field "$key" must contain strings only.',
      );
    }
    final normalizedValue = value.trim();
    if (normalizedValue.isEmpty) {
      throw FormatException(
        'Speech model "$modelId" field "$key" must not contain empty strings.',
      );
    }
    normalizedValues.add(normalizedValue);
  }
  if (normalizedValues.isEmpty) {
    throw FormatException('Speech model "$modelId" must contain languages.');
  }
  return normalizedValues;
}

SpeechModelKind _parseSpeechModelKind(String value) {
  try {
    return SpeechModelKind.values.byName(value);
  } on ArgumentError {
    throw FormatException('Unsupported speech model kind: $value');
  }
}

String _safeDirectoryName(String value, String fieldName) {
  final normalizedValue = value.trim();
  if (value != normalizedValue ||
      normalizedValue.isEmpty ||
      p.isAbsolute(normalizedValue) ||
      normalizedValue.contains(r'\') ||
      normalizedValue
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException(
      'Speech model manifest field "$fieldName" must use a safe relative directory name.',
    );
  }
  return normalizedValue;
}

String _safeFilePath(String value) {
  final normalizedValue = value.trim();
  if (value != normalizedValue ||
      normalizedValue.isEmpty ||
      p.isAbsolute(normalizedValue) ||
      normalizedValue.contains(r'\') ||
      normalizedValue
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException(
      'Speech model file "$value" must use a safe relative path.',
    );
  }
  return normalizedValue;
}

List<String> _optionalDirectoryNameList(Object? value, String fieldName) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw FormatException(
      'Speech model manifest field "$fieldName" must be a list.',
    );
  }
  return value
      .map((item) {
        if (item is! String) {
          throw FormatException(
            'Speech model manifest field "$fieldName" must contain strings only.',
          );
        }
        return _safeDirectoryName(item, fieldName);
      })
      .toList(growable: false);
}

void _ensureUniqueFilePaths(
  List<SpeechModelFileManifest> files,
  String modelId,
) {
  final seenPaths = <String>{};
  for (final file in files) {
    if (!seenPaths.add(file.path)) {
      throw FormatException(
        'Speech model "$modelId" contains duplicate file path "${file.path}".',
      );
    }
  }
}

void _validateManifestForFileSystemUse(SpeechModelManifest manifest) {
  _safeDirectoryName(manifest.directoryName, 'directoryName');
  if (manifest.languageCodes.isEmpty) {
    throw FormatException(
      'Speech model "${manifest.id}" must contain languages.',
    );
  }
  if (manifest.files.isEmpty) {
    throw FormatException('Speech model "${manifest.id}" must contain files.');
  }
  _ensureUniqueFilePaths(manifest.files, manifest.id);
  for (final file in manifest.files) {
    _validateFileManifest(file);
  }
  for (final deprecatedModelId in manifest.deprecatedModelIds) {
    _safeDirectoryName(deprecatedModelId, 'deprecatedModelIds');
  }
}

void _validateFileManifest(SpeechModelFileManifest file) {
  _safeFilePath(file.path);
  if (file.sizeBytes < 0) {
    throw FormatException(
      'Speech model file "${file.path}" must contain a valid sizeBytes value.',
    );
  }
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(file.sha256.toLowerCase())) {
    throw FormatException(
      'Speech model file "${file.path}" must contain a SHA-256 hash.',
    );
  }
}

Uri? _optionalUri(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme) {
    throw FormatException('Speech model source URL is invalid: $value');
  }
  return uri;
}

bool _isSpeechOfflineResourceKind(OfflineResourceKind kind) {
  return switch (kind) {
    OfflineResourceKind.speechAsr ||
    OfflineResourceKind.speechTts ||
    OfflineResourceKind.speechSpeakerEmbedding ||
    OfflineResourceKind.speechLanguageIdentification => true,
    OfflineResourceKind.ocr || OfflineResourceKind.translation => false,
  };
}
