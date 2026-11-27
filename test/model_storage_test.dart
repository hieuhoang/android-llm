import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llm_text_app/model_storage.dart';

void main() {
  late HttpServer server;
  late Directory supportDirectory;
  late List<int> modelBytes;
  late ModelArtifact artifact;
  late LinuxModelStore store;
  final rangeStarts = <int>[];
  var requestCount = 0;

  setUp(() async {
    supportDirectory = await Directory.systemTemp.createTemp('model-store-');
    modelBytes = List<int>.generate(4096, (index) => index % 256);
    artifact = ModelArtifact(
      key: 'test',
      repository: 'test/model',
      revision: 'revision',
      filename: 'model.gguf',
      sha256: sha256.convert(modelBytes).toString(),
      size: modelBytes.length,
    );
    rangeStarts.clear();
    requestCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestCount++;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final start = range == null
          ? 0
          : int.parse(RegExp(r'^bytes=(\d+)-$').firstMatch(range)!.group(1)!);
      rangeStarts.add(start);
      final response = request.response;
      if (start > 0) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${modelBytes.length - 1}/${modelBytes.length}',
        );
      }
      final bytes = modelBytes.sublist(start);
      response.contentLength = bytes.length;
      response.add(bytes);
      await response.close();
    });
    store = LinuxModelStore(
      supportDirectoryProvider: () async => supportDirectory,
      uriProvider: (artifact) => Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/${artifact.filename}',
      ),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await supportDirectory.delete(recursive: true);
  });

  test('downloads, verifies, and reuses a cached model', () async {
    final progress = <double?>[];
    final token = ModelDownloadCancelToken();
    final path = await store.obtain(
      artifact,
      completedBytes: 0,
      totalBytes: artifact.size,
      onProgress: progress.add,
      cancelToken: token,
    );

    expect(await File(path).readAsBytes(), modelBytes);
    expect(progress, contains(1));
    expect(
      await store.obtain(
        artifact,
        completedBytes: 0,
        totalBytes: artifact.size,
        onProgress: (_) {},
        cancelToken: token,
      ),
      path,
    );
    expect(requestCount, 1);
  });

  test('resumes a partial download', () async {
    final modelDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}models',
    );
    await modelDirectory.create(recursive: true);
    final partialPath =
        '${modelDirectory.path}${Platform.pathSeparator}${artifact.filename}.part';
    final offset = modelBytes.length ~/ 2;
    await File(partialPath).writeAsBytes(modelBytes.sublist(0, offset));

    final path = await store.obtain(
      artifact,
      completedBytes: 0,
      totalBytes: artifact.size,
      onProgress: (_) {},
      cancelToken: ModelDownloadCancelToken(),
    );

    expect(await File(path).readAsBytes(), modelBytes);
    expect(rangeStarts, [offset]);
  });

  test('rejects a downloaded model with the wrong checksum', () async {
    final invalidArtifact = ModelArtifact(
      key: artifact.key,
      repository: artifact.repository,
      revision: artifact.revision,
      filename: artifact.filename,
      sha256: List.filled(64, '0').join(),
      size: artifact.size,
    );

    await expectLater(
      store.obtain(
        invalidArtifact,
        completedBytes: 0,
        totalBytes: invalidArtifact.size,
        onProgress: (_) {},
        cancelToken: ModelDownloadCancelToken(),
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      File(
        '${supportDirectory.path}${Platform.pathSeparator}models'
        '${Platform.pathSeparator}${artifact.filename}',
      ).existsSync(),
      isFalse,
    );
  });
}
