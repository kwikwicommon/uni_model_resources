import 'dart:convert';
import 'dart:io';

abstract class ResourceStringStorage {
  String? read(String key);
  Future<void> write(String key, String value);
}

class MemoryResourceStorage implements ResourceStringStorage {
  final Map<String, String> values = {};
  @override
  String? read(String key) => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class FileResourceStorage extends MemoryResourceStorage {
  FileResourceStorage._(this.file);
  final File file;
  Future<void> _tail = Future.value();
  static Future<FileResourceStorage> open(File file) async {
    final store = FileResourceStorage._(file);
    if (await file.exists()) {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      store.values.addAll(
        decoded.map((key, value) => MapEntry(key, value as String)),
      );
    }
    return store;
  }

  @override
  Future<void> write(String key, String value) {
    values[key] = value;
    final contents = jsonEncode(values);
    final next = _tail.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.writing');
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(file.path);
    });
    _tail = next.catchError((Object _) {});
    return next;
  }
}
