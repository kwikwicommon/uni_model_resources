import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uni_model_resources/uni_model_resources.dart';

void main() {
  test(
    'OfflineResourceCatalogModule merges resources by priority and version',
    () {
      const module = OfflineResourceCatalogModule();
      final bundled = OfflineResourceCatalogDocument(
        schemaVersion: 2,
        source: 'bundled',
        priority: 0,
        resources: [_manifest('core', version: '1.0.0')],
      );
      final remote = OfflineResourceCatalogDocument(
        schemaVersion: 2,
        source: 'remote',
        priority: 100,
        resources: [_manifest('core', version: '1.1.0')],
      );

      final merged = module.mergeCatalogs([bundled, remote]);

      expect(merged.resources.single.version, '1.1.0');
      expect(merged.conflicts.single.resourceId, 'core');
      expect(merged.conflicts.single.keptSource, 'remote');
    },
  );

  test('catalog rejects unsupported schema versions', () {
    const module = OfflineResourceCatalogModule();

    expect(
      () => module.parseCatalogString(
        jsonEncode({'schemaVersion': 1, 'resources': const []}),
      ),
      throwsA(isA<ResourceFailure>()),
    );
  });

  test('OfflineResourceCatalogModule rejects shared storage directories', () {
    const module = OfflineResourceCatalogModule();
    final first = OfflineResourceCatalogDocument(
      schemaVersion: 2,
      source: 'first',
      priority: 0,
      resources: [_manifest('first', directoryName: 'shared')],
    );
    final second = OfflineResourceCatalogDocument(
      schemaVersion: 2,
      source: 'second',
      priority: 0,
      resources: [_manifest('second', directoryName: 'shared')],
    );

    expect(
      () => module.mergeCatalogs([first, second]),
      throwsA(
        isA<ResourceFailure>().having(
          (failure) => failure.message,
          'message',
          contains('same storage directory'),
        ),
      ),
    );
  });

  test(
    'OfflineResourceCatalogModule verifies remote catalog signatures',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final module = OfflineResourceCatalogModule(
        trustPolicy: OfflineResourceCatalogTrustPolicy(
          allowedRemoteHosts: const {'example.com'},
          trustedEd25519PublicKeys: {
            'test-key': base64UrlEncode(publicKey.bytes),
          },
        ),
      );
      final payload = <String, Object?>{
        'schemaVersion': 2,
        'resources': [_manifest('signed').toJson()],
      };
      final signedCatalog = await _signedCatalog(payload, keyPair, algorithm);

      await module.verifyCatalogSignature(
        signedCatalog,
        Uri.parse('https://example.com/catalog.json'),
      );

      await expectLater(
        module.verifyCatalogSignature(
          jsonEncode(payload),
          Uri.parse('https://example.com/catalog.json'),
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );
}

OfflineResourceManifest _manifest(
  String resourceId, {
  String version = '1.0.0',
  String? directoryName,
}) {
  return OfflineResourceManifest(
    resourceId: resourceId,
    kind: OfflineResourceKind.translation,
    title: resourceId,
    version: version,
    directoryName: directoryName ?? resourceId,
    languageCodes: const {'en'},
    files: [
      OfflineResourceFileManifest(
        path: 'model.bin',
        sizeBytes: 8,
        sha256: _sha256Text('expected'),
      ),
    ],
  );
}

Future<String> _signedCatalog(
  Map<String, Object?> payload,
  KeyPair keyPair,
  SignatureAlgorithm algorithm,
) async {
  final signature = await algorithm.sign(
    utf8.encode(_canonicalJson(payload)),
    keyPair: keyPair,
  );
  return jsonEncode({
    ...payload,
    'signature': {
      'algorithm': 'ed25519',
      'keyId': 'test-key',
      'value': base64UrlEncode(signature.bytes),
    },
  });
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return jsonEncode({
      for (final key in keys) key: _canonicalJsonValue(value[key]),
    });
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

String _sha256Text(String value) {
  return sha256.convert(utf8.encode(value)).toString();
}
