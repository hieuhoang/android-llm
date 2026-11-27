import 'dart:io';

import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';

import 'local_agent.dart';
import 'model_storage.dart';

enum ModelChoice { qwen3, omniQ2, omniQ4, omniQ8 }

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
    bool useGpu = false,
    bool loadProjector = true,
    bool stagedMultimodal = false,
  });
  Stream<GenerationChunk> generate(
    String prompt, {
    bool enableReasoning = true,
    ModelChoice model = ModelChoice.qwen3,
    List<PromptAttachment> attachments = const [],
    bool loadProjector = true,
    bool useAgent = false,
    EmailRequest? onEmailRequest,
    void Function(Calculation)? onCalculation,
  });
  void clearHistory();
  Future<void> cancel();
  Future<void> dispose();
}

class LocalTextGenerator implements TextGenerator {
  LocalTextGenerator({LlamaEngine? engine, AppModelFileStore? modelStore})
    : _engine = engine ?? LlamaEngine(LlamaBackend()),
      _modelStore = modelStore ?? LinuxModelStore();

  static int _contextSizeFor(ModelChoice model) =>
      model == ModelChoice.qwen3 ? 2048 : 8192;
  final LlamaEngine _engine;
  final LocalAgent _agent = LocalAgent();
  late final _session = ChatSession(
    _engine,
    maxContextTokens: _contextSizeFor(ModelChoice.qwen3),
  );
  static const _downloads = MethodChannel('llm_text_app/model_download');
  ModelDownloadCancelToken? _downloadCancel;
  final AppModelFileStore _modelStore;
  ModelChoice? _loadedModel;
  bool? _loadedWithGpu;
  bool? _loadedWithProjector;
  bool? _loadedWithStaging;
  bool _cancelled = false;
  String? _downloading;
  bool _verifying = false;

