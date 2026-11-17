import 'package:path/path.dart' as p;

import 'offline_resource_models.dart';
import 'speech_model_manager.dart';

/// Validated, explicitly bound Sherpa runtime files.
class SherpaRuntimeModel {
  SherpaRuntimeModel({required this.manifest, required this.handle}) {
    final bindings = manifest.runtimeBindings.where(
      (binding) => binding.kind.name == manifest.kind.name,
    );
    if (bindings.length != 1) {
      throw FormatException(
        'Resource ${manifest.resourceId} needs one speech runtime binding.',
      );
    }
    options = bindings.single.options;
    if (!const {
      'whisper',
      'senseVoice',
      'zipformer',
      'vits',
      'kokoro',
      'kitten',
    }.contains(modelType)) {
      throw FormatException('Unsupported Sherpa model type: $modelType');
    }
    final isAsr = const {
      'whisper',
      'senseVoice',
      'zipformer',
    }.contains(modelType);
    if ((isAsr && manifest.kind != OfflineResourceKind.speechAsr) ||
        (!isAsr && manifest.kind != OfflineResourceKind.speechTts)) {
      throw const FormatException(
        'Sherpa model type does not match resource kind.',
      );
    }
    for (final key in switch (modelType) {
      'whisper' => ['encoder', 'decoder', 'tokens'],
      'zipformer' => ['encoder', 'decoder', 'joiner', 'tokens'],
      'kokoro' || 'kitten' => ['model', 'tokens', 'voices'],
      _ => ['model', 'tokens'],
    }) {
      file(key);
    }
    directory('dataDir');
    directory('dictDir');
    fileList('lexicons');
    fileList('ruleFsts');
    fileList('ruleFars');
  }

  final OfflineResourceManifest manifest;
  final SpeechModelHandle handle;
  late final Map<String, Object?> options;
  String get modelType => options['modelType']?.toString() ?? '';
  bool get isStreaming => modelType == 'zipformer';

  String file(String key, {bool optional = false}) {
    final value = options[key];
    if (optional && value == null) return '';
    if (value is! String || !handle.files.containsKey(value)) {
      throw FormatException(
        'Resource ${manifest.resourceId} has an invalid $key file binding.',
      );
    }
    return handle.files[value]!;
  }

  String directory(String key) {
    final value = options[key];
    if (value == null) return '';
    if (value is! String ||
        value.isEmpty ||
        p.isAbsolute(value) ||
        value.contains(r'\') ||
        value
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        !handle.files.keys.any((path) => path.startsWith('$value/'))) {
      throw FormatException(
        'Resource ${manifest.resourceId} has an invalid $key directory binding.',
      );
    }
    return p.joinAll([handle.directoryPath, ...value.split('/')]);
  }

  String fileList(String key) {
    final values = options[key];
    if (values == null) return '';
    if (values is! List ||
        values.any(
          (value) => value is! String || !handle.files.containsKey(value),
        )) {
      throw FormatException(
        'Resource ${manifest.resourceId} has an invalid $key file list.',
      );
    }
    return values.map((value) => handle.files[value]!).join(',');
  }

  void requireLanguage(String locale) {
    final language = locale
        .trim()
        .replaceAll('_', '-')
        .toLowerCase()
        .split('-')
        .first;
    if (language == 'auto' ||
        language.isEmpty ||
        manifest.languageCodes.contains('multi')) {
      return;
    }
    if (!manifest.languageCodes.contains(language)) {
      throw UnsupportedError('${manifest.title} does not support $locale.');
    }
  }

  int speakerId(String locale, String? voiceId) {
    requireLanguage(locale);
    final defaults = options['defaultSpeakers'];
    final language = locale
        .trim()
        .replaceAll('_', '-')
        .toLowerCase()
        .split('-')
        .first;
    final count = options['speakerCount'];
    final supplied = voiceId?.trim();
    final int? id;
    if (supplied != null && supplied.isNotEmpty && supplied != 'default') {
      id = int.tryParse(supplied);
    } else {
      final value = defaults is Map ? defaults[language] : null;
      id = value is int ? value : 0;
    }
    if (id == null || id < 0 || (count is int && id >= count)) {
      throw ArgumentError.value(
        voiceId,
        'voiceId',
        'Invalid speaker ID for ${manifest.title}.',
      );
    }
    return id;
  }
}
