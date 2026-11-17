import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uni_model_resources/src/offline_resource_models.dart';

class SherpaWhisperModelConfig {
  const SherpaWhisperModelConfig({
    required this.modelId,
    required this.languageCodes,
    required this.encoderPath,
    required this.decoderPath,
    required this.tokensPath,
  });

  final String modelId;
  final Set<String> languageCodes;
  final String encoderPath;
  final String decoderPath;
  final String tokensPath;
}

class SherpaTtsModelConfig {
  const SherpaTtsModelConfig({
    required this.modelId,
    this.modelType = 'vits',
    this.voicesPath = '',
    this.defaultSpeakers = const {},
    this.speakerCount,
    required this.languageCodes,
    required this.modelPath,
    required this.tokensPath,
    required this.outputDirPath,
    required this.dataDirPath,
    required this.lexiconPath,
    required this.dictDirPath,
    required this.ruleFsts,
    required this.ruleFars,
  });

  final String modelType;
  final String voicesPath;
  final Map<String, int> defaultSpeakers;
  final int? speakerCount;
  final String modelId;
  final Set<String> languageCodes;
  final String modelPath;
  final String tokensPath;
  final String outputDirPath;
  final String dataDirPath;
  final String lexiconPath;
  final String dictDirPath;
  final String ruleFsts;
  final String ruleFars;
}

class SherpaSpeakerEmbeddingModelConfig {
  const SherpaSpeakerEmbeddingModelConfig({
    required this.modelId,
    required this.modelVersion,
    required this.languageCodes,
    required this.modelPath,
    required this.sampleRate,
    required this.embeddingDimension,
    required this.preprocessingVersion,
    required this.supportedPlatforms,
  });

  final String modelId;
  final String modelVersion;
  final Set<String> languageCodes;
  final String modelPath;
  final int sampleRate;
  final int embeddingDimension;
  final String preprocessingVersion;
  final Set<String> supportedPlatforms;
}

class SherpaWhisperModelStatus {
  const SherpaWhisperModelStatus({
    required this.modelId,
    required this.languageCodes,
    required this.directoryPath,
    required this.requiredPaths,
    required this.missingPaths,
    this.invalidPaths = const <String>[],
    required this.config,
    this.resourceManifest,
  });

  final String modelId;
  final Set<String> languageCodes;
  final String directoryPath;
  final List<String> requiredPaths;
  final List<String> missingPaths;
  final List<String> invalidPaths;
  final SherpaWhisperModelConfig? config;
  final OfflineResourceManifest? resourceManifest;

  bool get isInstalled =>
      config != null && missingPaths.isEmpty && invalidPaths.isEmpty;

  String get resourceId => resourceManifest?.resourceId ?? modelId;

  String get diagnosticMessage {
    if (isInstalled) {
      return 'Model "$modelId" is installed.';
    }
    if (missingPaths.isEmpty && invalidPaths.isEmpty) {
      return 'Model "$modelId" is not registered.';
    }
    if (missingPaths.isNotEmpty && invalidPaths.isNotEmpty) {
      return 'Model "$modelId" is unavailable. Missing files: ${missingPaths.join(', ')}. '
          'Invalid files: ${invalidPaths.join(', ')}.';
    }
    if (invalidPaths.isNotEmpty) {
      return 'Model "$modelId" failed file validation: ${invalidPaths.join(', ')}.';
    }
    return 'Model "$modelId" is unavailable. Missing files: ${missingPaths.join(', ')}.';
  }
}

class SherpaTtsModelStatus {
  const SherpaTtsModelStatus({
    required this.modelId,
    required this.languageCodes,
    required this.directoryPath,
    required this.requiredPaths,
    required this.missingPaths,
    this.invalidPaths = const <String>[],
    required this.config,
    this.resourceManifest,
  });

  final String modelId;
  final Set<String> languageCodes;
  final String directoryPath;
  final List<String> requiredPaths;
  final List<String> missingPaths;
  final List<String> invalidPaths;
  final SherpaTtsModelConfig? config;
  final OfflineResourceManifest? resourceManifest;

  bool get isInstalled =>
      config != null && missingPaths.isEmpty && invalidPaths.isEmpty;

  String get resourceId => resourceManifest?.resourceId ?? modelId;

