import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'media_input.dart';
import 'text_generator.dart';

void main() {
  runApp(const LlmTextApp());
}

class LlmTextApp extends StatelessWidget {
  const LlmTextApp({super.key, this.generator, this.media});

  final TextGenerator? generator;
  final MediaInput? media;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LLM Text',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5367D5)),
        useMaterial3: true,
      ),
      home: PromptScreen(generator: generator, media: media),
    );
  }
}

class PromptScreen extends StatefulWidget {
  const PromptScreen({super.key, this.generator, this.media});

  final TextGenerator? generator;
  final MediaInput? media;

  @override
  State<PromptScreen> createState() => _PromptScreenState();
}

class _ConversationTurn {
  _ConversationTurn(this.prompt, this.attachments);

  final String prompt;
  final List<PromptAttachment> attachments;
  String reasoning = '';
  String response = '';
  String? note;
  bool truncated = false;
}

class _PromptScreenState extends State<PromptScreen> {
  final _promptController = TextEditingController();
  late final TextGenerator _generator =
      widget.generator ?? LocalTextGenerator();
  final _conversation = <_ConversationTurn>[];
  late final _media = widget.media ?? MediaInput();
  final _attachments = <PromptAttachment>[];
  ModelChoice _model = ModelChoice.qwen3;
  String _status = 'Models download on first use.';
  bool _busy = false;
  bool _mediaBusy = false;
  bool _recording = false;
  bool _enableReasoning = true;
  bool _useGpu = false;
  bool _loadProjector = true;
  bool _stagedMultimodal = false;
  bool _downsizeImages = false;
  bool _cancelled = false;
  double? _progress;
  String? _stopError;
  static const _buildInfo = MethodChannel('llm_text_app/build_info');
  final Future<DateTime> _buildTimestamp = _buildInfo
      .invokeMethod<String>('buildTimestamp')
      .then((timestamp) {
        if (timestamp == null || timestamp.isEmpty) {
          throw StateError('Android did not provide a build time.');
        }
        return DateTime.parse(timestamp).toLocal();
      });

