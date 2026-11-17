import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uni_model_resources/src/resource_failure.dart';
import 'package:uni_model_resources/src/offline_resource_models.dart';

class OfflineResourceCatalogTrustPolicy {
  const OfflineResourceCatalogTrustPolicy({
    this.allowedRemoteHosts = const {},
    this.allowedRemoteUris = const {},
    this.pinnedCatalogDigests = const {},
    this.trustedEd25519PublicKeys = const {},
    this.revokedKeyIds = const {},
    this.allowAnyHttpsSource = false,
    this.allowLocalCatalogs = true,
    this.allowInsecureHttp = false,
    this.requireSignatureForRemoteCatalogs = true,
  });

  final Set<String> allowedRemoteHosts;
  final Set<String> allowedRemoteUris;
  final Map<String, String> pinnedCatalogDigests;
  final Map<String, String> trustedEd25519PublicKeys;
  final Set<String> revokedKeyIds;
  final bool allowAnyHttpsSource;
  final bool allowLocalCatalogs;
  final bool allowInsecureHttp;
  final bool requireSignatureForRemoteCatalogs;

  bool isSourceAllowed(Uri uri) {
    if (uri.scheme == 'file') {
      return allowLocalCatalogs;
    }
    if (uri.scheme == 'https') {
      return allowAnyHttpsSource || _matchesRemoteAllowlist(uri);
    }
    if (uri.scheme == 'http') {
      return allowInsecureHttp && _matchesRemoteAllowlist(uri);
    }
    return false;
  }

  bool hasPinnedDigest(Uri uri) {
    return pinnedDigestFor(uri) != null;
  }

  String? pinnedDigestFor(Uri uri) {
    final candidates = _digestLookupCandidates(uri);
    for (final candidate in candidates) {
      final digest = pinnedCatalogDigests[candidate];
      if (digest != null && digest.trim().isNotEmpty) {
        return digest.trim();
      }
    }
    return null;
  }

  bool _matchesRemoteAllowlist(Uri uri) {
    final host = uri.host.toLowerCase();
    final authority = uri.port == 0
        ? host
        : '${uri.host.toLowerCase()}:${uri.port}';
    return allowedRemoteHosts
            .map((value) => value.toLowerCase())
            .contains(host) ||
        allowedRemoteHosts
            .map((value) => value.toLowerCase())
            .contains(authority) ||
        allowedRemoteUris.contains(uri.toString());
  }

  List<String> _digestLookupCandidates(Uri uri) {
    final host = uri.host.toLowerCase();
    final authority = uri.port == 0
        ? host
        : '${uri.host.toLowerCase()}:${uri.port}';
    return [uri.toString(), '${uri.scheme}://$authority', authority, host];
  }
}

class OfflineResourceCatalogModule {
  const OfflineResourceCatalogModule({
    this.trustPolicy = const OfflineResourceCatalogTrustPolicy(),
    this.failureFactory = _defaultCatalogFailureFactory,
  });

  final OfflineResourceCatalogTrustPolicy trustPolicy;
  final OfflineResourceCatalogFailureFactory failureFactory;

