import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

@immutable
class ModelArtifact {
  const ModelArtifact({
    required this.key,
    required this.repository,
    required this.revision,
    required this.filename,
    required this.sha256,
    required this.size,
  });

  final String key;
  final String repository;
  final String revision;
  final String filename;
  final String sha256;
  final int size;
}

abstract interface class AppModelFileStore {
  Future<String> obtain(
    ModelArtifact artifact, {
    required int completedBytes,
    required int totalBytes,
    required void Function(double?) onProgress,
    required ModelDownloadCancelToken cancelToken,
  });

  void cancel();
}

class LinuxModelStore implements AppModelFileStore {
  LinuxModelStore({
    Future<Directory> Function()? supportDirectoryProvider,
    HttpClient Function()? httpClientFactory,
    Uri Function(ModelArtifact)? uriProvider,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _uriProvider = uriProvider ?? _modelUri;

  final Future<Directory> Function() _supportDirectoryProvider;
  final HttpClient Function() _httpClientFactory;
  final Uri Function(ModelArtifact) _uriProvider;
  HttpClient? _activeClient;

  @override
  void cancel() {
    _activeClient?.close(force: true);
  }

  @override
  Future<String> obtain(
    ModelArtifact artifact, {
    required int completedBytes,
    required int totalBytes,
    required void Function(double?) onProgress,
    required ModelDownloadCancelToken cancelToken,
  }) async {
    final client = _httpClientFactory();
    _activeClient = client;
    try {
      void checkCancelled() {
        if (cancelToken.isCancelled) {
          throw StateError('Model download stopped.');
        }
      }

      checkCancelled();
      final supportDirectory = await _supportDirectoryProvider();
      final modelDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}models',
      );
      await modelDirectory.create(recursive: true);

      final modelFile = File(
        '${modelDirectory.path}${Platform.pathSeparator}${artifact.filename}',
      );
      if (await modelFile.exists()) {
        if (await modelFile.length() == artifact.size &&
            await _hasExpectedChecksum(modelFile, artifact.sha256)) {
          return modelFile.path;
        }
        await modelFile.delete();
      }

      final partialFile = File('${modelFile.path}.part');
      var offset = await partialFile.exists() ? await partialFile.length() : 0;
      if (offset > artifact.size) {
        await partialFile.delete();
        offset = 0;
      } else if (offset == artifact.size) {
        if (await _hasExpectedChecksum(partialFile, artifact.sha256)) {
          return (await partialFile.rename(modelFile.path)).path;
        }
        await partialFile.delete();
        offset = 0;
      }

      checkCancelled();
      final uri = _uriProvider(artifact);
      final request = await client.getUrl(uri);
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await request.close();
      final append = switch (response.statusCode) {
        HttpStatus.partialContent => _validateContentRange(
          response,
          offset,
          artifact,
          uri,
        ),
        HttpStatus.ok => false,
        _ => throw HttpException(
          'Model download failed with HTTP ${response.statusCode}.',
          uri: uri,
        ),
      };
      if (!append) offset = 0;

      var receivedBytes = 0;
      final sink = partialFile.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in response) {
          checkCancelled();
          sink.add(chunk);
          receivedBytes += chunk.length;
          onProgress(
            ((completedBytes + offset + receivedBytes) / totalBytes)
                .clamp(0, 1)
                .toDouble(),
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      checkCancelled();
      if (await partialFile.length() != artifact.size) {
        throw StateError(
          'Downloaded model has an unexpected size: ${artifact.filename}.',
        );
      }
      if (!await _hasExpectedChecksum(partialFile, artifact.sha256)) {
        await partialFile.delete();
        throw StateError('Checksum mismatch for ${artifact.filename}.');
      }
      checkCancelled();
      return (await partialFile.rename(modelFile.path)).path;
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      client.close(force: cancelToken.isCancelled);
    }
  }

  bool _validateContentRange(
    HttpClientResponse response,
    int offset,
    ModelArtifact artifact,
    Uri uri,
  ) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = value == null
        ? null
        : RegExp(r'^bytes (\d+)-\d+/(\d+|\*)$').firstMatch(value);
    if (match == null ||
        int.parse(match.group(1)!) != offset ||
        (match.group(2) != '*' &&
            int.parse(match.group(2)!) != artifact.size)) {
      throw HttpException('Invalid model download range response.', uri: uri);
    }
    return offset > 0;
  }

  Future<bool> _hasExpectedChecksum(File file, String expected) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expected;
  }

  static Uri _modelUri(ModelArtifact artifact) => Uri.https(
    'huggingface.co',
    '/${artifact.repository}/resolve/${artifact.revision}/${artifact.filename}',
  );
}
