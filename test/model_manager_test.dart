import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:uni_model_resources/uni_model_resources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory supportDirectory;
  late Directory tempDirectory;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'transli-offline-resource-test',
    );
    supportDirectory = Directory(path.join(root.path, 'support'))
      ..createSync(recursive: true);
    tempDirectory = Directory(path.join(root.path, 'temp'))
      ..createSync(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'manager listeners and App projection share one job lifecycle',
    () async {
      final body = Uint8List.fromList(utf8.encode('expected'));
      final phases = <OfflineResourceInstallPhase>[];
      final projected = <OfflineResourceInstallPhase>[];
      final manager = ModelManager(
        dio: Dio()
          ..httpClientAdapter = _RedirectingHttpClientAdapter(
            finalUri: Uri.parse('https://cdn.hf.co/model.bin'),
            body: body,
          ),
        applicationSupportDirectoryProvider: () async => supportDirectory,
        temporaryDirectoryProvider: () async => tempDirectory,
        onJobChanged: (job) => projected.add(job.phase),
      );
      final manifest = _manifest(
        'listener-test',
        url: Uri.parse('https://huggingface.co/model.bin'),
      );
      manager.addJobListener(
        manifest.resourceId,
        (job) => phases.add(job.phase),
      );
      await manager.install(manifest);
      expect(
        phases,
        containsAllInOrder([
          OfflineResourceInstallPhase.queued,
          OfflineResourceInstallPhase.downloading,
          OfflineResourceInstallPhase.validating,
          OfflineResourceInstallPhase.installing,
          OfflineResourceInstallPhase.completed,
        ]),
      );
      expect(projected, phases);
      expect(manager.activeJobFor(manifest.resourceId), isNull);
      expect(
        manager.lastJobFor(manifest.resourceId)?.phase,
        OfflineResourceInstallPhase.completed,
      );
    },
  );

  test(
    'persistent resource storage retains successive updates across reopen',
    () async {
      final file = File(path.join(root.path, 'state.json'));
      final storage = await FileResourceStorage.open(file);
      await Future.wait([
        storage.write('first', 'one'),
        storage.write('second', 'two'),
      ]);
      await storage.write('first', 'updated');
      final restored = await FileResourceStorage.open(file);
      expect(restored.read('first'), 'updated');
      expect(restored.read('second'), 'two');
    },
  );

  for (final ignoreRange in [false, true]) {
    test(
      'resumes after restart when server ${ignoreRange ? 'ignores' : 'supports'} Range',
      () async {
        final adapter = _ResumeHttpClientAdapter(ignoreRange: ignoreRange);
        final storage = MemoryResourceStorage();
        ModelManager createManager() => ModelManager(
          storage: storage,
          dio: Dio()..httpClientAdapter = adapter,
          applicationSupportDirectoryProvider: () async => supportDirectory,
          temporaryDirectoryProvider: () async => tempDirectory,
        );
        final manifest = _manifest(
          'resumable',
          url: Uri.parse(
            'https://github.com/example/releases/download/v1/model.bin',
          ),
        );
        await expectLater(
          createManager().install(manifest),
          throwsA(isA<OfflineResourceServiceException>()),
        );
        await Future<void>.delayed(Duration.zero);
        final restored = createManager();
        final status = await restored.install(manifest);
        expect(status.isInstalled, isTrue);
        expect(adapter.range, 'bytes=4-');
        expect(
          await File(
            path.join(status.directoryPath, 'model.bin'),
          ).readAsString(),
          'expected',
        );
      },
    );
  }

  test('downloads resources redirected to the Hugging Face CDN', () async {
    final body = Uint8List.fromList(utf8.encode('expected'));
    final dio = Dio()
      ..httpClientAdapter = _RedirectingHttpClientAdapter(
        finalUri: Uri.parse('https://us.aws.cdn.hf.co/model.bin'),
        body: body,
      );
    final service = _service(
      dio: dio,
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );
    final manifest = OfflineResourceManifest(
      resourceId: 'huggingface-redirect',
      kind: OfflineResourceKind.translation,
      title: 'Hugging Face redirect',
      version: '1.0.0',
      directoryName: 'huggingface-redirect',
      languageCodes: const {'en'},
      files: [
        OfflineResourceFileManifest(
          path: 'model.bin',
          sizeBytes: body.length,
          sha256: _sha256Text('expected'),
          url: Uri.parse(
            'https://huggingface.co/example/model/resolve/main/model.bin',
          ),
        ),
      ],
    );

    final status = await service.installResource(manifest);

    expect(status.isInstalled, isTrue);
    expect(
      await File(path.join(status.directoryPath, 'model.bin')).readAsString(),
      'expected',
    );
  });

  for (final redirects in [
    ['/api/resolve-cache/models/example/model.bin?etag=verified'],
    ['../../../api/resolve-cache/models/example/model.bin'],
    ['https://cdn.hf.co/cache/models/current', '../model.bin'],
  ]) {
    test(
      'downloads Hugging Face files with relative redirects $redirects',
      () async {
        final adapter = _HostAwareHttpClientAdapter({
          'hf-mirror.com': _RedirectingHttpClientAdapter(
            finalUri: Uri.parse(redirects.last),
            redirectLocations: redirects.map(Uri.parse).toList(),
            body: Uint8List.fromList(utf8.encode('expected')),
          ),
        });
        final manager = ModelManager(
          dio: Dio()..httpClientAdapter = adapter,
          applicationSupportDirectoryProvider: () async => supportDirectory,
          temporaryDirectoryProvider: () async => tempDirectory,
        );
        final manifest = _manifest(
          'relative-redirect',
          url: Uri.parse(
            'https://huggingface.co/example/model/resolve/main/model.bin',
          ),
        );

        final status = await manager.install(manifest);

        expect(status.isInstalled, isTrue);
        expect(
          await File(
            path.join(status.directoryPath, 'model.bin'),
          ).readAsString(),
          'expected',
        );
      },
    );
  }

  for (final redirects in [
    ['https://evil.example/cache/current', '../model.bin'],
    ['//evil.example/model.bin'],
    ['http://hf-mirror.com/model.bin'],
  ]) {
    test('rejects untrusted relative redirect chains $redirects', () async {
      final manager = ModelManager(
        dio: Dio()
          ..httpClientAdapter = _RedirectingHttpClientAdapter(
            finalUri: Uri.parse(redirects.last),
            redirectLocations: redirects.map(Uri.parse).toList(),
            body: Uint8List.fromList(utf8.encode('expected')),
          ),
        applicationSupportDirectoryProvider: () async => supportDirectory,
        temporaryDirectoryProvider: () async => tempDirectory,
      );

      await expectLater(
        manager.install(
          _manifest(
            'untrusted-relative-redirect',
            url: Uri.parse('https://huggingface.co/example/model.bin'),
          ),
        ),
        throwsA(
          isA<OfflineResourceServiceException>().having(
            (error) => error.failure.code,
            'code',
            'offline_resource_untrustedRedirect',
          ),
        ),
      );
    });
  }

  test('downloads Hugging Face files from a trusted mirror host', () async {
    final body = Uint8List.fromList(utf8.encode('mirrored'));
    final dio = Dio()
      ..httpClientAdapter = _HostAwareHttpClientAdapter({
        'hf-mirror.com': _RedirectingHttpClientAdapter(
          finalUri: Uri.parse('https://cdn.hf-mirror.com/example/model.bin'),
          body: body,
        ),
      });
    final storage = _MemoryStringStorage();
    await storage.write(
      ModelManager.huggingFaceMirrorStorageKey,
      'hf-mirror.com',
    );
    final service = _service(
      dio: dio,
      storage: storage,
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );
    final manifest = OfflineResourceManifest(
      resourceId: 'huggingface-mirror',
      kind: OfflineResourceKind.translation,
      title: 'Hugging Face mirror',
      version: '1.0.0',
      directoryName: 'huggingface-mirror',
      languageCodes: const {'en'},
      files: [
        OfflineResourceFileManifest(
          path: 'model.bin',
          sizeBytes: body.length,
          sha256: _sha256Text('mirrored'),
          url: Uri.parse(
            'https://huggingface.co/example/model/resolve/main/model.bin',
          ),
        ),
      ],
    );

    final status = await service.installResource(manifest);

    expect(status.isInstalled, isTrue);
    expect(
      await File(path.join(status.directoryPath, 'model.bin')).readAsString(),
      'mirrored',
    );
  });

  test('falls back to Hugging Face after a mirror network failure', () async {
    final body = Uint8List.fromList(utf8.encode('official'));
    final dio = Dio()
      ..httpClientAdapter = _HostAwareHttpClientAdapter({
        'hf-mirror.com': _FailingHttpClientAdapter(),
        'huggingface.co': _RedirectingHttpClientAdapter(
          finalUri: Uri.parse('https://us.aws.cdn.hf.co/model.bin'),
          body: body,
        ),
      });
    final storage = _MemoryStringStorage();
    await storage.write(
      ModelManager.huggingFaceMirrorStorageKey,
      'hf-mirror.com',
    );
    final service = _service(
      dio: dio,
      storage: storage,
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );
    final manifest = OfflineResourceManifest(
      resourceId: 'huggingface-fallback',
      kind: OfflineResourceKind.translation,
      title: 'Hugging Face fallback',
      version: '1.0.0',
      directoryName: 'huggingface-fallback',
      languageCodes: const {'en'},
      files: [
        OfflineResourceFileManifest(
          path: 'model.bin',
          sizeBytes: body.length,
          sha256: _sha256Text('official'),
          url: Uri.parse(
            'https://huggingface.co/example/model/resolve/main/model.bin',
          ),
        ),
      ],
    );

    final status = await service.installResource(manifest);
    expect(status.isInstalled, isTrue);
  });

  test(
    'rejects Hugging Face downloads redirected to an untrusted host',
    () async {
      final body = Uint8List.fromList(utf8.encode('evil'));
      final dio = Dio()
        ..httpClientAdapter = _RedirectingHttpClientAdapter(
          finalUri: Uri.parse('https://evil.example/model.bin'),
          body: body,
        );
      final storage = _MemoryStringStorage();
      await storage.write(
        ModelManager.huggingFaceMirrorStorageKey,
        OfflineResourceDownloadMirrors.disabledSentinel,
      );
      final service = _service(
        dio: dio,
        storage: storage,
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,
      );
      final manifest = OfflineResourceManifest(
        resourceId: 'huggingface-untrusted',
        kind: OfflineResourceKind.translation,
        title: 'Untrusted redirect',
        version: '1.0.0',
        directoryName: 'huggingface-untrusted',
        languageCodes: const {'en'},
        files: [
          OfflineResourceFileManifest(
            path: 'model.bin',
            sizeBytes: body.length,
            sha256: _sha256Text('evil'),
            url: Uri.parse(
              'https://huggingface.co/example/model/resolve/main/model.bin',
            ),
          ),
        ],
      );

      await expectLater(
        service.installResource(manifest),
        throwsA(
          isA<OfflineResourceServiceException>().having(
            (error) => error.failure.code,
            'code',
            'offline_resource_untrustedRedirect',
          ),
        ),
      );
    },
  );

  test('downloads GitHub release assets after the CDN redirect', () async {
    final body = Uint8List.fromList(utf8.encode('github-asset'));
    final dio = Dio()
      ..httpClientAdapter = _RedirectingHttpClientAdapter(
        finalUri: Uri.parse(
          'https://release-assets.githubusercontent.com/github-production-release-asset/model.bin',
        ),
        body: body,
      );
    final service = _service(
      dio: dio,
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );
    final manifest = OfflineResourceManifest(
      resourceId: 'github-redirect',
      kind: OfflineResourceKind.translation,
      title: 'GitHub release asset',
      version: '1.0.0',
      directoryName: 'github-redirect',
      languageCodes: const {'multi'},
      files: [
        OfflineResourceFileManifest(
          path: 'model.bin',
          sizeBytes: body.length,
          sha256: _sha256Text('github-asset'),
          url: Uri.parse(
            'https://github.com/example/repo/releases/download/v1/model.bin',
          ),
        ),
      ],
    );

    final status = await service.installResource(manifest);

    expect(status.isInstalled, isTrue);
    expect(
      await File(path.join(status.directoryPath, 'model.bin')).readAsString(),
      'github-asset',
    );
  });

  test(
    'classifies Windows path and permission failures during install setup',
    () async {
      final service = _service(
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async {
          throw const FileSystemException(
            'The filename or extension is too long.',
            r'C:\very\long\resource\path',
            OSError('The filename or extension is too long.', 206),
          );
        },
      );

      await expectLater(
        service.installResource(_manifest('path-too-long')),
        throwsA(
          isA<OfflineResourceServiceException>().having(
            (error) => error.failure.code,
            'code',
            'offline_resource_pathTooLong',
          ),
        ),
      );

      final permissionService = _service(
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async {
          throw const FileSystemException(
            'Access is denied.',
            r'C:\Users\Transli\AppData\Local\Transli',
            OSError('Access is denied.', 5),
          );
        },
      );
      await expectLater(
        permissionService.installResource(_manifest('permission-denied')),
        throwsA(
          isA<OfflineResourceServiceException>().having(
            (error) => error.failure.code,
            'code',
            'offline_resource_permissionDenied',
          ),
        ),
      );
    },
  );

  test('classifies file lock competition during install setup', () async {
    final service = _service(
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async {
        throw const FileSystemException(
          'The process cannot access the file because it is being used by another process.',
          r'C:\Users\Transli\AppData\Local\Temp',
          OSError(
            'The process cannot access the file because it is being used by another process.',
            32,
          ),
        );
      },
    );

    await expectLater(
      service.installResource(_manifest('locked-temp')),
      throwsA(
        isA<OfflineResourceServiceException>().having(
          (error) => error.failure.code,
          'code',
          'offline_resource_fileInUse',
        ),
      ),
    );
  });

  test('rejects resources that are unsupported on this platform', () async {
    final service = _service(
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );
    final manifest = OfflineResourceManifest(
      resourceId: 'unsupported-platform',
      kind: OfflineResourceKind.translation,
      title: 'Unsupported',
      version: '1.0.0',
      directoryName: 'unsupported-platform',
      languageCodes: const {'en'},
      supportedPlatforms: const {'haiku'},
      files: [
        OfflineResourceFileManifest(
          path: 'model.bin',
          sizeBytes: 8,
          sha256: _sha256Text('expected'),
          url: Uri.parse('https://example.com/model.bin'),
        ),
      ],
    );

    await expectLater(
      service.installResource(manifest),
      throwsA(
        isA<OfflineResourceServiceException>().having(
          (error) => error.failure.code,
          'code',
          'offline_resource_unsupportedPlatform',
        ),
      ),
    );
  });

  test('reports missing files separately from checksum failures', () async {
    final sourceDirectory = Directory(path.join(root.path, 'source-missing'))
      ..createSync(recursive: true);
    final service = _service(
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );

    await expectLater(
      service.importResourceDirectory(
        sourceDirectory: sourceDirectory,
        manifest: _manifest('missing-files'),
      ),
      throwsA(
        isA<OfflineResourceServiceException>().having(
          (error) => error.failure.code,
          'code',
          'offline_resource_missingFiles',
        ),
      ),
    );
  });

  test('removed resources are not reported as installed', () async {
    final sourceDirectory = Directory(path.join(root.path, 'source-remove'))
      ..createSync(recursive: true);
    await File(
      path.join(sourceDirectory.path, 'model.bin'),
    ).writeAsString('expected');
    final manifest = _manifest('remove-me');
    final service = _service(
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );

    final installed = await service.importResourceDirectory(
      sourceDirectory: sourceDirectory,
      manifest: manifest,
    );
    expect(installed.isInstalled, isTrue);

    await service.removeResource(manifest);
    final inspected = await service.inspectResource(manifest);
    expect(inspected.isInstalled, isFalse);
  });

  test('reports large resource checksum failures after transfer', () async {
    final sourceDirectory = Directory(path.join(root.path, 'source'))
      ..createSync(recursive: true);
    await File(
      path.join(sourceDirectory.path, 'model.bin'),
    ).writeAsString('unexpected');
    final manifest = _manifest(
      'bad-checksum',
      expectedSha256: sha256.convert(utf8.encode('expected')).toString(),
    );
    final service = _service(
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );

    await expectLater(
      service.importResourceDirectory(
        sourceDirectory: sourceDirectory,
        manifest: manifest,
      ),
      throwsA(
        isA<OfflineResourceServiceException>().having(
          (error) => error.failure.code,
          'code',
          'offline_resource_verificationFailed',
        ),
      ),
    );
  });

  test('locks verify and remove while an install is in progress', () async {
    final hanging = Completer<ResponseBody>();
    final dio = Dio()..httpClientAdapter = _HangingHttpClientAdapter(hanging);
    final storage = _MemoryStringStorage();
    await storage.write(
      ModelManager.huggingFaceMirrorStorageKey,
      OfflineResourceDownloadMirrors.disabledSentinel,
    );
    final service = _service(
      dio: dio,
      storage: storage,
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );
    final manifest = OfflineResourceManifest(
      resourceId: 'locked-resource',
      kind: OfflineResourceKind.translation,
      title: 'Locked resource',
      version: '1.0.0',
      directoryName: 'locked-resource',
      languageCodes: const {'en'},
      files: [
        OfflineResourceFileManifest(
          path: 'model.bin',
          sizeBytes: 8,
          sha256: _sha256Text('expected'),
          url: Uri.parse('https://example.com/model.bin'),
        ),
      ],
    );

    final install = service.installResource(manifest);
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      service.verifyResource(manifest),
      throwsA(
        isA<OfflineResourceServiceException>().having(
          (error) => error.failure.code,
          'code',
          'offline_resource_installActive',
        ),
      ),
    );
    await expectLater(
      service.removeResource(manifest),
      throwsA(
        isA<OfflineResourceServiceException>().having(
          (error) => error.failure.code,
          'code',
          'offline_resource_installActive',
        ),
      ),
    );

    await service.cancelResourceInstall(manifest.resourceId);
    await expectLater(install, throwsA(isA<OfflineResourceServiceException>()));
  });

  test(
    'restores interrupted resource install jobs as resumable failures',
    () async {
      final storage = _MemoryStringStorage();
      final startedAt = DateTime.utc(2026, 1, 1, 8);
      await storage.write(
        ModelManager.installJobsStorageKey,
        jsonEncode([
          OfflineResourceInstallJob(
            jobId: 'interrupted-job',
            resourceId: 'interrupted-resource',
            kind: OfflineResourceKind.translation,
            phase: OfflineResourceInstallPhase.downloading,
            receivedBytes: 4,
            totalBytes: 8,
            sourceType: OfflineResourceSourceType.remote,
            startedAt: startedAt,
            resourceVersion: '1.0.0',
            downloadDirectoryPath: path.join(tempDirectory.path, 'download'),
            canResume: true,
          ).toJson(),
        ]),
      );
      final service = _service(
        storage: storage,
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,
      );

      final jobs = service.installJobs;

      expect(jobs.single.phase, OfflineResourceInstallPhase.failed);
      expect(jobs.single.canResume, isTrue);
      expect(jobs.single.message, contains('interrupted'));
    },
  );

  test(
    'records startup health suggestions for damaged installed directories',
    () async {
      final destination = Directory(
        path.join(
          supportDirectory.path,
          'offline_resources',
          'translation',
          'damaged',
        ),
      );
      await destination.create(recursive: true);
      await File(
        path.join(destination.path, 'model.bin'),
      ).writeAsString('unexpected');
      final catalog = OfflineResourceCatalogDocument(
        schemaVersion: 2,
        resources: [_manifest('damaged')],
      );
      final storage = _MemoryStringStorage();
      await storage.write(
        ModelManager.catalogCacheStorageKey,
        jsonEncode(catalog.toJson()),
      );
      final service = _service(
        storage: storage,
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,
      );

      final result = await service.checkInstalledResourceHealthOnStartup();

      expect(result['issueCount'], 1);
      final issues = result['issues'] as List<dynamic>;
      expect(issues.single['repairSuggestion'], contains('reinstall'));
    },
  );

  test('does not report damaged resources as updates', () {
    final manifest = _manifest('damaged-update');
    final status = OfflineResourceStatus(
      manifest: manifest,
      directoryPath: path.join(
        supportDirectory.path,
        'offline_resources',
        'translation',
        'damaged-update',
      ),
      files: [
        OfflineResourceFileStatus(
          file: manifest.files.single,
          path: path.join(
            supportDirectory.path,
            'offline_resources',
            'translation',
            'damaged-update',
            'model.bin',
          ),
          exists: true,
          sizeMatches: false,
          hashMatches: false,
        ),
      ],
      installedVersion: '0.9.0',
    );

    expect(status.isInstalled, isFalse);
    expect(status.hasUpdate, isFalse);
  });

  test(
    'rejects duplicate catalog file paths instead of silently dropping entries',
    () {
      final service = _service(
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,
      );

      expect(
        () => service.parseCatalogString(
          jsonEncode({
            'schemaVersion': 2,
            'resources': [
              {
                'resourceId': 'duplicate-files',
                'kind': 'translation',
                'version': '1.0.0',
                'directoryName': 'duplicate-files',
                'files': [
                  {
                    'path': 'model.bin',
                    'sizeBytes': 8,
                    'sha256': _sha256Text('expected'),
                  },
                  {
                    'path': 'model.bin',
                    'sizeBytes': 8,
                    'sha256': _sha256Text('expected'),
                  },
                ],
              },
            ],
          }),
        ),
        throwsA(
          isA<OfflineResourceServiceException>().having(
            (error) => error.failure.message,
            'message',
            contains('duplicate file path'),
          ),
        ),
      );
    },
  );

  test('rejects catalog resources that share one storage directory', () {
    final service = _service(
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );

    expect(
      () => service.parseCatalogString(
        jsonEncode({
          'schemaVersion': 2,
          'resources': [
            {
              'resourceId': 'translation-a',
              'kind': 'translation',
              'version': '1.0.0',
              'directoryName': 'shared',
              'files': [
                {
                  'path': 'model.bin',
                  'sizeBytes': 8,
                  'sha256': _sha256Text('expected'),
                },
              ],
            },
            {
              'resourceId': 'translation-b',
              'kind': 'translation',
              'version': '1.0.0',
              'directoryName': 'shared',
              'files': [
                {
                  'path': 'other.bin',
                  'sizeBytes': 8,
                  'sha256': _sha256Text('expected'),
                },
              ],
            },
          ],
        }),
      ),
      throwsA(
        isA<OfflineResourceServiceException>().having(
          (error) => error.failure.message,
          'message',
          contains('same storage directory'),
        ),
      ),
    );
  });

  test(
    'rejects merged catalog resources that share one storage directory',
    () async {
      const bundledCatalogAssetPath = 'test-offline-resource-catalog.json';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (message) async {
            final key = utf8.decode(message!.buffer.asUint8List());
            if (key != bundledCatalogAssetPath) {
              return null;
            }
            final bytes = Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'schemaVersion': 2,
                  'resources': [
                    {
                      'resourceId': 'bundled-translation',
                      'kind': 'translation',
                      'version': '1.0.0',
                      'directoryName': 'shared',
                      'files': [
                        {
                          'path': 'bundled.bin',
                          'sizeBytes': 8,
                          'sha256': _sha256Text('expected'),
                        },
                      ],
                    },
                  ],
                }),
              ),
            );
            return ByteData.sublistView(bytes);
          });

      final storage = _MemoryStringStorage();
      await storage.write(
        ModelManager.catalogCacheStorageKey,
        jsonEncode({
          'schemaVersion': 2,
          'resources': [
            {
              'resourceId': 'cached-translation',
              'kind': 'translation',
              'version': '1.0.0',
              'directoryName': 'shared',
              'files': [
                {
                  'path': 'cached.bin',
                  'sizeBytes': 8,
                  'sha256': _sha256Text('expected'),
                },
              ],
            },
          ],
        }),
      );
      final service = _service(
        storage: storage,
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,

        bundledCatalogAssetPath: bundledCatalogAssetPath,
        remoteCatalogAvailable: true,
      );

      try {
        await expectLater(
          service.loadLocalCatalog(),
          throwsA(
            isA<OfflineResourceServiceException>().having(
              (error) => error.failure.message,
              'message',
              contains('same storage directory'),
            ),
          ),
        );
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMessageHandler('flutter/assets', null);
      }
    },
  );

  test('release policy ignores cached remote catalogs', () async {
    final storage = _MemoryStringStorage();
    await storage.write(
      ModelManager.catalogCacheStorageKey,
      jsonEncode({
        'schemaVersion': 2,
        'resources': [
          {
            'resourceId': 'cached-translation',
            'kind': 'translation',
            'version': '1.0.0',
            'directoryName': 'cached-translation',
            'files': [
              {
                'path': 'model.bin',
                'sizeBytes': 8,
                'sha256': _sha256Text('expected'),
              },
            ],
          },
        ],
      }),
    );
    final service = _service(
      storage: storage,
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,

      remoteCatalogAvailable: false,
    );

    final catalog = await service.loadLocalCatalog();

    expect(catalog.resources, isEmpty);
    await expectLater(
      service.writeCatalogUrl('https://example.com/catalog.json'),
      throwsStateError,
    );
  });

  test(
    'rejects unsafe programmatic manifests before writing to disk',
    () async {
      final service = _service(
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,
      );
      final sourceDirectory = Directory(path.join(root.path, 'unsafe-source'))
        ..createSync(recursive: true);
      await File(
        path.join(sourceDirectory.path, 'model.bin'),
      ).writeAsString('expected');

      await expectLater(
        service.importResourceDirectory(
          sourceDirectory: sourceDirectory,
          manifest: OfflineResourceManifest(
            resourceId: 'unsafe',
            kind: OfflineResourceKind.translation,
            title: 'unsafe',
            version: '1.0.0',
            directoryName: 'unsafe',
            languageCodes: const {'en'},
            files: [
              OfflineResourceFileManifest(
                path: './model.bin',
                sizeBytes: 8,
                sha256: _sha256Text('expected'),
              ),
            ],
          ),
        ),
        throwsA(
          isA<OfflineResourceServiceException>()
              .having((error) => error.failure.code, 'code', isNull)
              .having(
                (error) => error.failure.type,
                'type',
                ResourceFailureType.validation,
              ),
        ),
      );
    },
  );

  test(
    'does not delete current generic resource when deprecated ids include the resource id',
    () async {
      final sourceDirectory = Directory(path.join(root.path, 'source-current'))
        ..createSync(recursive: true);
      await File(
        path.join(sourceDirectory.path, 'model.bin'),
      ).writeAsString('expected');
      final manifest = _manifest(
        'current',
        deprecatedResourceIds: const ['current'],
      );
      final service = _service(
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,
      );

      final status = await service.importResourceDirectory(
        sourceDirectory: sourceDirectory,
        manifest: manifest,
      );

      expect(status.isInstalled, isTrue);
      expect(await Directory(status.directoryPath).exists(), isTrue);
    },
  );

  test(
    'removes deprecated generic resources by installed resource id metadata',
    () async {
      final legacyDirectory = Directory(
        path.join(
          supportDirectory.path,
          'offline_resources',
          'translation',
          'legacy-dir',
        ),
      );
      await legacyDirectory.create(recursive: true);
      await File(
        path.join(legacyDirectory.path, 'model.bin'),
      ).writeAsString('legacy');
      await File(
        path.join(legacyDirectory.path, '.transli_resource.json'),
      ).writeAsString(
        jsonEncode({
          'resourceId': 'legacy-resource',
          'kind': OfflineResourceKind.translation.name,
          'version': '0.9.0',
        }),
      );

      final sourceDirectory = Directory(
        path.join(root.path, 'source-with-deprecated-id'),
      )..createSync(recursive: true);
      await File(
        path.join(sourceDirectory.path, 'model.bin'),
      ).writeAsString('expected');
      final manifest = _manifest(
        'replacement-resource',
        deprecatedResourceIds: const ['legacy-resource'],
      );
      final service = _service(
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,
      );

      final status = await service.importResourceDirectory(
        sourceDirectory: sourceDirectory,
        manifest: manifest,
      );

      expect(status.isInstalled, isTrue);
      expect(await legacyDirectory.exists(), isFalse);
    },
  );

  test(
    'removes expired resumable download artifacts while preserving fresh ones',
    () async {
      final downloadRoot = Directory(
        path.join(tempDirectory.path, 'offline_resource_downloads'),
      );
      final oldDownload = Directory(path.join(downloadRoot.path, 'old-job'));
      final freshDownload = Directory(
        path.join(downloadRoot.path, 'fresh-job'),
      );
      await oldDownload.create(recursive: true);
      await freshDownload.create(recursive: true);
      await File(
        path.join(oldDownload.path, 'model.bin'),
      ).writeAsString('partial');
      await File(
        path.join(freshDownload.path, 'model.bin'),
      ).writeAsString('partial');
      final now = DateTime.now().toUtc();

      final storage = _MemoryStringStorage();
      await storage.write(
        ModelManager.installJobsStorageKey,
        jsonEncode([
          OfflineResourceInstallJob(
            jobId: 'old-job',
            resourceId: 'old-resource',
            kind: OfflineResourceKind.translation,
            phase: OfflineResourceInstallPhase.failed,
            receivedBytes: 4,
            totalBytes: 8,
            sourceType: OfflineResourceSourceType.remote,
            startedAt: now.subtract(const Duration(days: 3)),
            updatedAt: now.subtract(const Duration(days: 3)),
            downloadDirectoryPath: oldDownload.path,
            canResume: true,
          ).toJson(),
          OfflineResourceInstallJob(
            jobId: 'fresh-job',
            resourceId: 'fresh-resource',
            kind: OfflineResourceKind.translation,
            phase: OfflineResourceInstallPhase.failed,
            receivedBytes: 4,
            totalBytes: 8,
            sourceType: OfflineResourceSourceType.remote,
            startedAt: now.subtract(const Duration(hours: 2)),
            updatedAt: now.add(const Duration(hours: 2)),
            downloadDirectoryPath: freshDownload.path,
            canResume: true,
          ).toJson(),
        ]),
      );
      final service = _service(
        storage: storage,
        supportDirectory: supportDirectory,
        tempDirectoryProvider: () async => tempDirectory,

        now: () => now,
      );

      final removedCount = await service.cleanupStaleInstallArtifacts(
        maxAge: const Duration(days: 1),
      );

      expect(removedCount, 1);
      expect(await oldDownload.exists(), isFalse);
      expect(await freshDownload.exists(), isTrue);
    },
  );

  test('rejects importing from an installed resource directory', () async {
    final service = _service(
      supportDirectory: supportDirectory,
      tempDirectoryProvider: () async => tempDirectory,
    );
    final manifest = _manifest('overlapping-source');
    final destination = Directory(
      await service.resolveResourceDirectoryPath(manifest),
    );
    await destination.create(recursive: true);
    await File(
      path.join(destination.path, 'model.bin'),
    ).writeAsString('expected');

    await expectLater(
      service.importResourceDirectory(
        sourceDirectory: destination,
        manifest: manifest,
      ),
      throwsA(
        isA<OfflineResourceServiceException>().having(
          (error) => error.failure.code,
          'code',
          'offline_resource_overlappingPaths',
        ),
      ),
    );
  });
}

