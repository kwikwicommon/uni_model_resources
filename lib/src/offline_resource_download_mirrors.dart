class OfflineResourceDownloadMirrors {
  const OfflineResourceDownloadMirrors({this.configuredHost});

  static const defaultHuggingFaceMirrorHost = 'hf-mirror.com';
  static const officialHuggingFaceHost = 'huggingface.co';
  static const disabledSentinel = 'off';

  final String? configuredHost;

  static String? normalizeHost(String? raw) {
    var value = raw?.trim().toLowerCase() ?? '';
    if (value.isEmpty ||
        value == disabledSentinel ||
        value == 'direct' ||
        value == 'none' ||
        value == officialHuggingFaceHost) {
      return null;
    }
    if (value.startsWith('https://')) {
      value = value.substring('https://'.length);
    } else if (value.startsWith('http://')) {
      value = value.substring('http://'.length);
    }
    final host = value.split('/').first.split(':').first.trim();
    if (!_isValidMirrorHost(host)) {
      return null;
    }
    return host;
  }

  String? get effectiveMirrorHost {
    if (configuredHost == null) {
      return defaultHuggingFaceMirrorHost;
    }
    return normalizeHost(configuredHost);
  }

  bool get isEnabled => effectiveMirrorHost != null;

  List<Uri> downloadUris(Uri source) {
    final rewritten = rewriteHuggingFaceUri(source);
    if (rewritten == null || rewritten == source) {
      return <Uri>[source];
    }
    return <Uri>[rewritten, source];
  }

  Uri? rewriteHuggingFaceUri(Uri source) {
    final mirrorHost = effectiveMirrorHost;
    if (mirrorHost == null || source.scheme.toLowerCase() != 'https') {
      return null;
    }
    final sourceHost = source.host.toLowerCase();
    if (!_isOfficialHuggingFaceContentHost(sourceHost)) {
      return null;
    }
    return source.replace(host: mirrorHost);
  }

  bool isTrustedRedirect(Uri sourceUri, Uri finalUri) {
    if (sourceUri.scheme.toLowerCase() != 'https' ||
        finalUri.scheme.toLowerCase() != 'https') {
      return false;
    }

    final sourceHost = sourceUri.host.toLowerCase();
    final finalHost = finalUri.host.toLowerCase();
    if (sourceHost == finalHost) {
      return true;
    }

    if (_isHuggingFaceFamilyHost(sourceHost) &&
        _isHuggingFaceFamilyHost(finalHost)) {
      return true;
    }

    if (_isGitHubFamilyHost(sourceHost) && _isGitHubFamilyHost(finalHost)) {
      return true;
    }

    return false;
  }

  bool _isHuggingFaceFamilyHost(String host) {
    if (_isOfficialHuggingFaceContentHost(host) ||
        host == 'hf.co' ||
        host.endsWith('.hf.co') ||
        _hostOrSubdomain(host, defaultHuggingFaceMirrorHost)) {
      return true;
    }
    final mirrorHost = effectiveMirrorHost;
    return mirrorHost != null && _hostOrSubdomain(host, mirrorHost);
  }

  static bool _isOfficialHuggingFaceContentHost(String host) {
    return host == officialHuggingFaceHost ||
        host.endsWith('.$officialHuggingFaceHost');
  }

  static bool _isGitHubFamilyHost(String host) {
    return host == 'github.com' ||
        host.endsWith('.github.com') ||
        host == 'githubusercontent.com' ||
        host.endsWith('.githubusercontent.com') ||
        host == 'githubassets.com' ||
        host.endsWith('.githubassets.com');
  }

  static bool _hostOrSubdomain(String host, String root) {
    return host == root || host.endsWith('.$root');
  }

  static bool _isValidMirrorHost(String host) {
    if (host == 'localhost') {
      return true;
    }
    return RegExp(
      r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
    ).hasMatch(host);
  }
}
