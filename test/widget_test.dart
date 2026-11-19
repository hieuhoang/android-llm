import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_text_app/main.dart';
import 'package:llm_text_app/media_input.dart';
import 'package:llm_text_app/text_generator.dart';

class FakeMediaInput extends MediaInput {
  @override
  Future<PromptAttachment?> pick(AttachmentKind kind) async =>
      PromptAttachment(kind: kind, path: '/test/${kind.name}', name: kind.name);

  @override
  Future<void> startRecording() async {}

  @override
  Future<PromptAttachment> stopRecording() async => const PromptAttachment(
    kind: AttachmentKind.audio,
    path: '/test/recording.wav',
    name: 'Microphone recording',
  );
}

class FakeGenerator implements TextGenerator {
  final loading = Completer<void>();
  StreamController<GenerationChunk>? output;
  void Function(double?)? progress;
  String? prompt;
  bool? reasoningEnabled;
  ModelChoice? model;
  List<PromptAttachment>? attachments;
  bool cancelled = false;
  bool historyCleared = false;

  @override
  Future<void> load(
    void Function(double?) onProgress, {
    ModelChoice model = ModelChoice.qwen3,
  }) {
    this.model = model;
    progress = onProgress;
    return loading.future;
  }

  @override
  Stream<GenerationChunk> generate(
    String prompt, {
    bool enableReasoning = true,
    ModelChoice model = ModelChoice.qwen3,
    List<PromptAttachment> attachments = const [],
  }) {
    this.prompt = prompt;
    reasoningEnabled = enableReasoning;
    this.model = model;
    this.attachments = attachments;
    output = StreamController<GenerationChunk>();
    return output!.stream;
  }

  @override
  void clearHistory() => historyCleared = true;

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    await output?.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const buildChannel = MethodChannel('llm_text_app/build_info');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(buildChannel, (call) async {
          if (call.method == 'buildTimestamp') return '2026-01-02T03:04:05Z';
          throw MissingPluginException();
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(buildChannel, null);
  });

  testWidgets('loads model and streams output for a nonempty prompt', (
    tester,
  ) async {
    final generator = FakeGenerator();
    await tester.pumpWidget(LlmTextApp(generator: generator));
    await tester.pump();
    final localBuildTime = DateTime.utc(
      2026,
      1,
      2,
      3,
      4,
      5,
    ).toLocal().toString().split('.').first;
    expect(find.text('Built: $localBuildTime (local time)'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, 'Generate');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('prompt-input')), '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('prompt-input')), ' Hello ');
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Clear conversation'),
          )
          .onPressed,
      isNull,
    );
    generator.progress!(0.5);
    await tester.pump();
    expect(find.text('Downloading model: 50%'), findsOneWidget);

