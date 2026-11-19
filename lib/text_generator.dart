import 'dart:io';

import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';

abstract interface class TextGenerator {
  Future<void> load(void Function(double?) onProgress);
  Stream<String> generate(String prompt);
  Future<void> cancel();
  Future<void> dispose();
}

class LocalTextGenerator implements TextGenerator {
  LocalTextGenerator({LlamaEngine? engine})
    : _engine = engine ?? LlamaEngine(LlamaBackend());

  static const _contextSize = 2048;
  final LlamaEngine _engine;
  late final _session = ChatSession(_engine, maxContextTokens: _contextSize);
  static const _downloads = MethodChannel('llm_text_app/model_download');
  ModelDownloadCancelToken? _downloadCancel;
  bool _loaded = false;
  bool _cancelled = false;
  bool _downloading = false;

  @override
  Future<void> load(void Function(double?) onProgress) async {
    if (_loaded) return;
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Public model storage is currently supported on Android only.',
      );
    }
    _cancelled = false;
    final cancel = ModelDownloadCancelToken();
    _downloadCancel = cancel;
    try {
      _downloading = true;
      await _downloads.invokeMethod<int>('start');
      while (true) {
        if (_cancelled) throw StateError('Model download stopped.');
        final status = await _downloads.invokeMapMethod<String, dynamic>(
          'status',
        );
        if (status == null) throw StateError('Missing download status.');
        final state = status['status'] as int;
        if (state == 8) break;
        if (state == 16) {
          throw StateError(
            'Model download failed (Android reason ${status['reason']}). Tap Generate to retry.',
          );
        }
        final received = status['received'] as int;
        final total = status['total'] as int;
        onProgress(total > 0 ? (received / total).clamp(0, 1) : null);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      _downloading = false;
      if (_cancelled) throw StateError('Model download stopped.');
      onProgress(null);
      final fd = await _downloads.invokeMethod<int>('open');
      if (fd == null) throw StateError('Could not open the downloaded model.');
      if (_cancelled) throw StateError('Model loading stopped.');
      await _engine.setModel(
        LlamaModel(
          ModelSource.path('/proc/self/fd/$fd', format: ModelFormat.gguf),
        ),
        params: const ModelParams(contextSize: _contextSize, gpuLayers: 0),
        download: ModelLoadOptions(
          cancelToken: cancel,
          sha256: '9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031',
        ),
      );
      _loaded = true;
    } finally {
      _downloading = false;
      _downloadCancel = null;
    }
  }

  @override
  Stream<String> generate(String prompt) async* {
    await for (final chunk in _session.create(
      [LlamaTextContent(prompt)],
      enableThinking: false,
      params: const GenerationParams(
        maxTokens: 256,
        temp: 0.7,
        topP: 0.8,
        topK: 20,
        presencePenalty: 1.5,
      ),
    )) {
      if (chunk.text.isNotEmpty) yield chunk.text;
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _downloadCancel?.cancel();
    _engine.cancelGeneration();
    if (_downloading) await _downloads.invokeMethod<void>('cancel');
  }

  @override
  Future<void> dispose() async {
    _cancelled = true;
    _downloadCancel?.cancel();
    _engine.cancelGeneration();
    await _engine.dispose();
    if (Platform.isAndroid) await _downloads.invokeMethod<void>('close');
  }
}
