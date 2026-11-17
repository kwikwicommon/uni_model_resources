import 'dart:io';

import 'package:uni_model_resources/src/offline_resource_models.dart';
import 'package:uni_model_resources/src/speech_model_manager.dart';

class SpeechResourceAdapter {
  SpeechResourceAdapter({SpeechModelManager? speechModelManager})
    : _speechModelManager = speechModelManager ?? SpeechModelManager();

  final SpeechModelManager _speechModelManager;

  Future<OfflineResourceStatus> inspectResource(
    OfflineResourceManifest manifest,
  ) async {
    final speechStatus = await _speechModelManager.inspectResourceManifest(
      manifest,
    );
    final files = speechStatus.files
        .map(
          (fileStatus) => OfflineResourceFileStatus(
            file: _findFileManifest(manifest, fileStatus.file.path),
            path: fileStatus.path,
            exists: fileStatus.exists,
            sizeMatches: fileStatus.sizeMatches,
            hashMatches: fileStatus.hashMatches,
          ),
        )
        .toList(growable: false);

    return OfflineResourceStatus(
      manifest: manifest,
      directoryPath: speechStatus.directoryPath,
      files: files,
    );
  }

  Future<void> installFromDirectory({
    required Directory sourceDirectory,
    required OfflineResourceManifest manifest,
  }) async {
    await _speechModelManager.importResourceDirectory(
      sourceDirectory: sourceDirectory,
      manifest: manifest,
      overwrite: true,
    );
    final speechManifest = _speechModelManager
        .speechManifestFromOfflineResource(manifest);
    await _speechModelManager.cleanupDeprecatedModels(speechManifest);
  }

  OfflineResourceFileManifest _findFileManifest(
    OfflineResourceManifest manifest,
    String pathValue,
  ) {
    return manifest.files.firstWhere((file) => file.path == pathValue);
  }
}