  String get diagnosticMessage {
    if (isInstalled) {
      return 'Model "$modelId" is installed.';
    }
    if (missingPaths.isEmpty && invalidPaths.isEmpty) {
      return 'Model "$modelId" is not registered.';
    }
    if (missingPaths.isNotEmpty && invalidPaths.isNotEmpty) {
      return 'Model "$modelId" is unavailable. Missing files: ${missingPaths.join(', ')}. '
          'Invalid files: ${invalidPaths.join(', ')}.';
    }
    if (invalidPaths.isNotEmpty) {
      return 'Model "$modelId" failed file validation: ${invalidPaths.join(', ')}.';
    }
    return 'Model "$modelId" is unavailable. Missing files: ${missingPaths.join(', ')}.';
  }
}

class SherpaSpeakerEmbeddingModelStatus {
  const SherpaSpeakerEmbeddingModelStatus({
    required this.modelId,
    required this.languageCodes,
    required this.directoryPath,
    required this.requiredPaths,
    required this.missingPaths,
    this.invalidPaths = const <String>[],
    required this.config,
    this.platformSupported = true,
    this.supportedPlatforms = const <String>{},
    this.resourceManifest,
  });

  final String modelId;
  final Set<String> languageCodes;
  final String directoryPath;
  final List<String> requiredPaths;
  final List<String> missingPaths;
  final List<String> invalidPaths;
  final SherpaSpeakerEmbeddingModelConfig? config;
  final bool platformSupported;
  final Set<String> supportedPlatforms;
  final OfflineResourceManifest? resourceManifest;

  bool get isInstalled =>
      config != null &&
      platformSupported &&
      missingPaths.isEmpty &&
      invalidPaths.isEmpty;

  String get resourceId => resourceManifest?.resourceId ?? modelId;

  String get diagnosticMessage {
    if (!platformSupported) {
      final matrix = supportedPlatforms.toList(growable: false)..sort();
      return 'Speaker embedding model "$modelId" is unsupported on this platform. '
          'Supported platforms: ${matrix.join(', ')}.';
    }
    if (isInstalled) {
      return 'Speaker embedding model "$modelId" is installed.';
    }
    if (missingPaths.isEmpty && invalidPaths.isEmpty) {
      return 'Speaker embedding model "$modelId" is not registered.';
    }
    if (missingPaths.isNotEmpty && invalidPaths.isNotEmpty) {
      return 'Speaker embedding model "$modelId" is unavailable. Missing files: ${missingPaths.join(', ')}. '
          'Invalid files: ${invalidPaths.join(', ')}.';
    }
    if (invalidPaths.isNotEmpty) {
      return 'Speaker embedding model "$modelId" failed file validation: ${invalidPaths.join(', ')}.';
    }
    return 'Speaker embedding model "$modelId" is unavailable. Missing files: ${missingPaths.join(', ')}.';
  }
}

class SherpaModelRegistry {
  SherpaModelRegistry({
    Future<Directory> Function()? applicationSupportDirectoryProvider,
  }) : _getApplicationSupportDirectory =
           applicationSupportDirectoryProvider ??
           getApplicationSupportDirectory;

  final Future<Directory> Function() _getApplicationSupportDirectory;
  static const _metadataFileName = '.transli_resource.json';

  static const _whisperDefinition = _SherpaWhisperDefinition(
    modelId: 'whisper_tiny',
    languageCodes: {'multi'},
    directoryName: 'sherpa-onnx-whisper-tiny',
    encoderFileName: 'tiny-encoder.int8.onnx',
    decoderFileName: 'tiny-decoder.int8.onnx',
    tokensFileName: 'tiny-tokens.txt',
  );

  static const List<_SherpaTtsDefinition> _ttsDefinitions = [
    _SherpaTtsDefinition(
      modelId: 'melo_zh_en',
      languageCodes: {'zh', 'en'},
      directoryName: 'vits-melo-tts-zh_en',
      modelFileName: 'model.onnx',
      tokensFileName: 'tokens.txt',
      lexiconFileName: 'lexicon.txt',
      dictDirectoryName: 'dict',
      ruleFstsFileNames: [
        'phone.fst',
        'date.fst',
        'number.fst',
        'new_heteronym.fst',
      ],
    ),
    _SherpaTtsDefinition(
      modelId: 'zh_aishell3',
      languageCodes: {'zh'},
      directoryName: 'vits-icefall-zh-aishell3',
      modelFileName: 'model.onnx',
      tokensFileName: 'tokens.txt',
      lexiconFileName: 'lexicon.txt',
      ruleFstsFileNames: [
        'phone.fst',
        'date.fst',
        'number.fst',
        'new_heteronym.fst',
      ],
      ruleFarsFileName: 'rule.far',
    ),
    _SherpaTtsDefinition(
      modelId: 'en_libritts',
      languageCodes: {'en'},
      directoryName: 'vits-piper-en_US-libritts_r-medium',
      modelFileName: 'en_US-libritts_r-medium.onnx',
      tokensFileName: 'tokens.txt',
      dataDirectoryName: 'espeak-ng-data',
    ),
    _SherpaTtsDefinition(
      modelId: 'en_amy_low',
      languageCodes: {'en'},
      directoryName: 'vits-piper-en_US-amy-low',
      modelFileName: 'en_US-amy-low.onnx',
      tokensFileName: 'tokens.txt',
      dataDirectoryName: 'espeak-ng-data',
    ),
  ];

