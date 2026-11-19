import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'text_generator.dart';

void main() {
  runApp(const LlmTextApp());
}

class LlmTextApp extends StatelessWidget {
  const LlmTextApp({super.key, this.generator});

  final TextGenerator? generator;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LLM Text',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5367D5)),
        useMaterial3: true,
      ),
      home: PromptScreen(generator: generator),
    );
  }
}

class PromptScreen extends StatefulWidget {
  const PromptScreen({super.key, this.generator});

  final TextGenerator? generator;

  @override
  State<PromptScreen> createState() => _PromptScreenState();
}

class _ConversationTurn {
  _ConversationTurn(this.prompt);

  final String prompt;
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
  String _status = 'Model downloads on first use (639 MB).';
  bool _busy = false;
  bool _enableReasoning = true;
  bool _cancelled = false;
  double? _progress;
  String? _stopError;
  final Future<DateTime> _buildTimestamp =
      const MethodChannel('llm_text_app/build_info')
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
  }

  Future<void> _generate() async {
    final prompt = _promptController.text.trim();
    if (_busy || prompt.isEmpty) return;
    final turn = _ConversationTurn(prompt);
    FocusScope.of(context).unfocus();
    setState(() {
      _conversation.add(turn);
      _busy = true;
      _cancelled = false;
      _stopError = null;
      _progress = null;
      _status = 'Preparing model (first download: 639 MB)...';
    });
    try {
      await _generator.load((progress) {
        if (!mounted || _cancelled) return;
        setState(() {
          _progress = progress;
          _status = progress == null
              ? 'Preparing model...'
              : 'Downloading model: ${(progress * 100).toStringAsFixed(0)}%';
        });
      });
      if (!mounted || _cancelled) return;
      setState(() {
        _status = 'Generating...';
        _progress = null;
      });
      await for (final chunk in _generator.generate(
        prompt,
        enableReasoning: _enableReasoning,
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
      if (mounted) {
        setState(() {
          _promptController.clear();
          _busy = false;
          if (_cancelled) {
            _status = _stopError ?? 'Stopped.';
            turn.note = turn.response.trim().isEmpty
                ? 'Stopped; not included in context.'
                : 'Stopped; partial response retained.';
          }
        });
      }
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
                  Text(
                    'Prompt',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('prompt-input'),
                    controller: _promptController,
                    enabled: !_busy,
                    minLines: 4,
                    maxLines: 8,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText:
                          'Enter the text you want the model to respond to...',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable reasoning'),
                    value: _enableReasoning,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _enableReasoning = value ?? false;
                          }),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  FilledButton(
                    onPressed: _busy || _promptController.text.trim().isEmpty
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
                        onPressed: _busy || _conversation.isEmpty
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
