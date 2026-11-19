import 'dart:async';

import 'package:flutter/material.dart';

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

class _PromptScreenState extends State<PromptScreen> {
  final _promptController = TextEditingController();
  late final TextGenerator _generator =
      widget.generator ?? LocalTextGenerator();
  String _output = 'Generated text will appear here.';
  String _status = 'Model downloads on first use (639 MB).';
  bool _busy = false;
  bool _cancelled = false;
  double? _progress;
  String? _stopError;

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
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _cancelled = false;
      _stopError = null;
      _progress = null;
      _status = 'Preparing model (first download: 639 MB)...';
      _output = '';
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
      await for (final text in _generator.generate(prompt)) {
        if (!mounted) break;
        setState(() => _output += text);
      }
      if (mounted && !_cancelled) {
        setState(() {
          _status = 'Ready';
          if (_output.isEmpty) _output = 'The model returned no text.';
        });
      }
    } catch (error) {
      if (mounted && !_cancelled) {
        setState(() => _status = 'Error: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          if (_cancelled) {
            _status = _stopError ?? 'Stopped. Tap Generate to retry.';
          }
        });
      }
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
                  Text(
                    'Prompt',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('prompt-input'),
                    controller: _promptController,
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
                  Text(
                    'Output',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    key: const Key('output-area'),
                    constraints: const BoxConstraints(minHeight: 160),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.topLeft,
                    child: Text(
                      _output,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
