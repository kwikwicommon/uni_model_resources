import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uni_model_resources/src/resource_failure.dart';
import 'resource_storage.dart';
import 'resource_cancellation.dart';
import 'package:uni_model_resources/src/offline_resource_adapters.dart';
import 'package:uni_model_resources/src/offline_resource_catalog.dart';
import 'package:uni_model_resources/src/offline_resource_download_mirrors.dart';
import 'package:uni_model_resources/src/offline_resource_install_jobs.dart';
import 'package:uni_model_resources/src/offline_resource_models.dart';

enum WindowsOfflineResourceInstallErrorCategory {
  permissionDenied,
  fileInUse,
  pathTooLong,
  verificationFailed,
  temporaryDirectoryUnavailable,
  unknown,
}

class OfflineResourceServiceException implements Exception {
  const OfflineResourceServiceException(this.failure);

  final ResourceFailure failure;

  @override
  String toString() => failure.message;
}

OfflineResourceServiceException _offlineResourceServiceFailure({
  required OfflineResourceKind kind,
  required String message,
  ResourceFailureType type = ResourceFailureType.service,
  ResourceFailureAction action = ResourceFailureAction.installResource,
  String? code,
  Object? cause,
}) {
  return OfflineResourceServiceException(
    ResourceFailure(
      type: type,
      module: ResourceFailureModule.offlineResource,
      message: message,
      retryable:
          type == ResourceFailureType.network ||
          type == ResourceFailureType.service,
      action: action,
      code: code,
      cause: cause,
    ),
  );
}