  static const _speakerEmbeddingDefinition = _SherpaSpeakerEmbeddingDefinition(
    modelId: 'speaker_embedding_default',
    modelVersion: '1.0.0',
    languageCodes: {'multi'},
    directoryName: '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k',
    modelFileName: '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
    sampleRate: 16000,
    embeddingDimension: 512,
    preprocessingVersion: 'pcm16le_norm_v1',
    supportedPlatforms: {'android', 'ios', 'macos', 'windows', 'linux'},
  );

  Future<SherpaWhisperModelStatus> resolveWhisperModel({
    String modelId = 'whisper_tiny',
  }) async {
    final root = await _getApplicationSupportDirectory();
    final manifestDefinition = await _resolveWhisperDefinitionFromManifests(
      root,
      modelId,
    );
    if (manifestDefinition != null) {
      return manifestDefinition.resolve(root);
    }
    if (_whisperDefinition.modelId != modelId) {
      return SherpaWhisperModelStatus(
        modelId: modelId,
        languageCodes: const {'multi'},
        directoryPath: p.join(root.path, 'sherpa_onnx', modelId),
        requiredPaths: const [],
        missingPaths: const [],
        config: null,
      );
    }
    return _whisperDefinition.resolve(root);
  }

  Future<List<SherpaTtsModelStatus>> listTtsModels() async {
    final root = await _getApplicationSupportDirectory();
    final statuses = <SherpaTtsModelStatus>[];
    for (final definition in await _resolveTtsDefinitions(root)) {
      statuses.add(await definition.resolve(root));
    }
    return statuses;
  }

  Future<SherpaTtsModelStatus?> resolveTtsModelForLanguage(
    String languageCode,
  ) async {
    final normalizedLanguageCode = languageCode
        .trim()
        .replaceAll('_', '-')
        .toLowerCase()
        .split('-')
        .first;
    final root = await _getApplicationSupportDirectory();

    SherpaTtsModelStatus? firstMissingMatch;
    for (final definition in await _resolveTtsDefinitions(root)) {
      if (!definition.languageCodes.contains(normalizedLanguageCode)) {
        continue;
      }

      final status = await definition.resolve(root);
      if (status.isInstalled) {
        return status;
      }
      firstMissingMatch ??= status;
    }

    return firstMissingMatch;
  }

  Future<SherpaSpeakerEmbeddingModelStatus> resolveSpeakerEmbeddingModel({
    String modelId = 'speaker_embedding_default',
  }) async {
    final root = await _getApplicationSupportDirectory();
    final definition = await _resolveSpeakerEmbeddingDefinitionFromManifests(
      root,
      modelId,
    );
    if (definition != null) {
      return definition.resolve(root);
    }
    if (_speakerEmbeddingDefinition.modelId != modelId) {
      return SherpaSpeakerEmbeddingModelStatus(
        modelId: modelId,
        languageCodes: const {'multi'},
        directoryPath: p.join(root.path, 'sherpa_onnx', modelId),
        requiredPaths: const <String>[],
        missingPaths: const <String>[],
        config: null,
      );
    }
    return _speakerEmbeddingDefinition.resolve(root);
  }

  Future<List<OfflineResourceManifest>>
  listInstalledSpeechResourceManifests() async {
    final root = await _getApplicationSupportDirectory();
    return _loadInstalledSpeechResourceManifests(root);
  }

  Future<OfflineResourceManifest?> findInstalledSpeechResourceManifest(
    String resourceId,
  ) async {
    final normalizedResourceId = resourceId.trim();
    if (normalizedResourceId.isEmpty) {
      return null;
    }
    final manifests = await listInstalledSpeechResourceManifests();
    for (final manifest in manifests) {
      if (manifest.resourceId == normalizedResourceId) {
        return manifest;
      }
    }
    return null;
  }