  @override
  Future<void> load(
    void Function(double?) onProgress, {
    ModelChoice model = ModelChoice.qwen3,
    bool useGpu = false,
    bool loadProjector = true,
    bool stagedMultimodal = false,
  }) async {
    final withProjector = model != ModelChoice.qwen3 && loadProjector;
    final withStaging = withProjector && stagedMultimodal;
    _cancelled = false;
    if (_loadedModel == model &&
        _loadedWithGpu == useGpu &&
        _loadedWithProjector == withProjector &&
        _loadedWithStaging == withStaging) {
      return;
    }
    if (!Platform.isAndroid && !Platform.isLinux) {
      throw UnsupportedError(
        'Model downloads are currently supported on Android and Linux.',
      );
    }
    final cancel = ModelDownloadCancelToken();
    _downloadCancel = cancel;
    try {
      if (_loadedModel != null) {
        await _engine.unloadModel();
        _loadedModel = null;
        _loadedWithGpu = null;
        _loadedWithProjector = null;
        _loadedWithStaging = null;
      }
      if (Platform.isAndroid) await _downloads.invokeMethod<void>('close');
      final modelFile = switch (model) {
        ModelChoice.qwen3 => const ModelArtifact(
          key: 'qwen3',
          repository: 'Qwen/Qwen3-0.6B-GGUF',
          revision: '23749fefcc72300e3a2ad315e1317431b06b590a',
          filename: 'Qwen3-0.6B-Q8_0.gguf',
          sha256: '9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031',
          size: 639446688,
        ),
        ModelChoice.omniQ2 => const ModelArtifact(
          key: 'omni_q2',
          repository: 'unsloth/Qwen2.5-Omni-3B-GGUF',
          revision: '9eb5b23b5222c0ec3b81ce932e35a7f21a9b75d3',
          filename: 'Qwen2.5-Omni-3B-Q2_K.gguf',
          sha256: 'c51e4b42d85f0a0c2d7699b1891521b8d050d89911b939a258c31e9a7e50c131',
          size: 1376856096,
        ),
        ModelChoice.omniQ4 => const ModelArtifact(
          key: 'omni',
          repository: 'ggml-org/Qwen2.5-Omni-3B-GGUF',
          revision: '75f1b73b657a50f5092502799457ccb4a4a1f9df',
          filename: 'Qwen2.5-Omni-3B-Q4_K_M.gguf',
          sha256: '4b0bd358c1e9ec55dd3055ef6d71c958c821533d85916a10cfa89c4552a86e29',
          size: 2104931648,
        ),
        ModelChoice.omniQ8 => const ModelArtifact(
          key: 'omni_q8',
          repository: 'ggml-org/Qwen2.5-Omni-3B-GGUF',
          revision: '75f1b73b657a50f5092502799457ccb4a4a1f9df',
          filename: 'Qwen2.5-Omni-3B-Q8_0.gguf',
          sha256: 'c7d8b07c8d8d7a9ed1de1b8df7ac821eb4d259a224bd44310baacfaa5a473d4c',
          size: 3616087360,
        ),
      };
      final files = [
        modelFile,
        if (withProjector)
          const ModelArtifact(
            key: 'omni_projector',
            repository: 'ggml-org/Qwen2.5-Omni-3B-GGUF',
            revision: '75f1b73b657a50f5092502799457ccb4a4a1f9df',
            filename: 'mmproj-Qwen2.5-Omni-3B-Q8_0.gguf',
            sha256: '4e6c816cd33f7298d07cb780c136a396631e50e62f6501660271f8c6e302e565',
            size: 1538031328,
          ),
      ];
      final paths = <String>[];
      final totalBytes = files.fold<int>(0, (total, file) => total + file.size);
      var completedBytes = 0;
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        _downloading = file.key;
        if (Platform.isAndroid) {
          await _downloads.invokeMethod<int>('start', {'key': file.key});
          while (true) {
            if (_cancelled) throw StateError('Model download stopped.');
            final status = await _downloads.invokeMapMethod<String, dynamic>(
              'status',
              {'key': file.key},
            );
            if (status == null) {
              throw StateError('Missing download status for ${file.key}.');
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
          completedBytes += file.size;
          _downloading = null;
          if (_cancelled) throw StateError('Model download stopped.');
          onProgress(null);
          final fd = await _downloads.invokeMethod<int>('open', {
            'key': file.key,
          });
          if (fd == null) {
            throw StateError('Could not open downloaded file ${file.key}.');
          }
          final path = '/proc/self/fd/$fd';
          _verifying = true;
          String? digest;
          try {
            digest = await _downloads.invokeMethod<String>('verify', {
              'key': file.key,
              'checksum': file.sha256,
            });
          } finally {
            _verifying = false;
          }
          if (_cancelled) throw StateError('Model verification stopped.');
          if (digest != file.sha256) {
            throw StateError('Checksum mismatch for ${file.key}.');
          }
          paths.add(path);
        } else {
          paths.add(
            await _modelStore.obtain(
              file,
              completedBytes: completedBytes,
              totalBytes: totalBytes,
              onProgress: onProgress,
              cancelToken: cancel,
            ),
          );
          completedBytes += file.size;
        }
        _downloading = null;
        if (_cancelled) throw StateError('Model download stopped.');
        onProgress(null);
      }
      if (_cancelled) throw StateError('Model loading stopped.');
      await _engine.setModel(
        LlamaModel(
          ModelSource.path(paths.first, format: ModelFormat.gguf),
          projector: paths.length > 1
              ? ModelSource.path(paths[1], format: ModelFormat.gguf)
              : null,
        ),
        params: ModelParams(
          contextSize: _contextSizeFor(model),
          device: useGpu ? ComputeDevice.gpu : ComputeDevice.cpu,
          gpuLayers: useGpu ? ModelParams.maxGpuLayers : 0,
          stagedMultimodal: withStaging,
        ),
        download: ModelLoadOptions(cancelToken: cancel),
      );
      _loadedModel = model;
      _loadedWithGpu = useGpu;
      _loadedWithProjector = withProjector;
      _loadedWithStaging = withStaging;
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
    bool loadProjector = true,
    bool useAgent = false,
    EmailRequest? onEmailRequest,
    void Function(Calculation)? onCalculation,
  }) async* {
    final withProjector = model != ModelChoice.qwen3 && loadProjector;
    if (!withProjector && attachments.isNotEmpty) {
      throw ArgumentError('Image and audio input requires the Omni projector.');
    }
    if (useAgent && (model != ModelChoice.qwen3 || attachments.isNotEmpty)) {
      throw ArgumentError(
        'The offline agent currently supports Qwen3 text only.',
      );
    }
    _session.maxContextTokens = _contextSizeFor(model);
    if (!withProjector) {
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
    var restorePreviousHistory = false;
    try {
      final params = GenerationParams(
        maxTokens: 512,
        thinkingBudget: thinking ? const ThinkingBudget(maxTokens: 256) : null,
        temp: thinking ? 0.6 : 0.7,
        topP: thinking ? 0.95 : 0.8,
        topK: 20,
        presencePenalty: 1.5,
      );
      if (useAgent) {
        final result = await _agent.run(
          _session,
          prompt,
          enableThinking: thinking,
          params: params,
          isCancelled: () => _cancelled,
          onEmailRequest: onEmailRequest,
          onCalculation: onCalculation,
        );
        restorePreviousHistory = result.rolledBack;
        switch (result.stopReason) {
          case LlamaToolLoopStopReason.completed:
          case LlamaToolLoopStopReason.cancelled:
            if (!result.rolledBack) {
              answer.write(result.text);
              yield GenerationChunk(
                text: result.text,
                reasoning: result.completion.thinking,
              );
            }
            return;
          case LlamaToolLoopStopReason.truncated:
            throw StateError('Agent response reached the token limit.');
          case LlamaToolLoopStopReason.contextExceeded:
            throw StateError('Agent request exceeds the context window.');
          case LlamaToolLoopStopReason.maxRounds:
            throw StateError('Agent reached the tool-call limit.');
          case LlamaToolLoopStopReason.unhandledToolCalls:
            restorePreviousHistory = true;
            throw StateError('Agent requested an unhandled tool.');
        }
      }
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
        params: params,
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
    } catch (_) {
      if (_loadedWithStaging == true) {
        _loadedModel = null;
      }
      rethrow;
    } finally {
      final history =
          !restorePreviousHistory && answer.toString().trim().isNotEmpty
          ? _session.history
          : previousHistory;
      _session.reset();
      for (final message in history) {
        if (message.role == LlamaChatRole.tool ||
            message.parts.any((part) => part is LlamaToolCallContent)) {
          continue;
        }
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
    _modelStore.cancel();
    _engine.cancelGeneration();
    final downloading = _downloading;
    if (downloading != null && Platform.isAndroid) {
      await _downloads.invokeMethod<void>('cancel', {'key': downloading});
    }
    if (_verifying && Platform.isAndroid) {
      await _downloads.invokeMethod<void>('cancelVerification');
    }
  }

  @override
  Future<void> dispose() async {
    _cancelled = true;
    _downloadCancel?.cancel();
    _modelStore.cancel();
    if (_verifying && Platform.isAndroid) {
      await _downloads.invokeMethod<void>('cancelVerification');
    }
    _engine.cancelGeneration();
    await _engine.dispose();
    if (Platform.isAndroid) await _downloads.invokeMethod<void>('close');
  }
}