  OfflineResourceCatalogDocument parseCatalogString(
    String source, {
    String catalogSource = 'catalog',
    int priority = 0,
  }) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Offline resource catalog must be a JSON object.',
        );
      }
      final document = OfflineResourceCatalogDocument.fromJson(decoded);
      return OfflineResourceCatalogDocument(
        schemaVersion: document.schemaVersion,
        source: document.source == 'catalog' ? catalogSource : document.source,
        priority: document.priority == 0 ? priority : document.priority,
        signature: document.signature,
        resources: document.resources,
        conflicts: document.conflicts,
      );
    } catch (error) {
      throw failureFactory(
        kind: OfflineResourceKind.translation,
        message: 'Invalid offline resource catalog: $error',
        type: ResourceFailureType.validation,
        action: ResourceFailureAction.configure,
        cause: error,
      );
    }
  }

  void validateSourceAllowed(Uri sourceUri) {
    if (!trustPolicy.isSourceAllowed(sourceUri)) {
      throw failureFactory(
        kind: OfflineResourceKind.translation,
        message: 'Offline resource catalog source is not trusted: $sourceUri',
        type: ResourceFailureType.configuration,
        action: ResourceFailureAction.configure,
      );
    }
  }

  Future<void> verifyCatalogSignature(String rawCatalog, Uri sourceUri) async {
    final decoded = jsonDecode(rawCatalog);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Offline resource catalog must be a JSON object.',
      );
    }

    final signature = OfflineResourceCatalogSignature.tryParse(
      decoded['signature'],
    );
    final isRemote = sourceUri.scheme == 'http' || sourceUri.scheme == 'https';
    final requiresSignature =
        isRemote &&
        (trustPolicy.requireSignatureForRemoteCatalogs ||
            trustPolicy.hasPinnedDigest(sourceUri));
    if (signature == null && requiresSignature) {
      throw const FormatException(
        'Remote offline resource catalog must include a signature.',
      );
    }

    final payload = Map<String, dynamic>.from(decoded)..remove('signature');
    final digest = sha256
        .convert(utf8.encode(_canonicalJson(payload)))
        .toString();
    if (signature != null) {
      if (signature.algorithm.toLowerCase() != 'ed25519') {
        throw FormatException(
          'Unsupported offline resource catalog signature algorithm: ${signature.algorithm}.',
        );
      }
      if (trustPolicy.revokedKeyIds.contains(signature.keyId)) {
        throw const FormatException(
          'Offline resource catalog signing key is revoked.',
        );
      }
      final encodedPublicKey =
          trustPolicy.trustedEd25519PublicKeys[signature.keyId];
      if (encodedPublicKey == null) {
        throw const FormatException(
          'Offline resource catalog signing key is not trusted.',
        );
      }
      final verified = await Ed25519().verify(
        utf8.encode(_canonicalJson(payload)),
        signature: Signature(
          base64Url.decode(signature.value),
          publicKey: SimplePublicKey(
            base64Url.decode(encodedPublicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!verified) {
        throw const FormatException(
          'Offline resource catalog signature does not match its payload.',
        );
      }
    }

    final pinnedDigest = trustPolicy.pinnedDigestFor(sourceUri);
    if (pinnedDigest != null && pinnedDigest.toLowerCase() != digest) {
      throw const FormatException(
        'Offline resource catalog does not match its pinned digest.',
      );
    }
  }

  OfflineResourceCatalogDocument mergeCatalogs(
    List<OfflineResourceCatalogDocument> catalogs,
  ) {
    final resourcesById = <String, _CatalogResourceEntry>{};
    final conflicts = <OfflineResourceCatalogConflict>[];
    var schemaVersion = OfflineResourceCatalogDocument.currentSchemaVersion;
    for (final catalog in catalogs) {
      if (catalog.schemaVersion > schemaVersion) {
        schemaVersion = catalog.schemaVersion;
      }
      for (final resource in catalog.resources) {
        final nextEntry = _CatalogResourceEntry(
          resource: resource,
          catalog: catalog,
        );
        final existingEntry = resourcesById[resource.resourceId];
        if (existingEntry == null) {
          resourcesById[resource.resourceId] = nextEntry;
          continue;
        }

        final nextWins = _catalogResourceWins(nextEntry, existingEntry);
        final keptEntry = nextWins ? nextEntry : existingEntry;
        final skippedEntry = nextWins ? existingEntry : nextEntry;
        resourcesById[resource.resourceId] = keptEntry;
        conflicts.add(
          OfflineResourceCatalogConflict(
            resourceId: resource.resourceId,
            keptSource: keptEntry.catalog.source,
            skippedSource: skippedEntry.catalog.source,
            keptVersion: keptEntry.resource.version,
            skippedVersion: skippedEntry.resource.version,
            reason: _catalogConflictReason(keptEntry, skippedEntry),
          ),
        );
      }
    }

    final resources = resourcesById.values
        .map((entry) => entry.resource)
        .toList(growable: false);
    _validateMergedCatalogStoragePaths(resources);

    return OfflineResourceCatalogDocument(
      schemaVersion: schemaVersion,
      source: 'merged',
      priority: catalogs.fold<int>(
        0,
        (maxPriority, catalog) =>
            catalog.priority > maxPriority ? catalog.priority : maxPriority,
      ),
      resources: resources,
      conflicts: conflicts,
    );
  }

  void _validateMergedCatalogStoragePaths(
    List<OfflineResourceManifest> resources,
  ) {
    final resourcesByPath = <String, OfflineResourceManifest>{};
    for (final resource in resources) {
      final storageKey = _resourceStorageKey(resource);
      final existingResource = resourcesByPath[storageKey];
      if (existingResource != null &&
          existingResource.resourceId != resource.resourceId) {
        throw failureFactory(
          kind: resource.kind,
          message:
              'Offline resources "${existingResource.resourceId}" and "${resource.resourceId}" use the same storage directory.',
          type: ResourceFailureType.validation,
          action: ResourceFailureAction.configure,
        );
      }
      resourcesByPath[storageKey] = resource;
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

  bool _catalogResourceWins(
    _CatalogResourceEntry nextEntry,
    _CatalogResourceEntry existingEntry,
  ) {
    final priorityComparison = nextEntry.catalog.priority.compareTo(
      existingEntry.catalog.priority,
    );
    if (priorityComparison != 0) {
      return priorityComparison > 0;
    }
    final versionComparison = _compareVersionStrings(
      nextEntry.resource.version,
      existingEntry.resource.version,
    );
    if (versionComparison != 0) {
      return versionComparison > 0;
    }
    return nextEntry.catalog.source.compareTo(existingEntry.catalog.source) >=
        0;
  }

  String _catalogConflictReason(
    _CatalogResourceEntry keptEntry,
    _CatalogResourceEntry skippedEntry,
  ) {
    if (keptEntry.catalog.priority != skippedEntry.catalog.priority) {
      return 'Catalog priority selected the kept resource.';
    }
    if (keptEntry.resource.version != skippedEntry.resource.version) {
      return 'Resource version selected the kept resource.';
    }
    return 'Catalog source order selected the kept resource.';
  }

  int _compareVersionStrings(String a, String b) {
    final aParts = _versionParts(a);
    final bParts = _versionParts(b);
    final maxLength = aParts.length > bParts.length
        ? aParts.length
        : bParts.length;
    for (var index = 0; index < maxLength; index++) {
      final aPart = index < aParts.length ? aParts[index] : '0';
      final bPart = index < bParts.length ? bParts[index] : '0';
      final aNumber = int.tryParse(aPart);
      final bNumber = int.tryParse(bPart);
      final comparison = aNumber != null && bNumber != null
          ? aNumber.compareTo(bNumber)
          : aPart.compareTo(bPart);
      if (comparison != 0) {
        return comparison;
      }
    }
    return 0;
  }

  List<String> _versionParts(String value) {
    return RegExp(r'[0-9]+|[A-Za-z]+')
        .allMatches(value)
        .map((match) => match.group(0) ?? '')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
  }

  String _canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      final normalized = <String, Object?>{};
      for (final key in keys) {
        normalized[key] = _canonicalJsonValue(value[key]);
      }
      return jsonEncode(normalized);
    }
    return jsonEncode(_canonicalJsonValue(value));
  }

  Object? _canonicalJsonValue(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: _canonicalJsonValue(value[key])};
    }
    if (value is List) {
      return value.map(_canonicalJsonValue).toList(growable: false);
    }
    return value;
  }
}

typedef OfflineResourceCatalogFailureFactory =
    Object Function({
      required OfflineResourceKind kind,
      required String message,
      ResourceFailureType type,
      ResourceFailureAction action,
      String? code,
      Object? cause,
    });

Object _defaultCatalogFailureFactory({
  required OfflineResourceKind kind,
  required String message,
  ResourceFailureType type = ResourceFailureType.service,
  ResourceFailureAction action = ResourceFailureAction.installResource,
  String? code,
  Object? cause,
}) {
  return ResourceFailure(
    type: type,
    module: ResourceFailureModule.offlineResource,
    message: message,
    retryable:
        type == ResourceFailureType.network ||
        type == ResourceFailureType.service,
    action: action,
    code: code,
    cause: cause,
  );
}

class _CatalogResourceEntry {
  const _CatalogResourceEntry({required this.resource, required this.catalog});

  final OfflineResourceManifest resource;
  final OfflineResourceCatalogDocument catalog;
}