  Future<_SherpaWhisperDefinition?> _resolveWhisperDefinitionFromManifests(
    Directory applicationSupportDirectory,
    String modelId,
  ) async {
    final manifests = await _loadInstalledSpeechResourceManifests(
      applicationSupportDirectory,
    );
    for (final manifest in manifests) {
      if (manifest.kind != OfflineResourceKind.speechAsr ||
          manifest.resourceId != modelId) {
        continue;
      }
      return _whisperDefinitionFromManifest(manifest);
    }
    return null;
  }

  Future<_SherpaSpeakerEmbeddingDefinition?>
  _resolveSpeakerEmbeddingDefinitionFromManifests(
    Directory applicationSupportDirectory,
    String modelId,
  ) async {
    final manifests = await _loadInstalledSpeechResourceManifests(
      applicationSupportDirectory,
    );
    for (final manifest in manifests) {
      if (manifest.kind != OfflineResourceKind.speechSpeakerEmbedding ||
          manifest.resourceId != modelId) {
        continue;
      }
      return _speakerEmbeddingDefinitionFromManifest(manifest);
    }
    return null;
  }

  Future<List<_SherpaTtsDefinition>> _resolveTtsDefinitions(
    Directory applicationSupportDirectory,
  ) async {
    final definitions = <_SherpaTtsDefinition>[];
    final seenModelIds = <String>{};
    final manifests = await _loadInstalledSpeechResourceManifests(
      applicationSupportDirectory,
    );
    for (final manifest in manifests) {
      if (manifest.kind != OfflineResourceKind.speechTts) {
        continue;
      }
      final definition = _ttsDefinitionFromManifest(manifest);
      if (definition == null || !seenModelIds.add(definition.modelId)) {
        continue;
      }
      definitions.add(definition);
    }
    for (final fallbackDefinition in _ttsDefinitions) {
      if (seenModelIds.add(fallbackDefinition.modelId)) {
        definitions.add(fallbackDefinition);
      }
    }
    return definitions;
  }

