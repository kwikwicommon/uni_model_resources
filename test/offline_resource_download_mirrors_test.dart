import 'package:flutter_test/flutter_test.dart';
import 'package:uni_model_resources/uni_model_resources.dart';

void main() {
  test('rewrites official Hugging Face hosts onto the default mirror', () {
    const mirrors = OfflineResourceDownloadMirrors();
    final source = Uri.parse(
      'https://huggingface.co/example/model/resolve/main/model.bin',
    );

    expect(mirrors.effectiveMirrorHost, 'hf-mirror.com');
    expect(
      mirrors.rewriteHuggingFaceUri(source),
      Uri.parse('https://hf-mirror.com/example/model/resolve/main/model.bin'),
    );
    expect(mirrors.downloadUris(source), [
      Uri.parse('https://hf-mirror.com/example/model/resolve/main/model.bin'),
      source,
    ]);
  });

  test('trusts Hugging Face, hf.co CDN, and configured mirror redirects', () {
    const mirrors = OfflineResourceDownloadMirrors(
      configuredHost: 'models.example.com',
    );
    final source = Uri.parse(
      'https://huggingface.co/example/model/resolve/main/model.bin',
    );

    expect(
      mirrors.isTrustedRedirect(
        source,
        Uri.parse('https://us.aws.cdn.hf.co/model.bin'),
      ),
      isTrue,
    );
    expect(
      mirrors.isTrustedRedirect(
        source,
        Uri.parse('https://hf-mirror.com/example/model/resolve/main/model.bin'),
      ),
      isTrue,
    );
    expect(
      mirrors.isTrustedRedirect(
        Uri.parse('https://models.example.com/model.bin'),
        Uri.parse('https://cdn.models.example.com/model.bin'),
      ),
      isTrue,
    );
    expect(
      mirrors.isTrustedRedirect(
        source,
        Uri.parse('https://evil.example/model.bin'),
      ),
      isFalse,
    );
  });

  test('disables rewriting when the stored host is off', () {
    const mirrors = OfflineResourceDownloadMirrors(configuredHost: 'off');
    final source = Uri.parse(
      'https://huggingface.co/example/model/resolve/main/model.bin',
    );

    expect(mirrors.effectiveMirrorHost, isNull);
    expect(mirrors.downloadUris(source), [source]);
  });
}