ModelManager _service({
  ResourceStringStorage? storage,
  Dio? dio,
  required Directory supportDirectory,
  required Future<Directory> Function() tempDirectoryProvider,
  String bundledCatalogAssetPath = 'missing-test-catalog.json',
  DateTime Function()? now,
  bool remoteCatalogAvailable = true,
}) {
  return ModelManager(
    storage: storage ?? _MemoryStringStorage(),
    dio: dio,
    applicationSupportDirectoryProvider: () async => supportDirectory,
    temporaryDirectoryProvider: tempDirectoryProvider,
    bundledCatalogAssetPath: bundledCatalogAssetPath,
    now: now,
    remoteCatalogAvailable: remoteCatalogAvailable,
  );
}

class _RedirectingHttpClientAdapter implements HttpClientAdapter {
  _RedirectingHttpClientAdapter({
    required this.finalUri,
    required this.body,
    this.redirectLocations,
  });

  final Uri finalUri;
  final Uint8List body;
  final List<Uri>? redirectLocations;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions requestOptions,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream<Uint8List>.value(body),
      HttpStatus.ok,
      redirects: [
        for (final location in redirectLocations ?? [finalUri])
          RedirectRecord(HttpStatus.found, requestOptions.method, location),
      ],
      headers: {
        Headers.contentLengthHeader: [body.length.toString()],
      },
    );
  }
}