  Future<List<OfflineResourceManifest>> _loadInstalledSpeechResourceManifests(
    Directory applicationSupportDirectory,
  ) async {
    final sherpaRoot = Directory(
      p.join(applicationSupportDirectory.path, 'sherpa_onnx'),
    );
    if (!await sherpaRoot.exists()) {
      return const [];
    }

    final manifests = <OfflineResourceManifest>[];
    await for (final entity in sherpaRoot.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final metadataFile = File(p.join(entity.path, _metadataFileName));
      if (!await metadataFile.exists()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await metadataFile.readAsString());
        if (decoded is! Map<String, dynamic>) {
          continue;
        }
        final manifestJson = decoded['manifest'];
        if (manifestJson is! Map<String, dynamic>) {
          continue;
        }
        final manifest = OfflineResourceManifest.fromJson(manifestJson);
        if (_isSpeechRuntimeKind(manifest.kind) &&
            manifest.directoryName == p.basename(entity.path)) {
          manifests.add(manifest);
        }
      } catch (_) {
        continue;
      }
    }
    return manifests;
  }

  _SherpaWhisperDefinition? _whisperDefinitionFromManifest(
    OfflineResourceManifest manifest,
  ) {
    for (final binding in manifest.runtimeBindings) {
      final type = binding.options['modelType'];
      if (type != null && type != 'whisper') return null;
    }
    final encoderPath = _findManifestFilePath(
      manifest,
      (path) => path.endsWith('.onnx') && path.contains('encoder'),
    );
    final decoderPath = _findManifestFilePath(
      manifest,
      (path) => path.endsWith('.onnx') && path.contains('decoder'),
    );
    final tokensPath = _findManifestFilePath(
      manifest,
      (path) => p.basename(path).contains('tokens') && path.endsWith('.txt'),
    );
    if (encoderPath == null || decoderPath == null || tokensPath == null) {
      return null;
    }
    return _SherpaWhisperDefinition(
      modelId: manifest.resourceId,
      languageCodes: manifest.languageCodes,
      directoryName: manifest.directoryName,
      encoderFileName: encoderPath,
      decoderFileName: decoderPath,
      tokensFileName: tokensPath,
      resourceManifest: manifest,
    );
  }

  _SherpaTtsDefinition? _ttsDefinitionFromManifest(
    OfflineResourceManifest manifest,
  ) {
    final modelPath =
        _safeManifestEntryFile(manifest) ??
        _findManifestFilePath(
          manifest,
          (path) => p.basename(path) == 'model.onnx',
        ) ??
        _findManifestFilePath(manifest, (path) => path.endsWith('.onnx'));
    final tokensPath = _findManifestFilePath(
      manifest,
      (path) => p.basename(path) == 'tokens.txt',
    );
    if (modelPath == null || tokensPath == null) {
      return null;
    }
    final bindings = manifest.runtimeBindings.where(
      (binding) => binding.kind == OfflineResourceRuntimeBindingKind.speechTts,
    );
    final options = bindings.isEmpty
        ? const <String, Object?>{}
        : bindings.first.options;
    final modelType = options['modelType']?.toString() ?? 'vits';
    if (!const {'vits', 'kokoro', 'kitten'}.contains(modelType)) return null;
    final voices = _findManifestFilePath(
      manifest,
      (path) => p.basename(path) == 'voices.bin',
    );
    if (modelType != 'vits' && voices == null) return null;
    final lexicons = options['lexicons'];
    final lexiconNames = lexicons is List
        ? lexicons
              .whereType<String>()
              .where((path) => manifest.files.any((file) => file.path == path))
              .toList()
        : <String>[];
    final speakers = options['defaultSpeakers'];
    return _SherpaTtsDefinition(
      modelType: modelType,
      voicesFileName: voices,
      lexiconFileNames: lexiconNames,
      defaultSpeakers: speakers is Map
          ? {
              for (final entry in speakers.entries)
                if (entry.value is int)
                  entry.key.toString(): entry.value as int,
            }
          : const {},
      speakerCount: options['speakerCount'] is int
          ? options['speakerCount'] as int
          : null,
      modelId: manifest.resourceId,
      languageCodes: manifest.languageCodes,
      directoryName: manifest.directoryName,
      modelFileName: modelPath,
      tokensFileName: tokensPath,
      dataDirectoryName: _findTopLevelDirectory(manifest, 'espeak-ng-data'),
      lexiconFileName: _findManifestFilePath(
        manifest,
        (path) => p.basename(path) == 'lexicon.txt',
      ),
      dictDirectoryName: _findTopLevelDirectory(manifest, 'dict'),
      ruleFstsFileNames: manifest.files
          .map((file) => file.path)
          .where((path) => path.endsWith('.fst'))
          .toList(growable: false),
      ruleFarsFileName: _findManifestFilePath(
        manifest,
        (path) => path.endsWith('.far'),
      ),
      resourceManifest: manifest,
    );
  }

  _SherpaSpeakerEmbeddingDefinition? _speakerEmbeddingDefinitionFromManifest(
    OfflineResourceManifest manifest,
  ) {
    final modelPath =
        _safeManifestEntryFile(manifest) ??
        _findManifestFilePath(
          manifest,
          (path) => p.basename(path) == 'model.onnx',
        ) ??
        _findManifestFilePath(manifest, (path) => path.endsWith('.onnx'));
    if (modelPath == null) {
      return null;
    }
    final metadata = _speakerEmbeddingBindingOptions(manifest);
    return _SherpaSpeakerEmbeddingDefinition(
      modelId: manifest.resourceId,
      modelVersion: manifest.version,
      languageCodes: manifest.languageCodes,
      directoryName: manifest.directoryName,
      modelFileName: modelPath,
      sampleRate: _readIntOption(metadata['sampleRate'], fallback: 16000),
      embeddingDimension: _readIntOption(
        metadata['embeddingDimension'],
        fallback: 512,
      ),
      preprocessingVersion: _readStringOption(
        metadata['preprocessingVersion'],
        fallback: 'pcm16le_norm_v1',
      ),
      supportedPlatforms: _readStringSetOption(
        metadata['supportedPlatforms'],
        fallback: const {'android', 'ios', 'macos', 'windows', 'linux'},
      ),
      resourceManifest: manifest,
    );
  }

  Map<String, Object?> _speakerEmbeddingBindingOptions(
    OfflineResourceManifest manifest,
  ) {
    for (final binding in manifest.runtimeBindings) {
      if (binding.kind ==
          OfflineResourceRuntimeBindingKind.speechSpeakerEmbedding) {
        return binding.options;
      }
    }
    return const <String, Object?>{};
  }

  int _readIntOption(Object? value, {required int fallback}) {
    final direct = value;
    if (direct is int && direct > 0) {
      return direct;
    }
    if (direct is num && direct > 0) {
      return direct.toInt();
    }
    final parsed = int.tryParse(direct?.toString() ?? '');
    if (parsed != null && parsed > 0) {
      return parsed;
    }
    return fallback;
  }

  String _readStringOption(Object? value, {required String fallback}) {
    final normalized = value?.toString().trim();
    if (normalized == null || normalized.isEmpty) {
      return fallback;
    }
    return normalized;
  }

  Set<String> _readStringSetOption(
    Object? value, {
    required Set<String> fallback,
  }) {
    if (value is! List) {
      return fallback;
    }
    final normalized = value
        .map((item) => item.toString().trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet();
    if (normalized.isEmpty) {
      return fallback;
    }
    return normalized;
  }

  String? _findManifestFilePath(
    OfflineResourceManifest manifest,
    bool Function(String path) test,
  ) {
    for (final file in manifest.files) {
      if (test(file.path)) {
        return file.path;
      }
    }
    return null;
  }

  String? _findTopLevelDirectory(
    OfflineResourceManifest manifest,
    String directoryName,
  ) {
    for (final file in manifest.files) {
      final parts = file.path.split('/');
      if (parts.isNotEmpty && parts.first == directoryName) {
        return directoryName;
      }
    }
    return null;
  }

  String? _safeManifestEntryFile(OfflineResourceManifest manifest) {
    final entryFile = manifest.entryFile;
    if (entryFile == null) {
      return null;
    }
    if (manifest.files.any((file) => file.path == entryFile)) {
      return entryFile;
    }
    return null;
  }

  Future<Set<String>> listInstalledTtsLanguages() async {
    final statuses = await listTtsModels();
    final languages = <String>{};
    for (final status in statuses) {
      if (status.isInstalled) {
        languages.addAll(status.languageCodes);
      }
    }
    return languages;
  }
}

