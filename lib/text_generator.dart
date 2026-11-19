import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';

enum ModelChoice { qwen3, omni }

enum AttachmentKind { image, audio }

class PromptAttachment {
  const PromptAttachment({
    required this.kind,
    required this.path,
    required this.name,
  });

  final AttachmentKind kind;
  final String path;
  final String name;
}

class GenerationChunk {
  const GenerationChunk({
    this.reasoning = '',
    this.text = '',
    this.truncated = false,
  });

  final String reasoning;
  final String text;
  final bool truncated;
}

abstract interface class TextGenerator {
  Future<void> load(
    void Function(double?) onProgress, {
    ModelChoice model = ModelChoice.qwen3,
  });
  Stream<GenerationChunk> generate(
    String prompt, {
    bool enableReasoning = true,
    ModelChoice model = ModelChoice.qwen3,
    List<PromptAttachment> attachments = const [],
  });
  void clearHistory();
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
  ModelChoice? _loadedModel;
  bool _cancelled = false;
  String? _downloading;

  @override
  Future<void> load(
    void Function(double?) onProgress, {
    ModelChoice model = ModelChoice.qwen3,
  }) async {
    if (_loadedModel == model) return;
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Public model storage is currently supported on Android only.',
      );
    }
    _cancelled = false;
    final cancel = ModelDownloadCancelToken();
    _downloadCancel = cancel;
    try {
      if (_loadedModel != null) {
        await _engine.unloadModel();
        _loadedModel = null;
      }
      await _downloads.invokeMethod<void>('close');
      final files = model == ModelChoice.qwen3
          ? [
              (
                'qwen3',
                '9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031',
                639446688,
              ),
            ]
          : [
              (
                'omni',
                '4b0bd358c1e9ec55dd3055ef6d71c958c821533d85916a10cfa89c4552a86e29',
                2104931648,
              ),
              (
                'omni_projector',
                '4e6c816cd33f7298d07cb780c136a396631e50e62f6501660271f8c6e302e565',
                1538031328,
              ),
            ];
      final paths = <String>[];
      final totalBytes = files.fold<int>(0, (total, file) => total + file.$3);
      var completedBytes = 0;
      for (var index = 0; index < files.length; index++) {
        final (key, checksum, expectedSize) = files[index];
        _downloading = key;
        await _downloads.invokeMethod<int>('start', {'key': key});
        while (true) {
          if (_cancelled) throw StateError('Model download stopped.');
          final status = await _downloads.invokeMapMethod<String, dynamic>(
            'status',
            {'key': key},
          );
          if (status == null) {
            throw StateError('Missing download status for $key.');
          }
          final state = status['status'] as int;
          if (state == 8) break;
          if (state == 16) {
            throw StateError(
              'Model download failed (Android reason ${status['reason']}). Tap Generate to retry.',
            );
          }
          final received = status['received'] as int;
          final total = status['total'] as int;
          onProgress(
            total > 0
                ? ((completedBytes + received) / totalBytes).clamp(0, 1)
                : null,
          );
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        completedBytes += expectedSize;
        _downloading = null;
        if (_cancelled) throw StateError('Model download stopped.');
        onProgress(null);
        final fd = await _downloads.invokeMethod<int>('open', {'key': key});
        if (fd == null) {
          throw StateError('Could not open downloaded file $key.');
        }
        final path = '/proc/self/fd/$fd';
        final digest = await sha256
            .bind(
              File(path).openRead().map((chunk) {
                if (_cancelled) throw StateError('Model verification stopped.');
                return chunk;
              }),
            )
            .first;
        if (digest.toString() != checksum) {
          throw StateError('Checksum mismatch for $key.');
        }
        paths.add(path);
      }
      if (_cancelled) throw StateError('Model loading stopped.');
      await _engine.setModel(
        LlamaModel(
          ModelSource.path(paths.first, format: ModelFormat.gguf),
          projector: paths.length > 1
              ? ModelSource.path(paths[1], format: ModelFormat.gguf)
              : null,
        ),
        params: const ModelParams(contextSize: _contextSize, gpuLayers: 0),
        download: ModelLoadOptions(cancelToken: cancel),
      );
      _loadedModel = model;
    } finally {
      _downloading = null;
      _downloadCancel = null;
    }
  }

  @override
  Stream<GenerationChunk> generate(
    String prompt, {
    bool enableReasoning = true,
    ModelChoice model = ModelChoice.qwen3,
    List<PromptAttachment> attachments = const [],
  }) async* {
    if (model == ModelChoice.qwen3 && attachments.isNotEmpty) {
      throw ArgumentError('The selected model does not support attachments.');
    }
    if (model == ModelChoice.qwen3) {
      final history = _session.history;
      _session.reset();
      for (final message in history) {
        _session.addMessage(
          message.copyWith(
            parts: [
              for (final part in message.parts)
                if (part is LlamaImageContent)
                  const LlamaTextContent('\n[Image attached]')
                else if (part is LlamaAudioContent)
                  const LlamaTextContent('\n[Audio attached]')
                else
                  part,
            ],
          ),
        );
      }
    }
    final previousHistory = _session.history;
    final answer = StringBuffer();
    final thinking = model == ModelChoice.qwen3 && enableReasoning;
    try {
      await for (final chunk in _session.create(
        [
          LlamaTextContent(prompt),
          for (final attachment in attachments)
            if (attachment.kind == AttachmentKind.image)
              LlamaImageContent(path: attachment.path)
            else
              LlamaAudioContent(path: attachment.path),
        ],
        enableThinking: thinking,
        params: GenerationParams(
          maxTokens: 512,
          thinkingBudget: thinking
              ? const ThinkingBudget(maxTokens: 256)
              : null,
          temp: thinking ? 0.6 : 0.7,
          topP: thinking ? 0.95 : 0.8,
          topK: 20,
          presencePenalty: 1.5,
        ),
      )) {
        answer.write(chunk.text);
        if (chunk.text.isNotEmpty ||
            chunk.thinking.isNotEmpty ||
            chunk.finishReason == LlamaFinishReason.length) {
          yield GenerationChunk(
            reasoning: chunk.thinking,
            text: chunk.text,
            truncated: chunk.finishReason == LlamaFinishReason.length,
          );
        }
      }
    } finally {
      final history = answer.toString().trim().isNotEmpty
          ? _session.history
          : previousHistory;
      _session.reset();
      for (final message in history) {
        _session.addMessage(
          message.role == LlamaChatRole.assistant
              ? LlamaChatMessage.fromText(
                  role: LlamaChatRole.assistant,
                  text: message.content,
                )
              : message,
        );
      }
    }
  }

  @override
  void clearHistory() => _session.reset();

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _downloadCancel?.cancel();
    _engine.cancelGeneration();
    final downloading = _downloading;
    if (downloading != null) {
      await _downloads.invokeMethod<void>('cancel', {'key': downloading});
    }
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