class _HostAwareHttpClientAdapter implements HttpClientAdapter {
  _HostAwareHttpClientAdapter(this.byHost);

  final Map<String, HttpClientAdapter> byHost;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions requestOptions,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final adapter = byHost[requestOptions.uri.host];
    if (adapter == null) {
      throw DioException.connectionError(
        requestOptions: requestOptions,
        reason: 'No handler for ${requestOptions.uri.host}',
      );
    }
    return adapter.fetch(requestOptions, requestStream, cancelFuture);
  }
}

class _FailingHttpClientAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions requestOptions,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw DioException.connectionError(
      requestOptions: requestOptions,
      reason: 'mirror unavailable',
    );
  }
}

class _HangingHttpClientAdapter implements HttpClientAdapter {
  _HangingHttpClientAdapter(this.completer);

  final Completer<ResponseBody> completer;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions requestOptions,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    cancelFuture?.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: requestOptions,
            type: DioExceptionType.cancel,
          ),
        );
      }
    });
    return completer.future;
  }
}

OfflineResourceManifest _manifest(
  String resourceId, {
  String? expectedSha256,
  Uri? url,
  List<String> deprecatedResourceIds = const [],
}) {
  return OfflineResourceManifest(
    resourceId: resourceId,
    kind: OfflineResourceKind.translation,
    title: resourceId,
    version: '1.0.0',
    directoryName: resourceId == 'damaged' ? 'damaged' : resourceId,
    languageCodes: const {'en'},
    files: [
      OfflineResourceFileManifest(
        path: 'model.bin',
        sizeBytes: 8,
        sha256:
            expectedSha256 ??
            sha256.convert(utf8.encode('expected')).toString(),
        url: url ?? Uri.file('/missing/model.bin'),
      ),
    ],
    deprecatedResourceIds: deprecatedResourceIds,
  );
}

String _sha256Text(String value) {
  return sha256.convert(utf8.encode(value)).toString();
}

class _MemoryStringStorage implements ResourceStringStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  String? read(String key) => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

class _ResumeHttpClientAdapter implements HttpClientAdapter {
  _ResumeHttpClientAdapter({required this.ignoreRange});
  final bool ignoreRange;
  int calls = 0;
  Object? range;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    range = options.headers[HttpHeaders.rangeHeader];
    final first = calls == 1;
    final text = first
        ? 'expe'
        : ignoreRange
        ? 'expected'
        : 'cted';
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(text))),
      first || ignoreRange ? HttpStatus.ok : HttpStatus.partialContent,
      headers: {
        Headers.contentLengthHeader: [(first ? 8 : text.length).toString()],
        if (!first && !ignoreRange)
          HttpHeaders.contentRangeHeader: ['bytes 4-7/8'],
      },
    );
  }
}