class _SherpaWhisperDefinition {
  const _SherpaWhisperDefinition({
    required this.modelId,
    required this.languageCodes,
    required this.directoryName,
    required this.encoderFileName,
    required this.decoderFileName,
    required this.tokensFileName,
    this.resourceManifest,
  });

  final String modelId;
  final Set<String> languageCodes;
  final String directoryName;
  final String encoderFileName;
  final String decoderFileName;
  final String tokensFileName;
  final OfflineResourceManifest? resourceManifest;

  Future<SherpaWhisperModelStatus> resolve(
    Directory applicationSupportDirectory,
  ) async {
    final directoryPath = p.join(
      applicationSupportDirectory.path,
      'sherpa_onnx',
      directoryName,
    );
    final requiredFilePaths = [
      p.join(directoryPath, encoderFileName),
      p.join(directoryPath, decoderFileName),
      p.join(directoryPath, tokensFileName),
    ];
    final availability = await _collectFileAvailability(
      directoryPath: directoryPath,
      requiredFilePaths: requiredFilePaths,
      resourceManifest: resourceManifest,
    );

    return SherpaWhisperModelStatus(
      modelId: modelId,
      languageCodes: languageCodes,
      directoryPath: directoryPath,
      requiredPaths: requiredFilePaths,
      missingPaths: availability.missingPaths,
      invalidPaths: availability.invalidPaths,
      resourceManifest: resourceManifest,
      config: availability.isReady
          ? SherpaWhisperModelConfig(
              modelId: modelId,
              languageCodes: languageCodes,
              encoderPath: requiredFilePaths[0],
              decoderPath: requiredFilePaths[1],
              tokensPath: requiredFilePaths[2],
            )
          : null,
    );
  }
}

class _SherpaTtsDefinition {
  const _SherpaTtsDefinition({
    required this.modelId,
    this.modelType = 'vits',
    this.voicesFileName,
    this.lexiconFileNames = const [],
    this.defaultSpeakers = const {},
    this.speakerCount,
    required this.languageCodes,
    required this.directoryName,
    required this.modelFileName,
    required this.tokensFileName,
    this.dataDirectoryName,
    this.lexiconFileName,
    this.dictDirectoryName,
    this.ruleFstsFileNames = const [],
    this.ruleFarsFileName,
    this.resourceManifest,
  });

  final String modelType;
  final String? voicesFileName;
  final List<String> lexiconFileNames;
  final Map<String, int> defaultSpeakers;
  final int? speakerCount;
  final String modelId;
  final Set<String> languageCodes;
  final String directoryName;
  final String modelFileName;
  final String tokensFileName;
  final String? dataDirectoryName;
  final String? lexiconFileName;
  final String? dictDirectoryName;
  final List<String> ruleFstsFileNames;
  final String? ruleFarsFileName;
  final OfflineResourceManifest? resourceManifest;