class ModelManager {
  ModelManager({
    ResourceStringStorage? storage,
    Dio? dio,
    SpeechResourceAdapter? speechAdapter,
    this.onInstalled,
    this.onRemoved,
    this.onJobChanged,
    this.isCancellationRequested,
    bool remoteCatalogAvailable = true,
    Future<Directory> Function()? applicationSupportDirectoryProvider,
    Future<Directory> Function()? temporaryDirectoryProvider,
    String bundledCatalogAssetPath = _defaultBundledCatalogAssetPath,
    int maxConcurrentInstallations = 1,
    OfflineResourceCatalogTrustPolicy catalogTrustPolicy =
        const OfflineResourceCatalogTrustPolicy(),
    DateTime Function()? now,
  }) : _storage = storage ?? MemoryResourceStorage(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(minutes: 5),
             ),
           ),
       _speechAdapter = speechAdapter ?? SpeechResourceAdapter(),
       _remoteCatalogAvailable = remoteCatalogAvailable,
       _applicationSupportDirectoryProvider =
           applicationSupportDirectoryProvider ??
           getApplicationSupportDirectory,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _bundledCatalogAssetPath = bundledCatalogAssetPath,
       _catalogModule = OfflineResourceCatalogModule(
         trustPolicy: catalogTrustPolicy,
         failureFactory: _offlineResourceServiceFailure,
       ),
       _now = now ?? DateTime.now {
    _installQueue = OfflineResourceInstallQueue(
      maxConcurrentInstallations: maxConcurrentInstallations,
      taskCancellationRegistry: _taskCancellationRegistry,
      emitJob: _emitJob,
      emitCanceledJob: _emitCanceledJob,
      canceledFailureFor: _canceledResourceFailure,
    );
  }
  static ModelManager instance = ModelManager();
  final Future<void> Function(OfflineResourceStatus)? onInstalled;
  final Future<void> Function(OfflineResourceManifest)? onRemoved;
  final void Function(OfflineResourceInstallJob)? onJobChanged;
  final bool Function(String)? isCancellationRequested;

  static const catalogUrlStorageKey = 'offline_resource_catalog_url';
  static const huggingFaceMirrorStorageKey =
      'offline_resource_huggingface_mirror';
  static const catalogCacheStorageKey = 'offline_resource_catalog_cache';
  static const usageStorageKey = 'offline_resource_usage_records';
  static const installJobsStorageKey = 'offline_resource_install_jobs';
  static const healthCheckStorageKey = 'offline_resource_health_check';
  static const _defaultBundledCatalogAssetPath =
      'assets/offline_resources/catalog.json';
  static const _genericResourceRootDirectoryName = 'offline_resources';
  static const _downloadRootDirectoryName = 'offline_resource_downloads';
  static const _metadataFileName = '.transli_resource.json';

  final ResourceStringStorage _storage;
  final Dio _dio;
  final SpeechResourceAdapter _speechAdapter;
  final bool _remoteCatalogAvailable;
  final Future<Directory> Function() _applicationSupportDirectoryProvider;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final String _bundledCatalogAssetPath;
  final OfflineResourceCatalogModule _catalogModule;
  final DateTime Function() _now;
  final ResourceCancellationRegistry _taskCancellationRegistry =
      ResourceCancellationRegistry();
  late final OfflineResourceInstallQueue _installQueue;
  final Map<String, OfflineResourceInstallJob> _activeJobs = {};
  bool _didRestoreInterruptedInstallJobs = false;
  Future<void> _installJobWriteChain = Future<void>.value();

  List<OfflineResourceInstallJob> get activeJobs {
    _restoreInterruptedInstallJobs();
    return List.unmodifiable(_activeJobs.values);
  }

  List<OfflineResourceInstallJob> get installJobs {
    _restoreInterruptedInstallJobs();
    return List.unmodifiable(_readPersistedInstallJobs());
  }

  Future<bool> cancelResourceInstall(String resourceIdOrJobId) async {
    const message = 'Offline resource install was canceled.';
    return _installQueue.cancel(resourceIdOrJobId, message: message);
  }

  Future<int> cleanupStaleInstallArtifacts({
    Duration maxAge = const Duration(days: 1),
  }) async {
    final tempRoot = await _temporaryDirectoryProvider();
    final downloadRoot = Directory(
      p.join(tempRoot.path, _downloadRootDirectoryName),
    );
    if (!await downloadRoot.exists()) {
      return 0;
    }

    final cutoff = _now().subtract(maxAge);
    final protectedPaths = _protectedDownloadDirectoryPaths(
      staleCutoff: cutoff,
    );
    final referenceTimes = _downloadDirectoryReferenceTimes();
    var removedCount = 0;
    await for (final entity in downloadRoot.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final normalizedPath = p.normalize(entity.path);
      if (protectedPaths.contains(normalizedPath)) {
        continue;
      }
      final referenceTime =
          referenceTimes[normalizedPath] ?? (await entity.stat()).modified;
      if (referenceTime.isAfter(cutoff)) {
        continue;
      }
      await entity.delete(recursive: true);
      removedCount += 1;
    }
    return removedCount;
  }

  String? readCatalogUrl() {
    final value = _storage.read(catalogUrlStorageKey)?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  Future<void> writeCatalogUrl(String? value) async {
    if (!_remoteCatalogAvailable && value?.trim().isNotEmpty == true) {
      throw StateError('Remote offline catalogs are disabled in this build.');
    }
    final normalizedValue = value?.trim() ?? '';
    await _storage.write(catalogUrlStorageKey, normalizedValue);
  }

  String? readHuggingFaceMirrorHost() {
    return _downloadMirrors().effectiveMirrorHost;
  }

  bool get usesHuggingFaceMirror => readHuggingFaceMirrorHost() != null;

  Future<void> writeHuggingFaceMirrorHost(String? value) async {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty ||
        trimmed.toLowerCase() ==
            OfflineResourceDownloadMirrors.disabledSentinel) {
      await _storage.write(
        huggingFaceMirrorStorageKey,
        OfflineResourceDownloadMirrors.disabledSentinel,
      );
      return;
    }
    final host = OfflineResourceDownloadMirrors.normalizeHost(trimmed);
    if (host == null) {
      throw _resourceFailure(
        kind: OfflineResourceKind.translation,
        message: 'Hugging Face mirror host is invalid.',
        type: ResourceFailureType.validation,
        action: ResourceFailureAction.configure,
        code: 'offline_resource_invalidMirrorHost',
      );
    }
    await _storage.write(huggingFaceMirrorStorageKey, host);
  }

  OfflineResourceDownloadMirrors _downloadMirrors() {
    return OfflineResourceDownloadMirrors(
      configuredHost: _storage.read(huggingFaceMirrorStorageKey),
    );
  }

  OfflineResourceCatalogDocument? readCachedCatalog() {
    final raw = _storage.read(catalogCacheStorageKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    try {
      return parseCatalogString(raw, catalogSource: 'cache', priority: 50);
    } catch (_) {
      return null;
    }
  }

  OfflineResourceCatalogDocument parseCatalogString(
    String source, {
    String catalogSource = 'catalog',
    int priority = 0,
  }) {
    return _catalogModule.parseCatalogString(
      source,
      catalogSource: catalogSource,
      priority: priority,
    );
  }

  Future<OfflineResourceCatalogDocument> loadCatalog({
    String? catalogUrl,
    bool forceRemote = false,
  }) async {
    _restoreInterruptedInstallJobs();
    unawaited(cleanupStaleInstallArtifacts());
    final bundledCatalog = await _loadBundledCatalog();
    final resolvedCatalogUrl = _remoteCatalogAvailable
        ? (catalogUrl ?? readCatalogUrl())?.trim() ?? ''
        : '';

    OfflineResourceCatalogDocument? externalCatalog;
    if (resolvedCatalogUrl.isNotEmpty) {
      try {
        final catalogSourceUri = _resolveCatalogSourceUri(resolvedCatalogUrl);
        _catalogModule.validateSourceAllowed(catalogSourceUri);
        final rawCatalog = await _loadCatalogSource(resolvedCatalogUrl);
        if (rawCatalog.trim().isEmpty) {
          throw const FormatException('Offline resource catalog is empty.');
        }
        await _catalogModule.verifyCatalogSignature(
          rawCatalog,
          catalogSourceUri,
        );
        externalCatalog = parseCatalogString(
          rawCatalog,
          catalogSource: catalogSourceUri.toString(),
          priority: 100,
        );
        await _storage.write(
          catalogCacheStorageKey,
          jsonEncode(externalCatalog.toJson()),
        );
        if (catalogUrl != null) {
          await writeCatalogUrl(catalogUrl);
        }
      } catch (error) {
        if (forceRemote) {
          throw _resourceFailure(
            kind: OfflineResourceKind.translation,
            message: 'Failed to load offline resource catalog: $error',
            type: ResourceFailureType.service,
            cause: error,
          );
        }
        externalCatalog = readCachedCatalog();
      }
    } else {
      externalCatalog = readCachedCatalog();
    }

    return _catalogModule.mergeCatalogs([bundledCatalog, ?externalCatalog]);
  }

  Future<OfflineResourceCatalogDocument> loadLocalCatalog() async {
    _restoreInterruptedInstallJobs();
    final bundledCatalog = await _loadBundledCatalog();
    final cachedCatalog = _remoteCatalogAvailable ? readCachedCatalog() : null;
    return _catalogModule.mergeCatalogs([bundledCatalog, ?cachedCatalog]);
  }

  Future<List<OfflineResourceStatus>> inspectLocalResourcesByKind(
    OfflineResourceKind kind,
  ) async {
    final catalog = await loadLocalCatalog();
    final manifests = catalog.resources
        .where((manifest) => manifest.kind == kind)
        .toList(growable: false);
    final statuses = await inspectResources(manifests);
    return statuses
        .where((status) => status.isInstalled)
        .toList(growable: false);
  }

  Future<List<OfflineResourceStatus>> inspectResources(
    List<OfflineResourceManifest> manifests,
  ) async {
    return Future.wait(manifests.map(inspectResource));
  }

  Future<OfflineResourceStatus> inspectResource(
    OfflineResourceManifest manifest,
  ) async {
    _validateManifestForPublicUse(manifest);
    final status = switch (manifest.kind) {
      OfflineResourceKind.speechAsr ||
      OfflineResourceKind.speechTts ||
      OfflineResourceKind.speechSpeakerEmbedding ||
      OfflineResourceKind.speechLanguageIdentification =>
        await _speechAdapter.inspectResource(manifest),
      OfflineResourceKind.ocr || OfflineResourceKind.translation =>
        await _inspectGenericResource(manifest),
    };
    final metadata = await _readInstalledMetadata(status.directoryPath);
    final verifiedAt = _now();
    final hasFingerprints = metadata['fileFingerprints'] is Map &&
        (metadata['fileFingerprints'] as Map).isNotEmpty;
    if (status.isInstalled && !hasFingerprints) {
      await _recordLastVerifiedAt(status.directoryPath, manifest, verifiedAt);
    }
    final usageRecords = _readUsageRecords();

    return OfflineResourceStatus(
      manifest: manifest,
      directoryPath: status.directoryPath,
      files: status.files,
      installedVersion: metadata['version'] is String
          ? (metadata['version'] as String).trim()
          : status.isInstalled
          ? manifest.version
          : null,
      lastUsedAt: usageRecords[manifest.resourceId]?.lastUsedAt,
      lastVerifiedAt: status.isInstalled
          ? verifiedAt
          : _readMetadataDateTime(metadata),
    );
  }

  Future<OfflineResourceStatus> verifyResource(
    OfflineResourceManifest manifest,
  ) async {
    _validateManifestForPublicUse(manifest);
    _restoreInterruptedInstallJobs();
    final jobId =
        '${manifest.resourceId}_verify_${_now().millisecondsSinceEpoch}';
    final initialJob = OfflineResourceInstallJob(
      jobId: jobId,
      resourceId: manifest.resourceId,
      kind: manifest.kind,
      phase: OfflineResourceInstallPhase.queued,
      receivedBytes: 0,
      totalBytes: manifest.sizeBytes,
      sourceType: OfflineResourceSourceType.verify,
      startedAt: _now(),
      resourceVersion: manifest.version,
    );

    return _enqueueInstallJob<OfflineResourceStatus>(
      job: initialJob,
      onJobChanged: null,
      operation: (control) async {
        var job = control.latestJob;
        try {
          _throwIfInstallCanceled(control);
          job = job.copyWith(
            phase: OfflineResourceInstallPhase.validating,
            receivedBytes: 0,
            totalBytes: manifest.sizeBytes,
          );
          _emitJob(job, null);
          final status = await inspectResource(manifest);
          if (status.isInstalled) {
            await onInstalled?.call(status);
            job = job.copyWith(
              phase: OfflineResourceInstallPhase.completed,
              receivedBytes: manifest.sizeBytes,
              totalBytes: manifest.sizeBytes,
              completedAt: _now(),
            );
            _emitJob(job, null, removeWhenFinished: true);
          } else {
            await onRemoved?.call(manifest);
            _emitFailedJob(job, _unavailableMessage(status), null);
          }
          return status;
        } on OfflineResourceInstallCanceled catch (error) {
          final failure = _canceledResourceFailure(job, error.message);
          _emitCanceledJob(job, failure.failure.message, null);
          throw failure;
        } catch (error) {
          if (error is OfflineResourceServiceException) {
            _emitFailedJob(job, error.failure.message, null);
            rethrow;
          }
          final failure = _resourceFailureForInstallError(
            kind: manifest.kind,
            resourceId: manifest.resourceId,
            actionName: 'verify',
            error: error,
          );
          _emitFailedJob(job, failure.failure.message, null);
          throw failure;
        }
      },
    );
  }

  Future<OfflineResourceStatus> installResource(
    OfflineResourceManifest manifest, {
    OfflineResourceJobCallback? onJobChanged,
    String? taskId,
  }) async {
    _validateManifestForPublicUse(manifest);
    _ensurePlatformSupported(manifest);
    _restoreInterruptedInstallJobs();
    final resumableJob = _findResumableInstallJob(manifest);
    final jobId =
        taskId ??
        resumableJob?.jobId ??
        '${manifest.resourceId}_${_now().millisecondsSinceEpoch}';
    final initialJob = OfflineResourceInstallJob(
      jobId: jobId,
      resourceId: manifest.resourceId,
      kind: manifest.kind,
      phase: OfflineResourceInstallPhase.queued,
      receivedBytes: resumableJob?.receivedBytes ?? 0,
      totalBytes: manifest.sizeBytes,
      sourceType: OfflineResourceSourceType.remote,
      startedAt: _now(),
      resourceVersion: manifest.version,
      sourceUri: _sourceUriForJob(manifest),
      downloadDirectoryPath: resumableJob?.downloadDirectoryPath,
      retryCount:
          (resumableJob?.retryCount ?? 0) + (resumableJob == null ? 0 : 1),
      canResume: resumableJob != null,
    );

    return _enqueueInstallJob<OfflineResourceStatus>(
      job: initialJob,
      onJobChanged: onJobChanged,
      operation: (control) async {
        var job = control.latestJob;
        final tempRoot = await _resolveTemporaryDirectory(manifest.kind);
        final downloadDirectory = _resolveDownloadDirectory(
          tempRoot: tempRoot,
          jobId: jobId,
          persistedPath: job.downloadDirectoryPath,
        );
        var removeDownloadDirectory = false;
        await _ensureDirectoryAvailable(
          directory: downloadDirectory,
          kind: manifest.kind,
          category: WindowsOfflineResourceInstallErrorCategory
              .temporaryDirectoryUnavailable,
        );
        job = job.copyWith(
          downloadDirectoryPath: downloadDirectory.path,
          canResume: true,
        );
        _emitJob(job, onJobChanged);

        try {
          _throwIfInstallCanceled(control);
          final totalBytes = manifest.sizeBytes;
          var completedBytes = 0;
          var lastProgressEmittedBytes = 0;
          var lastProgressEmittedAt = DateTime.fromMillisecondsSinceEpoch(0);

          for (final file in manifest.files) {
            _throwIfInstallCanceled(control);
            final destinationPath = p.joinAll([
              downloadDirectory.path,
              ...file.path.split('/'),
            ]);
            final destinationFile = File(destinationPath);
            await destinationFile.parent.create(recursive: true);
            final fileUri = _resolveFileDownloadUri(manifest, file);
            final existingStatus = await _inspectFile(file, destinationPath);
            if (existingStatus.isValid) {
              completedBytes += file.sizeBytes;
              job = job.copyWith(
                phase: OfflineResourceInstallPhase.downloading,
                receivedBytes: completedBytes,
                totalBytes: totalBytes,
              );
              _emitJob(job, onJobChanged);
              continue;
            }

            job = job.copyWith(
              phase: OfflineResourceInstallPhase.downloading,
              receivedBytes: completedBytes,
              totalBytes: totalBytes,
            );
            lastProgressEmittedBytes = completedBytes;
            lastProgressEmittedAt = job.updatedAt ?? lastProgressEmittedAt;
            _emitJob(job, onJobChanged);

            await _downloadFile(
              fileUri,
              destinationFile,
              kind: manifest.kind,
              cancelToken: control.cancelToken,
              expectedSizeBytes: file.sizeBytes,
              onProgress: (receivedBytes) {
                final absoluteReceivedBytes =
                    completedBytes +
                    receivedBytes.clamp(0, file.sizeBytes).toInt();
                final now = _now();
                if (!_shouldEmitDownloadProgress(
                  nextBytes: absoluteReceivedBytes,
                  previousBytes: lastProgressEmittedBytes,
                  now: now,
                  previousAt: lastProgressEmittedAt,
                  totalBytes: totalBytes,
                  isComplete: absoluteReceivedBytes >= totalBytes,
                )) {
                  return;
                }
                lastProgressEmittedBytes = absoluteReceivedBytes;
                lastProgressEmittedAt = now;
                job = job.copyWith(
                  phase: OfflineResourceInstallPhase.downloading,
                  receivedBytes: absoluteReceivedBytes,
                  totalBytes: totalBytes,
                  updatedAt: now,
                );
                _emitJob(job, onJobChanged);
              },
            );
            completedBytes += file.sizeBytes;
          }

          _throwIfInstallCanceled(control);
          job = job.copyWith(
            phase: OfflineResourceInstallPhase.validating,
            receivedBytes: totalBytes,
            totalBytes: totalBytes,
          );
          _emitJob(job, onJobChanged);
          await _validateResourceDirectory(downloadDirectory.path, manifest);

          _throwIfInstallCanceled(control);
          job = job.copyWith(
            phase: OfflineResourceInstallPhase.installing,
            receivedBytes: totalBytes,
            totalBytes: totalBytes,
          );
          _emitJob(job, onJobChanged);
          await _installFromValidatedDirectory(downloadDirectory, manifest);

          final status = await inspectResource(manifest);
          await onInstalled?.call(status);
          job = job.copyWith(
            phase: OfflineResourceInstallPhase.completed,
            receivedBytes: totalBytes,
            totalBytes: totalBytes,
            completedAt: _now(),
            canResume: false,
          );
          removeDownloadDirectory = true;
          _emitJob(job, onJobChanged, removeWhenFinished: true);
          return status;
        } on OfflineResourceInstallCanceled catch (error) {
          final latestJob = control.latestJob;
          final failure = _canceledResourceFailure(latestJob, error.message);
          _emitCanceledJob(latestJob, failure.failure.message, onJobChanged);
          throw failure;
        } on DioException catch (error) {
          if (error.type == DioExceptionType.cancel) {
            final latestJob = control.latestJob;
            final failure = _canceledResourceFailure(
              latestJob,
              'Offline resource install was canceled.',
            );
            _emitCanceledJob(latestJob, failure.failure.message, onJobChanged);
            throw failure;
          }
          final failure = _resourceFailure(
            kind: manifest.kind,
            message:
                'Failed to download offline resource "${manifest.resourceId}": ${error.message}',
            type: ResourceFailureType.network,
            cause: error,
          );
          _emitFailedJob(
            control.latestJob,
            failure.failure.message,
            onJobChanged,
            canResume: true,
          );
          throw failure;
        } catch (error) {
          if (error is OfflineResourceServiceException) {
            _emitFailedJob(
              control.latestJob,
              error.failure.message,
              onJobChanged,
              canResume: error.failure.type == ResourceFailureType.network,
            );
            rethrow;
          }
          final failure = _resourceFailureForInstallError(
            kind: manifest.kind,
            resourceId: manifest.resourceId,
            actionName: 'install',
            error: error,
          );
          _emitFailedJob(
            control.latestJob,
            failure.failure.message,
            onJobChanged,
          );
          throw failure;
        } finally {
          if (removeDownloadDirectory && await downloadDirectory.exists()) {
            await downloadDirectory.delete(recursive: true);
          }
        }
      },
    );
  }

  Future<Directory> _resolveTemporaryDirectory(OfflineResourceKind kind) async {
    try {
      final directory = await _temporaryDirectoryProvider();
      await _ensureDirectoryAvailable(
        directory: directory,
        kind: kind,
        category: WindowsOfflineResourceInstallErrorCategory
            .temporaryDirectoryUnavailable,
      );
      return directory;
    } catch (error) {
      if (error is OfflineResourceServiceException) {
        rethrow;
      }
      final category = _classifyWindowsInstallError(error);
      throw _resourceFailureForCategory(
        kind: kind,
        category: category == WindowsOfflineResourceInstallErrorCategory.unknown
            ? WindowsOfflineResourceInstallErrorCategory
                  .temporaryDirectoryUnavailable
            : category,
        message: 'Offline resource temporary directory is unavailable: $error',
        cause: error,
      );
    }
  }

  Future<void> _ensureDirectoryAvailable({
    required Directory directory,
    required OfflineResourceKind kind,
    required WindowsOfflineResourceInstallErrorCategory category,
  }) async {
    try {
      await directory.create(recursive: true);
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Path is not a real directory.',
          directory.path,
        );
      }
    } catch (error) {
      throw _resourceFailureForCategory(
        kind: kind,
        category: category == WindowsOfflineResourceInstallErrorCategory.unknown
            ? _classifyWindowsInstallError(error)
            : category,
        message:
            'Offline resource directory is unavailable: ${directory.path}. $error',
        cause: error,
      );
    }
  }

  Directory _resolveDownloadDirectory({
    required Directory tempRoot,
    required String jobId,
    required String? persistedPath,
  }) {
    final downloadRootPath = p.normalize(
      p.join(tempRoot.path, _downloadRootDirectoryName),
    );
    final persisted = persistedPath?.trim();
    if (persisted != null && persisted.isNotEmpty) {
      final normalizedPersistedPath = p.normalize(p.absolute(persisted));
      if (normalizedPersistedPath != downloadRootPath &&
          p.isWithin(downloadRootPath, normalizedPersistedPath)) {
        return Directory(normalizedPersistedPath);
      }
    }
    return Directory(p.join(downloadRootPath, jobId));
  }

  bool _shouldEmitDownloadProgress({
    required int nextBytes,
    required int previousBytes,
    required DateTime now,
    required DateTime previousAt,
    required int totalBytes,
    required bool isComplete,
  }) {
    if (nextBytes <= previousBytes) {
      return false;
    }
    if (isComplete) {
      return true;
    }
    final elapsed = now.difference(previousAt);
    return nextBytes - previousBytes >= _downloadProgressByteStep(totalBytes) ||
        elapsed >= const Duration(milliseconds: 250);
  }

  int _downloadProgressByteStep(int totalBytes) {
    if (totalBytes <= 0) {
      return 64 * 1024;
    }
    return (totalBytes / 100).ceil().clamp(64 * 1024, 2 * 1024 * 1024).toInt();
  }

  OfflineResourceServiceException _resourceFailureForInstallError({
    required OfflineResourceKind kind,
    required String resourceId,
    required String actionName,
    required Object error,
  }) {
    final category = _classifyWindowsInstallError(error);
    return _resourceFailureForCategory(
      kind: kind,
      category: category,
      message: _windowsInstallErrorMessage(
        resourceId: resourceId,
        actionName: actionName,
        category: category,
        error: error,
      ),
      cause: error,
    );
  }

  OfflineResourceServiceException _resourceFailureForCategory({
    required OfflineResourceKind kind,
    required WindowsOfflineResourceInstallErrorCategory category,
    required String message,
    Object? cause,
  }) {
    return _resourceFailure(
      kind: kind,
      message: message,
      type: _failureTypeForWindowsInstallCategory(category),
      action:
          category ==
              WindowsOfflineResourceInstallErrorCategory.permissionDenied
          ? ResourceFailureAction.grantPermission
          : ResourceFailureAction.installResource,
      code: 'offline_resource_${category.name}',
      cause: cause,
    );
  }

  WindowsOfflineResourceInstallErrorCategory _classifyWindowsInstallError(
    Object error,
  ) {
    if (error is OfflineResourceServiceException) {
      final code = error.failure.code;
      if (code == 'offline_resource_verificationFailed' ||
          code == 'offline_resource_missingFiles' ||
          code == 'offline_resource_unsupportedPlatform' ||
          code == 'offline_resource_bindingFailed') {
        return WindowsOfflineResourceInstallErrorCategory.verificationFailed;
      }
      if (code == 'offline_resource_temporaryDirectoryUnavailable') {
        return WindowsOfflineResourceInstallErrorCategory
            .temporaryDirectoryUnavailable;
      }
    }
    if (error is FileSystemException) {
      final osCode = error.osError?.errorCode;
      final message = '${error.message} ${error.osError?.message ?? ''}'
          .toLowerCase();
      if (osCode == 5 ||
          osCode == 13 ||
          message.contains('access is denied') ||
          message.contains('permission')) {
        return WindowsOfflineResourceInstallErrorCategory.permissionDenied;
      }
      if (osCode == 32 ||
          osCode == 33 ||
          message.contains('being used by another process')) {
        return WindowsOfflineResourceInstallErrorCategory.fileInUse;
      }
      if (osCode == 206 ||
          message.contains('filename or extension is too long') ||
          message.contains('path too long')) {
        return WindowsOfflineResourceInstallErrorCategory.pathTooLong;
      }
      if (message.contains('temporary') || message.contains('temp')) {
        return WindowsOfflineResourceInstallErrorCategory
            .temporaryDirectoryUnavailable;
      }
    }
    if (error is PathAccessException) {
      return WindowsOfflineResourceInstallErrorCategory.permissionDenied;
    }
    if (error is FileSystemException &&
        error.path != null &&
        error.path!.length >= 240) {
      return WindowsOfflineResourceInstallErrorCategory.pathTooLong;
    }
    return WindowsOfflineResourceInstallErrorCategory.unknown;
  }

  ResourceFailureType _failureTypeForWindowsInstallCategory(
    WindowsOfflineResourceInstallErrorCategory category,
  ) {
    return switch (category) {
      WindowsOfflineResourceInstallErrorCategory.permissionDenied =>
        ResourceFailureType.permission,
      WindowsOfflineResourceInstallErrorCategory.verificationFailed =>
        ResourceFailureType.resourceMissing,
      WindowsOfflineResourceInstallErrorCategory.pathTooLong ||
      WindowsOfflineResourceInstallErrorCategory
          .temporaryDirectoryUnavailable => ResourceFailureType.configuration,
      WindowsOfflineResourceInstallErrorCategory.fileInUse ||
      WindowsOfflineResourceInstallErrorCategory.unknown =>
        ResourceFailureType.service,
    };
  }

  String _windowsInstallErrorMessage({
    required String resourceId,
    required String actionName,
    required WindowsOfflineResourceInstallErrorCategory category,
    required Object error,
  }) {
    final suffix = error.toString();
    return switch (category) {
      WindowsOfflineResourceInstallErrorCategory.permissionDenied =>
        'Failed to $actionName offline resource "$resourceId": permission denied. $suffix',
      WindowsOfflineResourceInstallErrorCategory.fileInUse =>
        'Failed to $actionName offline resource "$resourceId": a file is in use by another process. $suffix',
      WindowsOfflineResourceInstallErrorCategory.pathTooLong =>
        'Failed to $actionName offline resource "$resourceId": path is too long. $suffix',
      WindowsOfflineResourceInstallErrorCategory.verificationFailed =>
        'Failed to $actionName offline resource "$resourceId": file verification failed. $suffix',
      WindowsOfflineResourceInstallErrorCategory
          .temporaryDirectoryUnavailable =>
        'Failed to $actionName offline resource "$resourceId": temporary directory is unavailable. $suffix',
      WindowsOfflineResourceInstallErrorCategory.unknown =>
        'Failed to $actionName offline resource "$resourceId": $suffix',
    };
  }

  Future<OfflineResourceStatus> importResourceDirectory({
    required Directory sourceDirectory,
    required OfflineResourceManifest manifest,
    OfflineResourceJobCallback? onJobChanged,
  }) async {
    _validateManifestForPublicUse(manifest);
    _ensurePlatformSupported(manifest);
    _restoreInterruptedInstallJobs();
    if (!await sourceDirectory.exists()) {
      throw _resourceFailure(
        kind: manifest.kind,
        message:
            'Offline resource source directory does not exist: ${sourceDirectory.path}.',
        type: ResourceFailureType.resourceMissing,
        code: 'offline_resource_sourceMissing',
      );
    }

    final jobId =
        '${manifest.resourceId}_import_${_now().millisecondsSinceEpoch}';
    final initialJob = OfflineResourceInstallJob(
      jobId: jobId,
      resourceId: manifest.resourceId,
      kind: manifest.kind,
      phase: OfflineResourceInstallPhase.queued,
      receivedBytes: 0,
      totalBytes: manifest.sizeBytes,
      sourceType: OfflineResourceSourceType.localImport,
      startedAt: _now(),
      resourceVersion: manifest.version,
      sourceUri: sourceDirectory.uri.toString(),
      downloadDirectoryPath: sourceDirectory.path,
    );

    return _enqueueInstallJob<OfflineResourceStatus>(
      job: initialJob,
      onJobChanged: onJobChanged,
      operation: (control) async {
        var job = control.latestJob;
        try {
          _throwIfInstallCanceled(control);
          job = job.copyWith(
            phase: OfflineResourceInstallPhase.validating,
            receivedBytes: 0,
            totalBytes: manifest.sizeBytes,
          );
          _emitJob(job, onJobChanged);
          await _validateResourceDirectory(sourceDirectory.path, manifest);

          _throwIfInstallCanceled(control);
          job = job.copyWith(
            phase: OfflineResourceInstallPhase.installing,
            receivedBytes: manifest.sizeBytes,
            totalBytes: manifest.sizeBytes,
          );
          _emitJob(job, onJobChanged);
          await _installFromValidatedDirectory(sourceDirectory, manifest);

          final status = await inspectResource(manifest);
          await onInstalled?.call(status);
          job = job.copyWith(
            phase: OfflineResourceInstallPhase.completed,
            receivedBytes: manifest.sizeBytes,
            totalBytes: manifest.sizeBytes,
            completedAt: _now(),
          );
          _emitJob(job, onJobChanged, removeWhenFinished: true);
          return status;
        } on OfflineResourceInstallCanceled catch (error) {
          final failure = _canceledResourceFailure(job, error.message);
          _emitCanceledJob(job, failure.failure.message, onJobChanged);
          throw failure;
        } catch (error) {
          if (error is OfflineResourceServiceException) {
            _emitFailedJob(job, error.failure.message, onJobChanged);
            rethrow;
          }
          final failure = _resourceFailureForInstallError(
            kind: manifest.kind,
            resourceId: manifest.resourceId,
            actionName: 'import',
            error: error,
          );
          _emitFailedJob(job, failure.failure.message, onJobChanged);
          throw failure;
        }
      },
    );
  }

  Future<void> removeResource(OfflineResourceManifest manifest) async {
    _validateManifestForPublicUse(manifest);
    if (_installQueue.hasActiveResource(manifest.resourceId)) {
      throw _resourceFailure(
        kind: manifest.kind,
        message:
            'Offline resource "${manifest.resourceId}" cannot be removed while an install is active.',
        type: ResourceFailureType.service,
        code: 'offline_resource_installActive',
      );
    }
    await onRemoved?.call(manifest);
    final directory = Directory(await resolveResourceDirectoryPath(manifest));
    if (await _isRealDirectory(directory)) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> recordResourceUsed(String resourceId, {DateTime? usedAt}) async {
    final normalizedResourceId = resourceId.trim();
    if (normalizedResourceId.isEmpty) {
      return;
    }
    final records = _readUsageRecords();
    records[normalizedResourceId] = OfflineResourceUsageRecord(
      resourceId: normalizedResourceId,
      lastUsedAt: usedAt ?? _now(),
    );
    final encoded = jsonEncode(
      records.map((key, value) => MapEntry(key, value.toJson())),
    );
    await _storage.write(usageStorageKey, encoded);
  }

  Map<String, OfflineResourceUsageRecord> readResourceUsageRecords() {
    return Map.unmodifiable(_readUsageRecords());
  }

  Future<Map<String, Object?>> exportWindowsDiagnosticJson() async {
    final catalog = await loadLocalCatalog();
    final statuses = await inspectResources(catalog.resources);
    final healthCheck = readLastHealthCheck();
    return {
      'catalogResourceCount': catalog.resources.length,
      'activeJobs': activeJobs
          .map((job) => job.toJson())
          .toList(growable: false),
      'persistedJobs': installJobs
          .map((job) => job.toJson())
          .toList(growable: false),
      'lastHealthCheck': healthCheck,
      'resources': [
        for (final status in statuses)
          {
            'resourceId': status.manifest.resourceId,
            'kind': status.manifest.kind.name,
            'directoryPath': status.directoryPath,
            'isInstalled': status.isInstalled,
            'installedBytes': status.installedBytes,
            'lastVerifiedAtMs': status.lastVerifiedAt
                ?.toUtc()
                .millisecondsSinceEpoch,
            'missingPaths': status.missingPaths,
            'invalidPaths': status.invalidPaths,
            'directoryAccess': await _probeDirectoryAccess(
              status.directoryPath,
            ),
          },
      ],
    };
  }

  Map<String, Object?> readLastHealthCheck() {
    final raw = _storage.read(healthCheckStorageKey);
    if (raw == null || raw.trim().isEmpty) {
      return <String, Object?>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return <String, Object?>{};
    }
    return <String, Object?>{};
  }

  Future<Map<String, Object?>> checkInstalledResourceHealthOnStartup() async {
    final catalog = await loadLocalCatalog();
    final statuses = await inspectResources(catalog.resources);
    final issues = <Map<String, Object?>>[];
    for (final status in statuses) {
      final access = await _probeDirectoryAccess(status.directoryPath);
      if (!status.isInstalled && access['exists'] != true) {
        continue;
      }
      if (!status.isInstalled &&
          status.missingPaths.isEmpty &&
          status.invalidPaths.isEmpty) {
        continue;
      }
      if (status.isInstalled && access['writable'] == true) {
        continue;
      }
      issues.add({
        'resourceId': status.manifest.resourceId,
        'kind': status.manifest.kind.name,
        'directoryPath': status.directoryPath,
        'missingPaths': status.missingPaths,
        'invalidPaths': status.invalidPaths,
        'directoryAccess': access,
        'repairSuggestion': _repairSuggestionFor(status, access),
      });
    }
    final result = {
      'checkedAtMs': _now().toUtc().millisecondsSinceEpoch,
      'resourceCount': statuses.length,
      'issueCount': issues.length,
      'issues': issues,
    };
    await _storage.write(healthCheckStorageKey, jsonEncode(result));
    return result;
  }

  Future<String> resolveResourceDirectoryPath(
    OfflineResourceManifest manifest,
  ) async {
    _validateManifestForPublicUse(manifest);
    if (_isSpeech(manifest.kind)) {
      final supportDirectory = await _applicationSupportDirectoryProvider();
      return p.join(
        supportDirectory.path,
        'sherpa_onnx',
        manifest.directoryName,
      );
    }

    final root = await _genericResourceRootDirectory(manifest.kind);
    return p.join(root.path, manifest.directoryName);
  }

  Future<Map<String, Object?>> _probeDirectoryAccess(
    String directoryPath,
  ) async {
    final directory = Directory(directoryPath);
    final exists = await directory.exists();
    var writable = false;
    String? error;
    if (exists) {
      final probeFile = File(p.join(directory.path, '.transli_access_probe'));
      try {
        await probeFile.writeAsString('probe', flush: true);
        await probeFile.delete();
        writable = true;
      } catch (probeError) {
        error = probeError.toString();
        try {
          if (await probeFile.exists()) {
            await probeFile.delete();
          }
        } catch (_) {}
      }
    }
    return {'exists': exists, 'writable': writable, 'error': ?error};
  }

  String _repairSuggestionFor(
    OfflineResourceStatus status,
    Map<String, Object?> access,
  ) {
    if (access['exists'] != true) {
      return 'Reinstall the resource because its directory is missing.';
    }
    if (access['writable'] != true) {
      return 'Close applications that may lock the directory, then grant write permission or choose a writable profile directory.';
    }
    if (status.invalidPaths.isNotEmpty) {
      return 'Verify the catalog source and reinstall the resource to replace corrupted files.';
    }
    if (status.missingPaths.isNotEmpty) {
      return 'Resume or reinstall the resource to restore missing files.';
    }
    return 'Run resource verification again after closing sync or antivirus tools that may be scanning this directory.';
  }

  Future<void> _installFromValidatedDirectory(
    Directory sourceDirectory,
    OfflineResourceManifest manifest,
  ) async {
    _validateManifestForFileSystemUse(manifest);
    if (_isSpeech(manifest.kind)) {
      await _speechAdapter.installFromDirectory(
        sourceDirectory: sourceDirectory,
        manifest: manifest,
      );
      await _cleanupDeprecatedSpeechResources(manifest);
    } else {
      switch (manifest.kind) {
        case OfflineResourceKind.ocr:
          await _copyGenericResource(
            sourceDirectory: sourceDirectory,
            manifest: manifest,
          );
          break;
        case OfflineResourceKind.translation:
          await _copyGenericResource(
            sourceDirectory: sourceDirectory,
            manifest: manifest,
          );
          break;
        case OfflineResourceKind.speechAsr:
        case OfflineResourceKind.speechTts:
        case OfflineResourceKind.speechSpeakerEmbedding:
        case OfflineResourceKind.speechLanguageIdentification:
          break;
      }
      await _cleanupDeprecatedGenericResources(manifest);
    }

    final directoryPath = await resolveResourceDirectoryPath(manifest);
    await _writeInstalledMetadata(directoryPath, manifest);
  }

  Future<void> _cleanupDeprecatedSpeechResources(
    OfflineResourceManifest manifest,
  ) async {
    final deprecatedResourceIds = manifest.deprecatedResourceIds.toSet();
    if (deprecatedResourceIds.isEmpty) {
      return;
    }
    final supportDirectory = await _applicationSupportDirectoryProvider();
    final sherpaRoot = Directory(p.join(supportDirectory.path, 'sherpa_onnx'));
    if (!await sherpaRoot.exists()) {
      return;
    }
    final currentPath = p.normalize(
      await resolveResourceDirectoryPath(manifest),
    );
    await for (final entity in sherpaRoot.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final directoryPath = p.normalize(entity.path);
      if (directoryPath == currentPath) {
        continue;
      }
      final metadata = await _readInstalledMetadata(entity.path);
      final resourceId = _resourceIdFromInstalledMetadata(metadata);
      if (resourceId == null || !deprecatedResourceIds.contains(resourceId)) {
        continue;
      }
      await entity.delete(recursive: true);
    }
  }

  Future<OfflineResourceStatus> _inspectGenericResource(
    OfflineResourceManifest manifest,
  ) async {
    _validateManifestForFileSystemUse(manifest);
    final directoryPath = await resolveResourceDirectoryPath(manifest);
    final metadata = await _readInstalledMetadata(directoryPath);
    final savedFingerprints = (metadata['fileFingerprints'] is Map)
        ? Map<String, dynamic>.from(metadata['fileFingerprints'] as Map)
        : null;
    return OfflineResourceStatus(
      manifest: manifest,
      directoryPath: directoryPath,
      files: await _inspectManifestFiles(
        directoryPath,
        manifest.files,
        savedFingerprints,
      ),
    );
  }

  Future<void> _validateResourceDirectory(
    String directoryPath,
    OfflineResourceManifest manifest,
  ) async {
    _validateManifestForFileSystemUse(manifest);
    final status = await _inspectResourceDirectory(directoryPath, manifest);
    if (!status.isInstalled) {
      throw _resourceFailure(
        kind: manifest.kind,
        message: _unavailableMessage(status),
        type: ResourceFailureType.resourceMissing,
        code: _unavailableCode(status),
      );
    }
  }

  Future<OfflineResourceStatus> _inspectResourceDirectory(
    String directoryPath,
    OfflineResourceManifest manifest,
  ) async {
    _validateManifestForFileSystemUse(manifest);
    return OfflineResourceStatus(
      manifest: manifest,
      directoryPath: directoryPath,
      files: await _inspectManifestFiles(directoryPath, manifest.files),
    );
  }

  Future<List<OfflineResourceFileStatus>> _inspectManifestFiles(
    String directoryPath,
    List<OfflineResourceFileManifest> files, [
    Map<String, dynamic>? savedFingerprints,
  ]) async {
    if (files.isEmpty) {
      return const <OfflineResourceFileStatus>[];
    }
    const maxConcurrent = 4;
    final statuses = List<OfflineResourceFileStatus?>.filled(
      files.length,
      null,
    );
    var nextIndex = 0;

    Future<void> inspectNext() async {
      while (true) {
        final index = nextIndex;
        nextIndex += 1;
        if (index >= files.length) {
          return;
        }
        final manifestFile = files[index];
        final filePath = p.joinAll([
          directoryPath,
          ...manifestFile.path.split('/'),
        ]);
        final fingerprint = savedFingerprints?[manifestFile.path]
            as Map<String, dynamic>?;
        statuses[index] = await _inspectFile(
          manifestFile,
          filePath,
          fingerprint,
        );
      }
    }

    final workerCount = files.length < maxConcurrent
        ? files.length
        : maxConcurrent;
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => inspectNext()),
    );
    return [for (final status in statuses) status!];
  }

  Future<void> _copyGenericResource({
    required Directory sourceDirectory,
    required OfflineResourceManifest manifest,
  }) async {
    final destinationDirectory = Directory(
      await resolveResourceDirectoryPath(manifest),
    );
    final sourcePath = p.normalize(p.absolute(sourceDirectory.path));
    final destinationPath = p.normalize(p.absolute(destinationDirectory.path));
    if (sourcePath == destinationPath ||
        p.isWithin(sourcePath, destinationPath) ||
        p.isWithin(destinationPath, sourcePath)) {
      throw _resourceFailure(
        kind: manifest.kind,
        message:
            'Offline resource source and destination directories must be separate paths.',
        type: ResourceFailureType.validation,
        action: ResourceFailureAction.configure,
        code: 'offline_resource_overlappingPaths',
      );
    }
    final parentDirectory = destinationDirectory.parent;
    await parentDirectory.create(recursive: true);
    final suffix = _now().microsecondsSinceEpoch;
    final stagingDirectory = Directory(
      p.join(parentDirectory.path, '${manifest.directoryName}.staging.$suffix'),
    );
    final backupDirectory = Directory(
      p.join(parentDirectory.path, '${manifest.directoryName}.backup.$suffix'),
    );
    var movedExistingDirectory = false;

    try {
      await stagingDirectory.create(recursive: true);
      for (final manifestFile in manifest.files) {
        final sourcePath = p.joinAll([
          sourceDirectory.path,
          ...manifestFile.path.split('/'),
        ]);
        final destinationPath = p.joinAll([
          stagingDirectory.path,
          ...manifestFile.path.split('/'),
        ]);
        final destinationFile = File(destinationPath);
        await destinationFile.parent.create(recursive: true);
        await File(sourcePath).copy(destinationPath);
      }

      await _validateResourceDirectory(stagingDirectory.path, manifest);
      if (await _isRealDirectory(destinationDirectory)) {
        await destinationDirectory.rename(backupDirectory.path);
        movedExistingDirectory = true;
      }
      await stagingDirectory.rename(destinationDirectory.path);
      if (movedExistingDirectory) {
        await _deleteDirectoryQuietly(backupDirectory);
      }
    } catch (_) {
      await _deleteDirectoryQuietly(stagingDirectory);
      if (movedExistingDirectory &&
          !await destinationDirectory.exists() &&
          await backupDirectory.exists()) {
        await backupDirectory.rename(destinationDirectory.path);
      }
      rethrow;
    }
  }

  Future<void> _cleanupDeprecatedGenericResources(
    OfflineResourceManifest manifest,
  ) async {
    final root = await _genericResourceRootDirectory(manifest.kind);
    final deprecatedDirectoryNames = manifest.deprecatedDirectoryNames
        .where(_isSafeRelativePath)
        .toSet();
    final deprecatedResourceIds = manifest.deprecatedResourceIds
        .where(_isSafeRelativePath)
        .toSet();
    final directCandidates = {
      ...deprecatedDirectoryNames,
      ...deprecatedResourceIds,
    };
    final currentPath = p.normalize(
      await resolveResourceDirectoryPath(manifest),
    );
    final deletedPaths = <String>{};

    for (final directoryName in directCandidates) {
      final directoryPath = _safeChildPath(root.path, directoryName);
      if (directoryPath == null) {
        continue;
      }
      final resourceId = deprecatedResourceIds.contains(directoryName)
          ? directoryName
          : null;
      await _deleteDeprecatedGenericResourceDirectory(
        directory: Directory(directoryPath),
        root: root,
        currentPath: currentPath,
        deletedPaths: deletedPaths,
        resourceId: resourceId,
      );
    }

    if (deprecatedResourceIds.isEmpty) {
      return;
    }

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final metadata = await _readInstalledMetadata(entity.path);
      final resourceId = _resourceIdFromInstalledMetadata(metadata);
      if (resourceId == null || !deprecatedResourceIds.contains(resourceId)) {
        continue;
      }
      await _deleteDeprecatedGenericResourceDirectory(
        directory: entity,
        root: root,
        currentPath: currentPath,
        deletedPaths: deletedPaths,
        resourceId: resourceId,
      );
    }
  }

  Future<void> _deleteDeprecatedGenericResourceDirectory({
    required Directory directory,
    required Directory root,
    required String currentPath,
    required Set<String> deletedPaths,
    required String? resourceId,
  }) async {
    final directoryPath = p.normalize(directory.path);
    final rootPath = p.normalize(root.path);
    if (directoryPath == currentPath ||
        directoryPath == rootPath ||
        !p.isWithin(rootPath, directoryPath) ||
        !deletedPaths.add(directoryPath)) {
      return;
    }
    final candidateResourceId =
        resourceId ??
        _resourceIdFromInstalledMetadata(
          await _readInstalledMetadata(directory.path),
        );
    if (candidateResourceId != null &&
        _hasActiveInstallForResourceId(candidateResourceId)) {
      return;
    }
    if (await _isRealDirectory(directory)) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _deleteDirectoryQuietly(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
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

  Future<OfflineResourceFileStatus> _inspectFile(
    OfflineResourceFileManifest manifestFile,
    String filePath, [
    Map<String, dynamic>? savedFingerprint,
  ]) async {
    final file = File(filePath);
    if (!await _isRealFile(file)) {
      return OfflineResourceFileStatus(
        file: manifestFile,
        path: filePath,
        exists: false,
        sizeMatches: false,
        hashMatches: false,
      );
    }
    final stat = await _statOrNull(file);
    if (stat == null) {
      return OfflineResourceFileStatus(
        file: manifestFile,
        path: filePath,
        exists: false,
        sizeMatches: false,
        hashMatches: false,
      );
    }

    final sizeMatches = stat.size == manifestFile.sizeBytes;
    if (!sizeMatches) {
      return OfflineResourceFileStatus(
        file: manifestFile,
        path: filePath,
        exists: true,
        sizeMatches: false,
        hashMatches: false,
        actualSizeBytes: stat.size,
      );
    }

    final currentMtime = stat.modified.millisecondsSinceEpoch;
    final recordedMtime = savedFingerprint?['modifiedMs'] as int?;
    final recordedSha256 = savedFingerprint?['sha256'] as String?;

    if (recordedMtime != null &&
        recordedMtime == currentMtime &&
        recordedSha256 != null &&
        recordedSha256.toLowerCase() == manifestFile.sha256.toLowerCase()) {
      return OfflineResourceFileStatus(
        file: manifestFile,
        path: filePath,
        exists: true,
        sizeMatches: true,
        hashMatches: true,
        actualSizeBytes: stat.size,
      );
    }

    final hashMatches = await _sha256Matches(file, manifestFile.sha256);
    return OfflineResourceFileStatus(
      file: manifestFile,
      path: filePath,
      exists: true,
      sizeMatches: true,
      hashMatches: hashMatches,
      actualSizeBytes: stat.size,
    );
  }

  Future<void> _downloadFile(
    Uri uri,
    File destinationFile, {
    required OfflineResourceKind kind,
    required CancelToken cancelToken,
    required int expectedSizeBytes,
    required void Function(int receivedBytes) onProgress,
  }) async {
    if (cancelToken.isCancelled) {
      throw const OfflineResourceInstallCanceled(
        'Offline resource install was canceled.',
      );
    }
    if (uri.scheme == 'file') {
      await _copyLocalDownloadFile(
        uri: uri,
        destinationFile: destinationFile,
        kind: kind,
        cancelToken: cancelToken,
        expectedSizeBytes: expectedSizeBytes,
        onProgress: onProgress,
      );
      return;
    }

    final candidates = _downloadMirrors().downloadUris(uri);
    Object? lastError;
    var allowResume = true;
    for (final candidate in candidates) {
      try {
        await _downloadHttpsFile(
          catalogUri: uri,
          requestUri: candidate,
          destinationFile: destinationFile,
          kind: kind,
          cancelToken: cancelToken,
          expectedSizeBytes: expectedSizeBytes,
          onProgress: onProgress,
          allowResume: allowResume,
        );
        return;
      } on OfflineResourceInstallCanceled {
        rethrow;
      } on DioException catch (error) {
        if (error.type == DioExceptionType.cancel) {
          rethrow;
        }
        lastError = error;
      } catch (error) {
        lastError = error;
      }
      allowResume = false;
      final transientFailure =
          lastError is DioException ||
          (lastError is OfflineResourceServiceException &&
              lastError.failure.type == ResourceFailureType.network);
      if ((candidate != candidates.last || !transientFailure) &&
          await destinationFile.exists()) {
        await destinationFile.delete();
      }
    }

    if (lastError is OfflineResourceServiceException) {
      throw lastError;
    }
    throw _resourceFailure(
      kind: kind,
      message:
          'Failed to download offline resource: ${lastError ?? 'unknown error'}',
      type: ResourceFailureType.network,
      cause: lastError,
    );
  }

  Future<void> _copyLocalDownloadFile({
    required Uri uri,
    required File destinationFile,
    required OfflineResourceKind kind,
    required CancelToken cancelToken,
    required int expectedSizeBytes,
    required void Function(int receivedBytes) onProgress,
  }) async {
    final sourceFile = File.fromUri(uri);
    if (!await _isRealFile(sourceFile)) {
      throw _resourceFailure(
        kind: kind,
        message:
            'Offline resource download source is not a readable file: ${sourceFile.path}.',
        type: ResourceFailureType.resourceMissing,
        code: 'offline_resource_sourceMissing',
      );
    }
    final sourceLength = await sourceFile.length();
    if (sourceLength != expectedSizeBytes) {
      throw _resourceFailure(
        kind: kind,
        message:
            'Offline resource download source size mismatch: expected $expectedSizeBytes bytes, got $sourceLength bytes.',
        type: ResourceFailureType.resourceMissing,
        code: 'offline_resource_verificationFailed',
      );
    }
    final sink = destinationFile.openWrite(mode: FileMode.write);
    var receivedBytes = 0;
    try {
      await for (final chunk in sourceFile.openRead()) {
        if (cancelToken.isCancelled) {
          throw const OfflineResourceInstallCanceled(
            'Offline resource install was canceled.',
          );
        }
        if (receivedBytes + chunk.length > expectedSizeBytes) {
          throw _resourceFailure(
            kind: kind,
            message: 'Offline resource download exceeds the manifest size.',
            type: ResourceFailureType.validation,
            code: 'offline_resource_sizeLimitExceeded',
          );
        }
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress(receivedBytes);
      }
    } finally {
      await sink.close();
    }
    if (receivedBytes != expectedSizeBytes) {
      throw _resourceFailure(
        kind: kind,
        message:
            'Offline resource file copy ended early: expected $expectedSizeBytes bytes, got $receivedBytes bytes.',
        type: ResourceFailureType.network,
        code: 'offline_resource_downloadIncomplete',
      );
    }
  }

  Future<void> _downloadHttpsFile({
    required Uri catalogUri,
    required Uri requestUri,
    required File destinationFile,
    required OfflineResourceKind kind,
    required CancelToken cancelToken,
    required int expectedSizeBytes,
    required void Function(int receivedBytes) onProgress,
    required bool allowResume,
  }) async {
    var resumeFromBytes = allowResume && await destinationFile.exists()
        ? await destinationFile.length()
        : 0;
    if (resumeFromBytes >= expectedSizeBytes) {
      await destinationFile.delete();
      resumeFromBytes = 0;
    }

    final headers = <String, Object?>{};
    if (resumeFromBytes > 0) {
      headers[HttpHeaders.rangeHeader] = 'bytes=$resumeFromBytes-';
    }
    final response = await _dio.get<ResponseBody>(
      requestUri.toString(),
      cancelToken: cancelToken,
      options: Options(responseType: ResponseType.stream, headers: headers),
    );
    // Dio exposes the last Location header without resolving relative URLs.
    // Resolve each hop against its predecessor before checking the final host.
    var finalUri = response.requestOptions.uri;
    for (final redirect in response.redirects) {
      finalUri = finalUri.resolveUri(redirect.location);
    }
    if (!_isTrustedDownloadRedirect(catalogUri, finalUri) &&
        !_isTrustedDownloadRedirect(requestUri, finalUri)) {
      throw _resourceFailure(
        kind: kind,
        message: 'Offline resource download redirected to an untrusted host.',
        type: ResourceFailureType.configuration,
        code: 'offline_resource_untrustedRedirect',
      );
    }
    var fileMode = FileMode.write;
    if (resumeFromBytes > 0 &&
        response.statusCode == HttpStatus.partialContent) {
      fileMode = FileMode.append;
    } else {
      resumeFromBytes = 0;
    }

    final contentLength = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    if (contentLength != null &&
        contentLength + resumeFromBytes > expectedSizeBytes) {
      throw _resourceFailure(
        kind: kind,
        message: 'Offline resource download exceeds the signed manifest size.',
        type: ResourceFailureType.validation,
        code: 'offline_resource_sizeLimitExceeded',
      );
    }
    final body = response.data;
    if (body == null) {
      throw _resourceFailure(
        kind: kind,
        message: 'Offline resource download returned an empty response body.',
        type: ResourceFailureType.service,
      );
    }

    final sink = destinationFile.openWrite(mode: fileMode);
    var receivedBytes = resumeFromBytes;
    try {
      await for (final chunk in body.stream) {
        if (cancelToken.isCancelled) {
          throw const OfflineResourceInstallCanceled(
            'Offline resource install was canceled.',
          );
        }
        if (receivedBytes + chunk.length > expectedSizeBytes) {
          throw _resourceFailure(
            kind: kind,
            message: 'Offline resource download exceeds the manifest size.',
            type: ResourceFailureType.validation,
            code: 'offline_resource_sizeLimitExceeded',
          );
        }
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress(receivedBytes);
      }
    } finally {
      await sink.close();
    }
    if (receivedBytes != expectedSizeBytes) {
      throw _resourceFailure(
        kind: kind,
        message:
            'Offline resource download is incomplete: expected $expectedSizeBytes bytes, got $receivedBytes bytes.',
        type: ResourceFailureType.network,
        code: 'offline_resource_downloadIncomplete',
      );
    }
  }

  Uri _resolveFileDownloadUri(
    OfflineResourceManifest manifest,
    OfflineResourceFileManifest file,
  ) {
    final fileUrl = file.url;
    if (fileUrl != null) {
      return fileUrl;
    }

    final sourceUrl = manifest.sourceUrl;
    if (sourceUrl == null) {
      throw _resourceFailure(
        kind: manifest.kind,
        message:
            'Offline resource "${manifest.resourceId}" does not define a download URL.',
        type: ResourceFailureType.configuration,
        action: ResourceFailureAction.configure,
      );
    }

    if (manifest.files.length == 1) {
      return sourceUrl;
    }

    final sourceText = sourceUrl.toString();
    final baseUrl = sourceText.endsWith('/')
        ? sourceUrl
        : Uri.parse('$sourceText/');
    return baseUrl.resolve(file.path);
  }

  bool _isTrustedDownloadRedirect(Uri sourceUri, Uri finalUri) {
    return _downloadMirrors().isTrustedRedirect(sourceUri, finalUri);
  }

  Uri _resolveCatalogSourceUri(String rawValue) {
    final normalizedValue = rawValue.trim();
    final uri = Uri.tryParse(normalizedValue);
    if (uri != null && uri.hasScheme) {
      return uri;
    }
    return File(normalizedValue).absolute.uri;
  }

  Future<String> _loadCatalogSource(String rawValue) async {
    final normalizedValue = rawValue.trim();
    final uri = Uri.tryParse(normalizedValue);

    if (uri != null && uri.hasScheme) {
      if (uri.scheme == 'file') {
        return File.fromUri(uri).readAsString();
      }
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        final response = await _dio.get<String>(
          normalizedValue,
          options: Options(responseType: ResponseType.plain),
        );
        return response.data ?? '';
      }
    }

    return File(normalizedValue).readAsString();
  }

  Future<OfflineResourceCatalogDocument> _loadBundledCatalog() async {
    try {
      final raw = await rootBundle.loadString(_bundledCatalogAssetPath);
      if (raw.trim().isEmpty) {
        return OfflineResourceCatalogDocument.empty();
      }
      return parseCatalogString(raw, catalogSource: 'bundled', priority: 0);
    } on FlutterError catch (error) {
      if (!_isMissingBundledCatalogError(error)) {
        rethrow;
      }
      return OfflineResourceCatalogDocument.empty();
    }
  }

  bool _isMissingBundledCatalogError(FlutterError error) {
    final message = error.toString();
    return message.contains('Unable to load asset') &&
        message.contains(_bundledCatalogAssetPath);
  }

  Future<Directory> _genericResourceRootDirectory(
    OfflineResourceKind kind,
  ) async {
    final supportDirectory = await _applicationSupportDirectoryProvider();
    final root = Directory(
      p.join(
        supportDirectory.path,
        _genericResourceRootDirectoryName,
        kind.name,
      ),
    );
    await root.create(recursive: true);
    return root;
  }

  Future<bool> _sha256Matches(File file, String expectedSha256) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expectedSha256;
  }

  Future<FileStat?> _statOrNull(FileSystemEntity entity) async {
    try {
      return await entity.stat();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeInstalledMetadata(
    String directoryPath,
    OfflineResourceManifest manifest,
  ) async {
    final metadataFile = File(p.join(directoryPath, _metadataFileName));
    await metadataFile.parent.create(recursive: true);
    final existing = await _readInstalledMetadata(directoryPath);
    final installedAt =
        _readMetadataDateTime(
          existing,
          'installedAt',
        ) ??
        _now();

    final fingerprints = <String, dynamic>{
      if (existing['fileFingerprints'] is Map)
        ...Map<String, dynamic>.from(existing['fileFingerprints'] as Map),
    };
    for (final file in manifest.files) {
      final filePath = p.joinAll([directoryPath, ...file.path.split('/')]);
      final stat = await _statOrNull(File(filePath));
      if (stat != null && stat.size == file.sizeBytes) {
        fingerprints[file.path] = {
          'sizeBytes': stat.size,
          'modifiedMs': stat.modified.millisecondsSinceEpoch,
          'sha256': file.sha256,
        };
      }
    }

    await metadataFile.writeAsString(
      jsonEncode({
        ...existing,
        'resourceId': manifest.resourceId,
        'kind': manifest.kind.name,
        'version': manifest.version,
        'installedAt': installedAt.toIso8601String(),
        'lastVerifiedAt': _now().toIso8601String(),
        'manifest': manifest.toJson(),
        'fileFingerprints': fingerprints,
      }),
    );
  }

  Future<Map<String, dynamic>> _readInstalledMetadata(
    String directoryPath,
  ) async {
    final metadataFile = File(p.join(directoryPath, _metadataFileName));
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

  Future<void> _recordLastVerifiedAt(
    String directoryPath,
    OfflineResourceManifest manifest,
    DateTime verifiedAt,
  ) async {
    final metadata = Map<String, dynamic>.from(
      await _readInstalledMetadata(directoryPath),
    );
    final metadataFile = File(p.join(directoryPath, _metadataFileName));
    await metadataFile.parent.create(recursive: true);
    metadata['resourceId'] = manifest.resourceId;
    metadata['kind'] = manifest.kind.name;
    metadata['version'] = manifest.version;
    metadata['installedAt'] ??= verifiedAt.toIso8601String();
    metadata['lastVerifiedAt'] = verifiedAt.toIso8601String();
    metadata['manifest'] = manifest.toJson();

    final fingerprints = <String, dynamic>{
      if (metadata['fileFingerprints'] is Map)
        ...Map<String, dynamic>.from(metadata['fileFingerprints'] as Map),
    };
    for (final file in manifest.files) {
      final filePath = p.joinAll([directoryPath, ...file.path.split('/')]);
      final stat = await _statOrNull(File(filePath));
      if (stat != null && stat.size == file.sizeBytes) {
        fingerprints[file.path] = {
          'sizeBytes': stat.size,
          'modifiedMs': stat.modified.millisecondsSinceEpoch,
          'sha256': file.sha256,
        };
      }
    }
    metadata['fileFingerprints'] = fingerprints;

    await metadataFile.writeAsString(jsonEncode(metadata));
  }

  DateTime? _readMetadataDateTime(
    Map<String, dynamic> metadata, [
    String key = 'lastVerifiedAt',
  ]) {
    final value = metadata[key];
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(value.trim());
  }

  String? _resourceIdFromInstalledMetadata(Map<String, dynamic> metadata) {
    final resourceId = metadata['resourceId'];
    if (resourceId is String && resourceId.trim().isNotEmpty) {
      return resourceId.trim();
    }
    final manifest = metadata['manifest'];
    if (manifest is Map<String, dynamic>) {
      final manifestResourceId = manifest['resourceId'];
      if (manifestResourceId is String &&
          manifestResourceId.trim().isNotEmpty) {
        return manifestResourceId.trim();
      }
    }
    return null;
  }

  Map<String, OfflineResourceUsageRecord> _readUsageRecords() {
    final raw = _storage.read(usageStorageKey);
    if (raw == null || raw.trim().isEmpty) {
      return {};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return {};
      }
      return decoded.map((key, value) {
        if (value is Map<String, dynamic>) {
          return MapEntry(key, OfflineResourceUsageRecord.fromJson(value));
        }
        return MapEntry(
          key,
          OfflineResourceUsageRecord(
            resourceId: key,
            lastUsedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      });
    } catch (_) {
      return {};
    }
  }

  List<OfflineResourceInstallJob> _readPersistedInstallJobs() {
    final raw = _storage.read(installJobsStorageKey);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(OfflineResourceInstallJob.fromJson)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writePersistedInstallJobsNow(
    List<OfflineResourceInstallJob> jobs,
  ) {
    final sortedJobs = [...jobs]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final retainedJobs = sortedJobs.take(50).toList(growable: false);
    return _storage.write(
      installJobsStorageKey,
      jsonEncode(
        retainedJobs.map((job) => job.toJson()).toList(growable: false),
      ),
    );
  }

  Future<void> _persistInstallJob(OfflineResourceInstallJob job) {
    return _enqueueInstallJobStorageWrite(() async {
      final jobsById = {
        for (final persistedJob in _readPersistedInstallJobs())
          persistedJob.jobId: persistedJob,
      };
      final previousJob = jobsById[job.jobId];
      if (previousJob == null || _installJobIsAtLeastAsNew(job, previousJob)) {
        jobsById[job.jobId] = job;
      }
      await _writePersistedInstallJobsNow(
        jobsById.values.toList(growable: false),
      );
    });
  }

  Future<void> _enqueueInstallJobStorageWrite(
    Future<void> Function() operation,
  ) {
    final nextWrite = _installJobWriteChain.then(
      (_) => operation(),
      onError: (_) => operation(),
    );
    _installJobWriteChain = nextWrite.catchError((_) {});
    return nextWrite;
  }

  bool _installJobIsAtLeastAsNew(
    OfflineResourceInstallJob nextJob,
    OfflineResourceInstallJob previousJob,
  ) {
    final nextUpdatedAt =
        nextJob.updatedAt ?? nextJob.completedAt ?? nextJob.startedAt;
    final previousUpdatedAt =
        previousJob.updatedAt ??
        previousJob.completedAt ??
        previousJob.startedAt;
    if (nextUpdatedAt.isAfter(previousUpdatedAt)) {
      return true;
    }
    if (nextUpdatedAt.isBefore(previousUpdatedAt)) {
      return false;
    }
    return _installPhaseRank(nextJob.phase) >=
        _installPhaseRank(previousJob.phase);
  }

  int _installPhaseRank(OfflineResourceInstallPhase phase) {
    return switch (phase) {
      OfflineResourceInstallPhase.queued => 0,
      OfflineResourceInstallPhase.downloading => 1,
      OfflineResourceInstallPhase.validating => 2,
      OfflineResourceInstallPhase.installing => 3,
      OfflineResourceInstallPhase.completed => 4,
      OfflineResourceInstallPhase.failed => 4,
      OfflineResourceInstallPhase.canceled => 4,
    };
  }

  void _restoreInterruptedInstallJobs() {
    if (_didRestoreInterruptedInstallJobs) {
      return;
    }
    _didRestoreInterruptedInstallJobs = true;
    final jobs = _readPersistedInstallJobs();
    var changed = false;
    final restoredJobs = <OfflineResourceInstallJob>[];
    for (final job in jobs) {
      if (job.isFinished) {
        restoredJobs.add(job);
        continue;
      }
      changed = true;
      final restoredJob = job.copyWith(
        phase: OfflineResourceInstallPhase.failed,
        message: 'Offline resource install was interrupted before completion.',
        completedAt: _now(),
        updatedAt: _now(),
        canResume: true,
      );
      restoredJobs.add(restoredJob);
      onJobChanged?.call(restoredJob);
    }
    if (changed) {
      unawaited(_writePersistedInstallJobsNow(restoredJobs));
    }
  }

  OfflineResourceInstallJob? _findResumableInstallJob(
    OfflineResourceManifest manifest,
  ) {
    final jobs =
        _readPersistedInstallJobs()
            .where(
              (job) =>
                  job.resourceId == manifest.resourceId &&
                  job.resourceVersion == manifest.version &&
                  job.canResume &&
                  job.downloadDirectoryPath != null,
            )
            .toList(growable: false)
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return jobs.isEmpty ? null : jobs.first;
  }

  Set<String> _protectedDownloadDirectoryPaths({DateTime? staleCutoff}) {
    final protected = <String>{};
    for (final job in _readPersistedInstallJobs()) {
      final directoryPath = job.downloadDirectoryPath;
      final referenceTime = job.updatedAt ?? job.completedAt ?? job.startedAt;
      final isStillFresh =
          staleCutoff == null || referenceTime.isAfter(staleCutoff);
      if (directoryPath != null && job.canResume && isStillFresh) {
        protected.add(p.normalize(directoryPath));
      }
    }
    for (final control in _installQueue.controls) {
      final directoryPath = control.latestJob.downloadDirectoryPath;
      if (directoryPath != null) {
        protected.add(p.normalize(directoryPath));
      }
    }
    return protected;
  }

  Map<String, DateTime> _downloadDirectoryReferenceTimes() {
    final references = <String, DateTime>{};
    for (final job in _readPersistedInstallJobs()) {
      final directoryPath = job.downloadDirectoryPath;
      if (directoryPath == null || !job.canResume) {
        continue;
      }
      references[p.normalize(directoryPath)] =
          job.updatedAt ?? job.completedAt ?? job.startedAt;
    }
    for (final control in _installQueue.controls) {
      final directoryPath = control.latestJob.downloadDirectoryPath;
      if (directoryPath == null) {
        continue;
      }
      references[p.normalize(directoryPath)] =
          control.latestJob.updatedAt ??
          control.latestJob.completedAt ??
          control.latestJob.startedAt;
    }
    return references;
  }

  bool _hasActiveInstallForResourceId(String resourceId) {
    return _installQueue.hasActiveResource(resourceId);
  }

  String? _sourceUriForJob(OfflineResourceManifest manifest) {
    final sourceUrl = manifest.sourceUrl;
    if (sourceUrl != null) {
      return sourceUrl.toString();
    }
    for (final file in manifest.files) {
      final url = file.url;
      if (url != null) {
        return url.toString();
      }
    }
    return null;
  }

  Future<T> _enqueueInstallJob<T>({
    required OfflineResourceInstallJob job,
    required OfflineResourceJobCallback? onJobChanged,
    required Future<T> Function(OfflineResourceJobControl control) operation,
  }) {
    return _installQueue.enqueue(
      job: job,
      onJobChanged: onJobChanged,
      operation: operation,
      duplicateFailure: _resourceFailure(
        kind: job.kind,
        message:
            'Offline resource "${job.resourceId}" already has an install or import in progress.',
        type: ResourceFailureType.service,
        code: 'offline_resource_installActive',
      ),
    );
  }

  void _emitJob(
    OfflineResourceInstallJob job,
    OfflineResourceJobCallback? onJobChanged, {
    bool removeWhenFinished = false,
  }) {
    final nextJob = job.copyWith(updatedAt: _now());
    _installQueue.updateLatestJob(nextJob);
    if (removeWhenFinished) {
      _activeJobs.remove(nextJob.resourceId);
    } else {
      _activeJobs[nextJob.resourceId] = nextJob;
    }
    unawaited(_persistInstallJob(nextJob));
    this.onJobChanged?.call(nextJob);
    _notifyJobListeners(nextJob);
    onJobChanged?.call(nextJob);
  }

  void _emitFailedJob(
    OfflineResourceInstallJob job,
    String message,
    OfflineResourceJobCallback? onJobChanged, {
    bool canResume = false,
  }) {
    final failedJob = job.copyWith(
      phase: OfflineResourceInstallPhase.failed,
      message: message,
      completedAt: _now(),
      canResume: canResume,
    );
    _emitJob(failedJob, onJobChanged, removeWhenFinished: true);
  }

  void _emitCanceledJob(
    OfflineResourceInstallJob job,
    String message,
    OfflineResourceJobCallback? onJobChanged,
  ) {
    final canceledJob = job.copyWith(
      phase: OfflineResourceInstallPhase.canceled,
      message: message,
      completedAt: _now(),
      canResume:
          job.sourceType == OfflineResourceSourceType.remote &&
          job.downloadDirectoryPath != null,
    );
    _emitJob(canceledJob, onJobChanged, removeWhenFinished: true);
  }

  void _throwIfInstallCanceled(OfflineResourceJobControl control) {
    if (control.isCanceled ||
        control.cancelToken.isCancelled ||
        _taskCancellationRegistry.isCancellationRequested(
          control.latestJob.jobId,
        ) ||
        (isCancellationRequested?.call(control.latestJob.jobId) ?? false)) {
      throw const OfflineResourceInstallCanceled(
        'Offline resource install was canceled.',
      );
    }
  }

  ResourceFailureModule _moduleForKind(OfflineResourceKind kind) {
    return ResourceFailureModule.offlineResource;
  }

  OfflineResourceServiceException _canceledResourceFailure(
    OfflineResourceInstallJob job,
    String message,
  ) {
    return OfflineResourceServiceException(
      ResourceFailure(
        type: ResourceFailureType.userCancelled,
        module: _moduleForKind(job.kind),
        message: message,
        retryable: false,
        action: ResourceFailureAction.none,
      ),
    );
  }

  String _unavailableMessage(OfflineResourceStatus status) {
    if (status.missingPaths.isNotEmpty) {
      return 'Offline resource "${status.manifest.resourceId}" is missing files: ${status.missingPaths.join(', ')}.';
    }
    return 'Offline resource "${status.manifest.resourceId}" failed file validation: ${status.invalidPaths.join(', ')}.';
  }

  String _unavailableCode(OfflineResourceStatus status) {
    if (status.missingPaths.isNotEmpty) {
      return 'offline_resource_missingFiles';
    }
    return 'offline_resource_verificationFailed';
  }

  void _ensurePlatformSupported(OfflineResourceManifest manifest) {
    if (manifest.supportsOperatingSystem(
      defaultTargetPlatform.name.toLowerCase(),
    )) {
      return;
    }
    throw _resourceFailure(
      kind: manifest.kind,
      message:
          'Offline resource "${manifest.resourceId}" is not supported on ${defaultTargetPlatform.name.toLowerCase()}.',
      type: ResourceFailureType.capability,
      action: ResourceFailureAction.none,
      code: 'offline_resource_unsupportedPlatform',
    );
  }

  bool _isSpeech(OfflineResourceKind kind) {
    return kind == OfflineResourceKind.speechAsr ||
        kind == OfflineResourceKind.speechTts ||
        kind == OfflineResourceKind.speechSpeakerEmbedding ||
        kind == OfflineResourceKind.speechLanguageIdentification;
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

  String? _safeChildPath(String parentPath, String relativePath) {
    if (!_isSafeRelativePath(relativePath)) {
      return null;
    }
    final normalizedParent = p.normalize(parentPath);
    final candidate = p.normalize(
      p.joinAll([normalizedParent, ...relativePath.split('/')]),
    );
    if (candidate == normalizedParent ||
        !p.isWithin(normalizedParent, candidate)) {
      return null;
    }
    return candidate;
  }

  void _validateManifestForFileSystemUse(OfflineResourceManifest manifest) {
    if (!_isSafeRelativePath(manifest.directoryName)) {
      throw FormatException(
        'Offline resource "${manifest.resourceId}" must use a safe directoryName value.',
      );
    }
    if (manifest.files.isEmpty) {
      throw FormatException(
        'Offline resource "${manifest.resourceId}" must contain files.',
      );
    }
    final seenPaths = <String>{};
    for (final file in manifest.files) {
      if (!_isSafeRelativePath(file.path)) {
        throw FormatException(
          'Offline resource file "${file.path}" must use a safe relative path.',
        );
      }
      if (!seenPaths.add(file.path)) {
        throw FormatException(
          'Offline resource "${manifest.resourceId}" contains duplicate file path "${file.path}".',
        );
      }
      if (file.sizeBytes < 0) {
        throw FormatException(
          'Offline resource file "${file.path}" must contain a valid sizeBytes value.',
        );
      }
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(file.sha256.toLowerCase())) {
        throw FormatException(
          'Offline resource file "${file.path}" must contain a SHA-256 hash.',
        );
      }
    }
    final entryFile = manifest.entryFile;
    if (entryFile != null) {
      if (!_isSafeRelativePath(entryFile)) {
        throw FormatException(
          'Offline resource "${manifest.resourceId}" entryFile must use a safe relative path.',
        );
      }
      if (!seenPaths.contains(entryFile)) {
        throw FormatException(
          'Offline resource "${manifest.resourceId}" entryFile is not listed in files.',
        );
      }
    }
    for (final deprecatedPath in [
      ...manifest.deprecatedDirectoryNames,
      ...manifest.deprecatedResourceIds,
    ]) {
      if (!_isSafeRelativePath(deprecatedPath)) {
        throw FormatException(
          'Offline resource "${manifest.resourceId}" contains an unsafe deprecated path value.',
        );
      }
    }
  }

  void _validateManifestForPublicUse(OfflineResourceManifest manifest) {
    try {
      _validateManifestForFileSystemUse(manifest);
    } catch (error) {
      throw _resourceFailure(
        kind: manifest.kind,
        message:
            'Invalid offline resource manifest "${manifest.resourceId}": $error',
        type: ResourceFailureType.validation,
        action: ResourceFailureAction.configure,
        cause: error,
      );
    }
  }

  OfflineResourceServiceException _resourceFailure({
    required OfflineResourceKind kind,
    required String message,
    ResourceFailureType type = ResourceFailureType.service,
    ResourceFailureAction action = ResourceFailureAction.installResource,
    String? code,
    Object? cause,
  }) {
    return _offlineResourceServiceFailure(
      kind: kind,
      message: message,
      type: type,
      action: action,
      code: code,
      cause: cause,
    );
  }

  final Map<String, Set<OfflineResourceJobCallback>> _jobListeners = {};
  final List<void Function()> _changeListeners = <void Function()>[];
  Future<OfflineResourceCenterSnapshot>? _snapshot;
  DateTime? _snapshotAt;
  final Map<String, OfflineResourceInstallJob> _lastJobs = {};

  OfflineResourceInstallJob? lastJobFor(String resourceId) =>
      _lastJobs[resourceId];

  OfflineResourceInstallJob? activeJobFor(String resourceId) {
    for (final job in activeJobs) {
      if (job.resourceId == resourceId) {
        return job;
      }
    }
    return null;
  }

  void addChangeListener(void Function() listener) {
    _changeListeners.add(listener);
  }

  void removeChangeListener(void Function() listener) {
    _changeListeners.remove(listener);
  }

  void addJobListener(String resourceId, OfflineResourceJobCallback listener) {
    (_jobListeners[resourceId] ??= {}).add(listener);
  }

  void removeJobListener(
    String resourceId,
    OfflineResourceJobCallback listener,
  ) {
    final listeners = _jobListeners[resourceId];
    listeners?.remove(listener);
    if (listeners?.isEmpty ?? false) {
      _jobListeners.remove(resourceId);
    }
  }

  Future<List<OfflineResourceStatus>> list({
    required Set<OfflineResourceKind> kinds,
  }) async {
    if (_snapshotAt == null ||
        DateTime.now().difference(_snapshotAt!) > const Duration(seconds: 5)) {
      _snapshotAt = DateTime.now();
      _snapshot = loadSnapshot();
    }
    final snapshot = await _snapshot!;
    return snapshot.statuses
        .where((status) => kinds.contains(status.manifest.kind))
        .toList(growable: false);
  }

  Future<void> startPendingInstalls(Set<OfflineResourceKind> kinds) async {
    if (kinds.isEmpty) {
      return;
    }
    final statuses = await list(kinds: kinds);
    for (final status in statuses) {
      if (status.isInstalled) {
        continue;
      }
      queueInstall(status.manifest);
    }
  }

  void queueInstall(OfflineResourceManifest manifest) {
    if (activeJobFor(manifest.resourceId) != null) {
      return;
    }
    _notifyChanged();
    unawaited(install(manifest).then<void>((_) {}, onError: (_, _) {}));
  }

  Future<void> resumeInterruptedInstalls() async {
    final snapshot = await loadSnapshot();
    final manifests = {
      for (final status in snapshot.statuses)
        status.manifest.resourceId: status,
    };
    for (final job in installJobs) {
      if (!job.canResume) {
        continue;
      }
      final status = manifests[job.resourceId];
      if (status == null || status.isInstalled) {
        continue;
      }
      if (job.resourceVersion != null &&
          job.resourceVersion != status.manifest.version) {
        continue;
      }
      queueInstall(status.manifest);
    }
  }

  Future<OfflineResourceStatus> install(
    OfflineResourceManifest manifest, {
    OfflineResourceJobCallback? onJobChanged,
  }) {
    return installResource(manifest, onJobChanged: onJobChanged);
  }

  Future<OfflineResourceStatus> importDirectory({
    required Directory sourceDirectory,
    required OfflineResourceManifest manifest,
    OfflineResourceJobCallback? onJobChanged,
  }) {
    return importResourceDirectory(
      sourceDirectory: sourceDirectory,
      manifest: manifest,
      onJobChanged: onJobChanged,
    );
  }

  Future<void> setUsesHuggingFaceMirror(bool enabled) async {
    await writeHuggingFaceMirrorHost(
      enabled
          ? OfflineResourceDownloadMirrors.defaultHuggingFaceMirrorHost
          : OfflineResourceDownloadMirrors.disabledSentinel,
    );
    _notifyChanged();
  }

  Future<void> remove(OfflineResourceManifest manifest) async {
    await removeResource(manifest);
    _snapshotAt = null;
    _notifyChanged();
  }

  Future<OfflineResourceStatus> verify(OfflineResourceManifest manifest) async {
    final status = await verifyResource(manifest);
    _snapshotAt = null;
    _notifyChanged();
    return status;
  }

  Future<bool> cancelInstall(String resourceIdOrJobId) {
    return cancelResourceInstall(resourceIdOrJobId);
  }

  void _notifyJobListeners(OfflineResourceInstallJob job) {
    _lastJobs[job.resourceId] = job;
    if (job.isFinished) _snapshotAt = null;
    final listeners = List<OfflineResourceJobCallback>.of(
      _jobListeners[job.resourceId] ?? const {},
    );
    for (final listener in listeners) {
      listener(job);
    }
    _notifyChanged();
  }

  void _notifyChanged() {
    final changeListeners = List<void Function()>.of(_changeListeners);
    for (final listener in changeListeners) {
      listener();
    }
  }

  Future<OfflineResourceCenterSnapshot> loadSnapshot({
    String? catalogUrl,
    bool forceRemote = false,
  }) async {
    final catalog = await loadCatalog(
      catalogUrl: catalogUrl,
      forceRemote: forceRemote,
    );
    return OfflineResourceCenterSnapshot(
      catalog: catalog,
      statuses: await inspectResources(catalog.resources),
      installJobs: installJobs,
    );
  }

  Future<List<OfflineResourceStatus>> availabilityByKind(
    OfflineResourceKind kind,
  ) => inspectLocalResourcesByKind(kind);
}

class OfflineResourceCenterSnapshot {
  const OfflineResourceCenterSnapshot({
    required this.catalog,
    required this.statuses,
    required this.installJobs,
  });

  final OfflineResourceCatalogDocument catalog;
  final List<OfflineResourceStatus> statuses;
  final List<OfflineResourceInstallJob> installJobs;

  Map<String, OfflineResourceStatus> get statusById => {
    for (final status in statuses) status.manifest.resourceId: status,
  };

  Map<String, OfflineResourceInstallJob> get jobById => {
    for (final job in installJobs) job.resourceId: job,
  };

  int get installedBytes =>
      statuses.fold<int>(0, (sum, status) => sum + status.installedBytes);

  int get availableBytes =>
      statuses.fold<int>(0, (sum, status) => sum + status.manifest.sizeBytes);

  bool isAvailable(String resourceId) {
    return statuses.any(
      (status) =>
          status.manifest.resourceId == resourceId && status.isInstalled,
    );
  }

  List<OfflineResourceStatus> statusesForKind(OfflineResourceKind kind) {
    return statuses
        .where((status) => status.manifest.kind == kind)
        .toList(growable: false);
  }
}