  @override
  void dispose() {
    unawaited(
      _disposeGenerator().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
      }),
    );
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _disposeGenerator() async {
    await _generator.dispose();
    await _media.dispose();
  }

  Future<void> _generate() async {
    final prompt = _promptController.text.trim();
    if (_busy ||
        _mediaBusy ||
        _recording ||
        (prompt.isEmpty && _attachments.isEmpty) ||
        ((_model == ModelChoice.qwen3 || !_loadProjector) &&
            _attachments.isNotEmpty)) {
      return;
    }
    final turn = _ConversationTurn(prompt, List.of(_attachments));
    FocusScope.of(context).unfocus();
    setState(() {
      _conversation.add(turn);
      _busy = true;
      _cancelled = false;
      _stopError = null;
      _progress = null;
      _status = 'Preparing model...';
    });
    var screenAwake = false;
    try {
      if (Platform.isAndroid) {
        await _buildInfo.invokeMethod<void>('keepScreenOn', true);
        screenAwake = true;
      }
      if (!mounted || _cancelled) return;
      await _generator.load(
        (progress) {
          if (!mounted || _cancelled) return;
          setState(() {
            _progress = progress;
            _status = progress == null
                ? 'Preparing model...'
                : 'Downloading model: ${(progress * 100).toStringAsFixed(0)}%';
          });
        },
        model: _model,
        useGpu: _useGpu,
        loadProjector: _loadProjector,
        stagedMultimodal: _stagedMultimodal,
      );
      if (!mounted || _cancelled) return;
      setState(() {
        _status = 'Generating...';
        _progress = null;
      });
      await for (final chunk in _generator.generate(
        prompt,
        enableReasoning: _enableReasoning,
        model: _model,
        attachments: turn.attachments,
        loadProjector: _loadProjector,
      )) {
        if (!mounted) break;
        setState(() {
          turn.reasoning += chunk.reasoning;
          turn.response += chunk.text;
          turn.truncated |= chunk.truncated;
        });
      }
      if (mounted && !_cancelled) {
        setState(() {
          _status = 'Ready';
          if (turn.response.trim().isEmpty) {
            turn.note = turn.truncated
                ? 'Token limit reached before a final answer; not included in context.'
                : 'No final answer; not included in context.';
          } else if (turn.truncated) {
            turn.note =
                'Response reached the token limit and may be incomplete.';
          }
        });
      }
    } catch (error) {
      if (mounted && !_cancelled) {
        setState(() {
          _status = 'Error: $error';
          turn.note = turn.response.trim().isEmpty
              ? 'Failed; not included in context.'
              : 'Generation failed; partial response retained.';
        });
      }
    } finally {
      String? screenError;
      if (screenAwake) {
        try {
          await _buildInfo.invokeMethod<void>('keepScreenOn', false);
        } catch (error, stack) {
          screenError = 'Could not restore screen timeout: $error';
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
        }
      }
      if (mounted) {
        setState(() {
          _promptController.clear();
          _attachments.clear();
          _busy = false;
          if (_cancelled) {
            _status = _stopError ?? 'Stopped.';
            turn.note = turn.response.trim().isEmpty
                ? 'Stopped; not included in context.'
                : 'Stopped; partial response retained.';
          }
          if (screenError != null) _status = screenError;
        });
      }
    }
  }

  Future<void> _pick(AttachmentKind kind) async {
    setState(() => _mediaBusy = true);
    try {
      final attachment = await _media.pick(
        kind,
        downsizeImages: kind == AttachmentKind.image && _downsizeImages,
      );
      if (mounted && attachment != null) {
        setState(() => _attachments.add(attachment));
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not select file: $error');
    } finally {
      if (mounted) setState(() => _mediaBusy = false);
    }
  }

  Future<void> _toggleRecording() async {
    setState(() => _mediaBusy = true);
    try {
      if (_recording) {
        final attachment = await _media.stopRecording();
        if (mounted) {
          setState(() {
            _recording = false;
            _attachments.add(attachment);
            _status = 'Recording attached.';
          });
        }
      } else {
        await _media.startRecording();
        if (mounted) {
          setState(() {
            _recording = true;
            _status = 'Recording...';
          });
        }
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Recording error: $error');
    } finally {
      if (mounted) setState(() => _mediaBusy = false);
    }
  }

  void _clearConversation() {
    try {
      _generator.clearHistory();
      setState(() {
        _conversation.clear();
        _status = 'Conversation cleared.';
      });
    } catch (error) {
      setState(() => _status = 'Could not clear conversation: $error');
    }
  }

  Future<void> _stop() async {
    setState(() {
      _cancelled = true;
      _status = 'Stopping...';
    });
    try {
      await _generator.cancel();
    } catch (error) {
      if (mounted) {
        setState(() {
          _stopError = 'Could not stop: $error';
          _status = _stopError!;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LLM Text')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FutureBuilder<DateTime>(
                    future: _buildTimestamp,
                    builder: (context, snapshot) {
                      final text = snapshot.hasError
                          ? 'Build time unavailable: ${snapshot.error}'
                          : snapshot.hasData
                          ? 'Built: ${snapshot.data.toString().split('.').first} (local time)'
                          : 'Reading build time...';
                      return Text(text, key: const Key('build-time'));
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ModelChoice>(
                    initialValue: _model,
                    decoration: const InputDecoration(labelText: 'Model'),
                    items: const [
                      DropdownMenuItem(
                        value: ModelChoice.qwen3,
                        child: Text('Qwen3 0.6B (text)'),
                      ),
                      DropdownMenuItem(
                        value: ModelChoice.omniQ2,
                        child: Text('Qwen2.5 Omni 3B Q2_K'),
                      ),
                      DropdownMenuItem(
                        value: ModelChoice.omniQ4,
                        child: Text('Qwen2.5 Omni 3B Q4_K_M'),
                      ),
                      DropdownMenuItem(
                        value: ModelChoice.omniQ8,
                        child: Text('Qwen2.5 Omni 3B Q8_0'),
                      ),
                    ],
                    onChanged: _busy || _mediaBusy || _recording
                        ? null
                        : (value) {
                            if (value != null) setState(() => _model = value);
                          },
                  ),
                  if (_model != ModelChoice.qwen3)
                    Text(
                      '${_loadProjector ? 'Omni model and shared projector total' : 'Omni model download is'} ${switch (_model) {
                        ModelChoice.omniQ2 => _loadProjector ? '2.92' : '1.38',
                        ModelChoice.omniQ4 => _loadProjector ? '3.64' : '2.10',
                        ModelChoice.omniQ8 => _loadProjector ? '5.15' : '3.62',
                        ModelChoice.qwen3 => throw StateError('Not an Omni model'),
                      }} GB and may exceed available memory. Lower quantization can affect quality. Speech output and reasoning mode are not supported. Qwen Research License: non-commercial use only.',
                    ),
                  if (_model != ModelChoice.qwen3)
                    CheckboxListTile(
                      key: const Key('projector-checkbox'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Load image/audio projector'),
                      subtitle: const Text(
                        'Turn off for text-only use and lower memory. Applies on the next generation; previous media becomes text placeholders.',
                      ),
                      value: _loadProjector,
                      onChanged: _busy || _mediaBusy || _recording
                          ? null
                          : (value) => setState(() {
                              _loadProjector = value ?? false;
                            }),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  if (_model != ModelChoice.qwen3)
                    CheckboxListTile(
                      key: const Key('staged-multimodal-checkbox'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Experimental low-memory image processing',
                      ),
                      subtitle: const Text(
                        'Encode images on CPU before loading the language model. Reloads the model for image requests; turn off for audio.',
                      ),
                      value: _stagedMultimodal,
                      onChanged:
                          _busy || _mediaBusy || _recording || !_loadProjector
                          ? null
                          : (value) => setState(() {
                              _stagedMultimodal = value ?? false;
                            }),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  if (_model != ModelChoice.qwen3)
                    CheckboxListTile(
                      key: const Key('downsize-images-checkbox'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Downsize large images'),
                      subtitle: const Text(
                        'Limit the longest edge to 1024 pixels. Applies to newly selected images.',
                      ),
                      value: _downsizeImages,
                      onChanged:
                          _busy || _mediaBusy || _recording || !_loadProjector
                          ? null
                          : (value) => setState(() {
                              _downsizeImages = value ?? false;
                            }),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  if (_model == ModelChoice.qwen3 && _attachments.isNotEmpty)
                    const Text(
                      'Remove attachments or select Omni to send them. Previous media becomes text placeholders.',
                    ),
                  if (_model != ModelChoice.qwen3 &&
                      !_loadProjector &&
                      _attachments.isNotEmpty)
                    const Text(
                      'Remove attachments or enable the image/audio projector to send them.',
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Prompt',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('prompt-input'),
                    controller: _promptController,
                    enabled: !_busy,
                    minLines: 2,
                    maxLines: 2,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText:
                          'Enter the text you want the model to respond to...',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_model != ModelChoice.qwen3) ...[
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed:
                              _busy ||
                                  _mediaBusy ||
                                  _recording ||
                                  !_loadProjector
                              ? null
                              : () => _pick(AttachmentKind.image),
                          child: const Text('Add image'),
                        ),
                        OutlinedButton(
                          onPressed:
                              _busy ||
                                  _mediaBusy ||
                                  _recording ||
                                  !_loadProjector
                              ? null
                              : () => _pick(AttachmentKind.audio),
                          child: const Text('Add audio file'),
                        ),
                        OutlinedButton(
                          onPressed: _busy || _mediaBusy || !_loadProjector
                              ? null
                              : _toggleRecording,
                          child: Text(
                            _recording ? 'Stop recording' : 'Record audio',
                          ),
                        ),
                      ],
                    ),
                  ],
                  for (final attachment in _attachments)
                    ListTile(
                      title: Text(
                        '${attachment.kind.name}: ${attachment.name}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove attachment',
                        icon: const Icon(Icons.close),
                        onPressed: _busy || _mediaBusy || _recording
                            ? null
                            : () => setState(
                                () => _attachments.remove(attachment),
                              ),
                      ),
                    ),
                  CheckboxListTile(
                    key: const Key('reasoning-checkbox'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable reasoning'),
                    value: _model == ModelChoice.qwen3 && _enableReasoning,
                    onChanged: _busy || _model != ModelChoice.qwen3
                        ? null
                        : (value) => setState(() {
                            _enableReasoning = value ?? false;
                          }),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  CheckboxListTile(
                    key: const Key('gpu-checkbox'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use GPU offloading'),
                    value: _useGpu,
                    onChanged: _busy || _mediaBusy || _recording
                        ? null
                        : (value) => setState(() {
                            _useGpu = value ?? false;
                          }),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  FilledButton(
                    onPressed:
                        _busy ||
                            _mediaBusy ||
                            _recording ||
                            (_promptController.text.trim().isEmpty &&
                                _attachments.isEmpty) ||
                            ((_model == ModelChoice.qwen3 || !_loadProjector) &&
                                _attachments.isNotEmpty)
                        ? null
                        : _generate,
                    child: const Text('Generate'),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _progress),
                    TextButton(
                      onPressed: _cancelled ? null : _stop,
                      child: const Text('Stop'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(_status, key: const Key('status')),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Conversation',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        onPressed:
                            _busy ||
                                _mediaBusy ||
                                _recording ||
                                _conversation.isEmpty
                            ? null
                            : _clearConversation,
                        child: const Text('Clear conversation'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Older messages may no longer fit in the model context.',
                  ),
                  const SizedBox(height: 8),
                  Container(
                    key: const Key('output-area'),
                    height: 300,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _conversation.isEmpty
                        ? const Align(
                            alignment: Alignment.topLeft,
                            child: Text('Your conversation will appear here.'),
                          )
                        : ListView.builder(
                            reverse: true,
                            itemCount: _conversation.length,
                            itemBuilder: (context, index) {
                              final turn =
                                  _conversation[_conversation.length -
                                      1 -
                                      index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'You',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge,
                                    ),
                                    SelectableText(turn.prompt),
                                    for (final attachment in turn.attachments)
                                      Text(
                                        '${attachment.kind.name}: ${attachment.name}',
                                      ),
                                    const SizedBox(height: 8),
                                    if (turn.reasoning.isNotEmpty) ...[
                                      Text(
                                        'Reasoning',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge,
                                      ),
                                      SelectableText(turn.reasoning),
                                      const SizedBox(height: 8),
                                    ],
                                    Text(
                                      'Answer',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge,
                                    ),
                                    if (turn.response.isNotEmpty)
                                      SelectableText(turn.response)
                                    else if (turn.note == null)
                                      const Text('Waiting for response...'),
                                    if (turn.note != null) Text(turn.note!),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