  Future<SherpaTtsModelStatus> resolve(
    Directory applicationSupportDirectory,
  ) async {
    final directoryPath = p.join(
      applicationSupportDirectory.path,
      'sherpa_onnx',
      directoryName,
    );
    final requiredFilePaths = <String>[
      p.join(directoryPath, modelFileName),
      p.join(directoryPath, tokensFileName),
    ];
    if (voicesFileName != null) {
      requiredFilePaths.add(p.join(directoryPath, voicesFileName!));
    }
    requiredFilePaths.addAll(
      lexiconFileNames.map((name) => p.join(directoryPath, name)),
    );
    final requiredDirectoryPaths = <String>[];

    if (dataDirectoryName != null) {
      requiredDirectoryPaths.add(p.join(directoryPath, dataDirectoryName!));
    }
    if (lexiconFileName != null) {
      requiredFilePaths.add(p.join(directoryPath, lexiconFileName!));
    }
    if (dictDirectoryName != null) {
      requiredDirectoryPaths.add(p.join(directoryPath, dictDirectoryName!));
    }
    for (final fileName in ruleFstsFileNames) {
      requiredFilePaths.add(p.join(directoryPath, fileName));
    }
    if (ruleFarsFileName != null) {
      requiredFilePaths.add(p.join(directoryPath, ruleFarsFileName!));
    }

    final availability = await _collectFileAvailability(
      directoryPath: directoryPath,
      requiredFilePaths: requiredFilePaths,
      requiredDirectoryPaths: requiredDirectoryPaths,
      resourceManifest: resourceManifest,
    );
    final outputDirPath = p.join(
      applicationSupportDirectory.path,
      'sherpa_onnx',
      'generated_audio',
    );

    return SherpaTtsModelStatus(
      modelId: modelId,
      languageCodes: languageCodes,
      directoryPath: directoryPath,
      requiredPaths: [...requiredFilePaths, ...requiredDirectoryPaths],
      missingPaths: availability.missingPaths,
      invalidPaths: availability.invalidPaths,
      resourceManifest: resourceManifest,
      config: availability.isReady
          ? SherpaTtsModelConfig(
              modelType: modelType,
              voicesPath: voicesFileName == null
                  ? ''
                  : p.join(directoryPath, voicesFileName!),
              defaultSpeakers: defaultSpeakers,
              speakerCount: speakerCount,
              modelId: modelId,
              languageCodes: languageCodes,
              modelPath: p.join(directoryPath, modelFileName),
              tokensPath: p.join(directoryPath, tokensFileName),
              outputDirPath: outputDirPath,
              dataDirPath: dataDirectoryName == null
                  ? ''
                  : p.join(directoryPath, dataDirectoryName!),
              lexiconPath: lexiconFileNames.isNotEmpty
                  ? lexiconFileNames
                        .map((name) => p.join(directoryPath, name))
                        .join(',')
                  : lexiconFileName == null
                  ? ''
                  : p.join(directoryPath, lexiconFileName!),
              dictDirPath: dictDirectoryName == null
                  ? ''
                  : p.join(directoryPath, dictDirectoryName!),
              ruleFsts: ruleFstsFileNames
                  .map((name) => p.join(directoryPath, name))
                  .join(','),
              ruleFars: ruleFarsFileName == null
                  ? ''
                  : p.join(directoryPath, ruleFarsFileName!),
            )
          : null,
    );
  }
}

class _SherpaSpeakerEmbeddingDefinition {
  const _SherpaSpeakerEmbeddingDefinition({
    required this.modelId,
    required this.modelVersion,
    required this.languageCodes,
    required this.directoryName,
    required this.modelFileName,
    required this.sampleRate,
    required this.embeddingDimension,
    required this.preprocessingVersion,
    required this.supportedPlatforms,
    this.resourceManifest,
  });

  final String modelId;
  final String modelVersion;
  final Set<String> languageCodes;
  final String directoryName;
  final String modelFileName;
  final int sampleRate;
  final int embeddingDimension;
  final String preprocessingVersion;
  final Set<String> supportedPlatforms;
  final OfflineResourceManifest? resourceManifest;