    generator.loading.complete();
    await tester.pump();
    expect(generator.prompt, 'Hello');
    expect(generator.reasoningEnabled, isTrue);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNull,
    );
    generator.output!.add(const GenerationChunk(reasoning: 'Thinking...'));
    await tester.pump();
    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.text('Thinking...'), findsOneWidget);
    generator.output!.add(const GenerationChunk(text: 'Hi'));
    await tester.pump();
    expect(find.text('Hi'), findsOneWidget);
    generator.output!.add(const GenerationChunk(text: ' there'));
    await tester.pump();
    expect(find.text('Hi there'), findsOneWidget);
    await generator.output!.close();
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('prompt-input')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('Hello'), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    await tester.tap(find.text('Enable reasoning'));
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Follow up');
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    expect(generator.reasoningEnabled, isFalse);
    generator.output!.add(const GenerationChunk(text: 'Second response'));
    await generator.output!.close();
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Hi there'), findsOneWidget);
    expect(find.text('Thinking...'), findsOneWidget);
    expect(find.text('Follow up'), findsOneWidget);
    expect(find.text('Second response'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('prompt-input')))
          .controller!
          .text,
      isEmpty,
    );

    await tester.tap(find.text('Clear conversation'));
    await tester.pump();
    expect(generator.historyCleared, isTrue);
    expect(find.text('Hello'), findsNothing);
    expect(find.text('Second response'), findsNothing);
    expect(find.text('Your conversation will appear here.'), findsOneWidget);
  });

  testWidgets('displays a loading error and allows retry', (tester) async {
    final generator = FakeGenerator();
    await tester.pumpWidget(LlmTextApp(generator: generator));
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Hello');
    await tester.pump();
    await tester.tap(find.text('Generate'));
    await tester.pump();
    generator.loading.completeError(Exception('Download failed'));
    await tester.pump();
    expect(find.textContaining('Download failed'), findsOneWidget);
    expect(find.text('Failed; not included in context.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('prompt-input')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('stop cancels loading and keeps the attempt visible', (
    tester,
  ) async {
    final generator = FakeGenerator();
    await tester.pumpWidget(LlmTextApp(generator: generator));
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Hello');
    await tester.pump();
    await tester.tap(find.text('Generate'));
    await tester.pump();
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(generator.cancelled, isTrue);
    generator.loading.completeError(Exception('Cancelled'));
    await tester.pump();
    expect(find.text('Stopped.'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Stopped; not included in context.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('prompt-input')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('keeps a partial response visible when stopped', (tester) async {
    final generator = FakeGenerator();
    generator.loading.complete();
    await tester.pumpWidget(LlmTextApp(generator: generator));
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Hello');
    await tester.pump();
    await tester.tap(find.text('Generate'));
    await tester.pump();
    generator.output!.add(const GenerationChunk(text: 'Partial answer'));
    await tester.pump();
    await tester.tap(find.text('Stop'));
    await tester.pump();
    await generator.output!.close();
    await tester.pump();
    expect(find.text('Partial answer'), findsOneWidget);
    expect(find.text('Stopped; partial response retained.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('prompt-input')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('a reasoning-only truncated turn is not included in context', (
    tester,
  ) async {
    final generator = FakeGenerator();
    generator.loading.complete();
    await tester.pumpWidget(LlmTextApp(generator: generator));
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Question');
    await tester.pump();
    await tester.tap(find.text('Generate'));
    await tester.pump();
    generator.output!.add(
      const GenerationChunk(reasoning: 'Working on it', truncated: true),
    );
    await generator.output!.close();
    await tester.pump();
    expect(find.text('Working on it'), findsOneWidget);
    expect(
      find.text(
        'Token limit reached before a final answer; not included in context.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('stopped reasoning remains visible without entering context', (
    tester,
  ) async {
    final generator = FakeGenerator();
    generator.loading.complete();
    await tester.pumpWidget(LlmTextApp(generator: generator));
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Question');
    await tester.pump();
    await tester.tap(find.text('Generate'));
    await tester.pump();
    generator.output!.add(const GenerationChunk(reasoning: 'Partial thought'));
    await tester.pump();
    await tester.tap(find.text('Stop'));
    await tester.pump();
    await generator.output!.close();
    await tester.pump();
    expect(find.text('Partial thought'), findsOneWidget);
    expect(find.text('Stopped; not included in context.'), findsOneWidget);
  });

  testWidgets('selects Omni, attaches media and records audio', (tester) async {
    final generator = FakeGenerator();
    generator.loading.complete();
    await tester.pumpWidget(
      LlmTextApp(generator: generator, media: FakeMediaInput()),
    );
    await tester.tap(find.byType(DropdownButtonFormField<ModelChoice>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Qwen2.5 Omni 3B (text, image, audio)').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNull,
    );
    await tester.tap(find.text('Add image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add audio file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record audio'));
    await tester.pumpAndSettle();
    expect(find.text('Stop recording'), findsOneWidget);
    await tester.tap(find.text('Stop recording'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(generator.model, ModelChoice.omni);
    expect(generator.attachments!.map((a) => a.name), [
      'image',
      'audio',
      'Microphone recording',
    ]);
    await generator.output!.close();
    await tester.pump();
  });
}