  Future<SherpaSpeakerEmbeddingModelStatus> resolve(
    Directory applicationSupportDirectory,
  ) async {
    final currentPlatform = _currentRuntimePlatformName();
    final platformSupported = supportedPlatforms.contains(currentPlatform);
    final directoryPath = p.join(
      applicationSupportDirectory.path,
      'sherpa_onnx',
      directoryName,
    );
    final requiredFilePaths = <String>[p.join(directoryPath, modelFileName)];
    final availability = await _collectFileAvailability(
      directoryPath: directoryPath,
      requiredFilePaths: requiredFilePaths,
      resourceManifest: resourceManifest,
    );
    return SherpaSpeakerEmbeddingModelStatus(
      modelId: modelId,
      languageCodes: languageCodes,
      directoryPath: directoryPath,
      requiredPaths: requiredFilePaths,
      missingPaths: availability.missingPaths,
      invalidPaths: availability.invalidPaths,
      resourceManifest: resourceManifest,
      platformSupported: platformSupported,
      supportedPlatforms: supportedPlatforms,
      config: availability.isReady && platformSupported
          ? SherpaSpeakerEmbeddingModelConfig(
              modelId: modelId,
              modelVersion: modelVersion,
              languageCodes: languageCodes,
              modelPath: p.join(directoryPath, modelFileName),
              sampleRate: sampleRate,
              embeddingDimension: embeddingDimension,
              preprocessingVersion: preprocessingVersion,
              supportedPlatforms: supportedPlatforms,
            )
          : null,
    );
  }
}

class _SherpaFileAvailability {
  const _SherpaFileAvailability({
    required this.missingPaths,
    required this.invalidPaths,
  });

  final List<String> missingPaths;
  final List<String> invalidPaths;

  bool get isReady => missingPaths.isEmpty && invalidPaths.isEmpty;
}

String _currentRuntimePlatformName() {
  if (Platform.isAndroid) {
    return 'android';
  }
  if (Platform.isIOS) {
    return 'ios';
  }
  if (Platform.isMacOS) {
    return 'macos';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  if (Platform.isLinux) {
    return 'linux';
  }
  return 'unknown';
}

Future<_SherpaFileAvailability> _collectFileAvailability({
  required String directoryPath,
  required List<String> requiredFilePaths,
  List<String> requiredDirectoryPaths = const [],
  required OfflineResourceManifest? resourceManifest,
}) async {
  final missingPaths = <String>[];
  final invalidPaths = <String>[];
  void addMissingPath(String path) {
    if (!missingPaths.contains(path)) {
      missingPaths.add(path);
    }
  }

  void addInvalidPath(String path) {
    if (!invalidPaths.contains(path)) {
      invalidPaths.add(path);
    }
  }

  for (final path in requiredFilePaths) {
    final entityType = await _entityTypeOrNotFound(path);
    if (entityType == FileSystemEntityType.notFound) {
      addMissingPath(path);
    } else if (entityType != FileSystemEntityType.file) {
      addInvalidPath(path);
    }
  }
  for (final path in requiredDirectoryPaths) {
    final entityType = await _entityTypeOrNotFound(path);
    if (entityType == FileSystemEntityType.notFound) {
      addMissingPath(path);
    } else if (entityType != FileSystemEntityType.directory) {
      addInvalidPath(path);
    }
  }
  final manifest = resourceManifest;
  if (manifest != null) {
    for (final manifestFile in manifest.files) {
      final path = p.joinAll([directoryPath, ...manifestFile.path.split('/')]);
      final entityType = await _entityTypeOrNotFound(path);
      if (entityType == FileSystemEntityType.notFound) {
        addMissingPath(path);
        continue;
      }
      if (entityType != FileSystemEntityType.file) {
        addInvalidPath(path);
        continue;
      }
      final file = File(path);
      final stat = await _statOrNull(file);
      if (stat == null || stat.size != manifestFile.sizeBytes) {
        addInvalidPath(path);
        continue;
      }
      if (!await _sha256Matches(file, manifestFile.sha256)) {
        addInvalidPath(path);
      }
    }
  }
  return _SherpaFileAvailability(
    missingPaths: List.unmodifiable(missingPaths),
    invalidPaths: List.unmodifiable(invalidPaths),
  );
}

bool _isSpeechRuntimeKind(OfflineResourceKind kind) {
  return switch (kind) {
    OfflineResourceKind.speechAsr ||
    OfflineResourceKind.speechTts ||
    OfflineResourceKind.speechSpeakerEmbedding ||
    OfflineResourceKind.speechLanguageIdentification => true,
    OfflineResourceKind.ocr || OfflineResourceKind.translation => false,
  };
}

Future<bool> _sha256Matches(File file, String expectedSha256) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString() == expectedSha256.toLowerCase();
}

Future<FileSystemEntityType> _entityTypeOrNotFound(String path) async {
  try {
    return await FileSystemEntity.type(path, followLinks: false);
  } on FileSystemException {
    return FileSystemEntityType.notFound;
  }
}

Future<FileStat?> _statOrNull(FileSystemEntity entity) async {
  try {
    return await entity.stat();
  } on FileSystemException {
    return null;
  }
}
