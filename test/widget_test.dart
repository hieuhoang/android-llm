import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_text_app/gmail_sender.dart';
import 'package:llm_text_app/main.dart';
import 'package:llm_text_app/local_agent.dart';
import 'package:llm_text_app/media_input.dart';
import 'package:llm_text_app/text_generator.dart';

class FakeMediaInput extends MediaInput {
  final resizeChoices = <(AttachmentKind, bool)>[];

  @override
  Future<PromptAttachment?> pick(
    AttachmentKind kind, {
    bool downsizeImages = false,
  }) async {
    resizeChoices.add((kind, downsizeImages));
    return PromptAttachment(
      kind: kind,
      path: '/test/${kind.name}',
      name: kind.name,
    );
  }

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
  bool? useGpu;
  bool? loadProjector;
  bool? stagedMultimodal;
  bool? generationProjector;
  bool? useAgent;
  EmailRequest? emailRequest;
  List<PromptAttachment>? attachments;
  bool cancelled = false;
  bool historyCleared = false;

  @override
  Future<void> load(
    void Function(double?) onProgress, {
    ModelChoice model = ModelChoice.qwen3,
    bool useGpu = false,
    bool loadProjector = true,
    bool stagedMultimodal = false,
  }) {
    this.model = model;
    this.useGpu = useGpu;
    this.loadProjector = loadProjector;
    this.stagedMultimodal = stagedMultimodal;
    progress = onProgress;
    return loading.future;
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
  }) {
    this.prompt = prompt;
    reasoningEnabled = enableReasoning;
    this.model = model;
    this.attachments = attachments;
    generationProjector = loadProjector;
    this.useAgent = useAgent;
    emailRequest = onEmailRequest;
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

class FakeGmailSender implements GmailSender {
  final result = Completer<String>();
  GmailDraft? sent;
  String? from;

  @override
  Future<String> account() async => 'sender@example.com';

  @override
  Future<String> send(GmailDraft draft, {required String from}) {
    sent = draft;
    this.from = from;
    return result.future;
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

  testWidgets('offline agent is opt-in and passed to generation', (
    tester,
  ) async {
    final generator = FakeGenerator()..loading.complete();
    await tester.pumpWidget(LlmTextApp(generator: generator));
    final checkbox = find.byKey(const Key('agent-checkbox'));
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('prompt-input')), 'What time?');
    await tester.pump();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(generator.useAgent, isTrue);
    expect(tester.widget<CheckboxListTile>(checkbox).onChanged, isNull);
    generator.output!.add(const GenerationChunk(text: 'Today'));
    await generator.output!.close();
    await tester.pump();
  });

  testWidgets(
    'email preview requires confirmation and reports the actual result',
    (tester) async {
      final generator = FakeGenerator()..loading.complete();
      final sender = FakeGmailSender();
      await tester.pumpWidget(
        LlmTextApp(generator: generator, gmailSender: sender),
      );
      await tester.enterText(
        find.byKey(const Key('prompt-input')),
        'Send email',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Generate'));
      await tester.tap(find.text('Generate'));
      await tester.pump();

      const draft = GmailDraft(
        to: 'recipient@example.com',
        subject: 'Subject',
        body: 'Message',
      );
      final declined = generator.emailRequest!(draft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('From: sender@example.com'), findsOneWidget);
      expect(find.text('To: recipient@example.com'), findsOneWidget);
      expect(find.text('Subject: Subject'), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);
      await tester.tap(find.text('Do not send'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect((await declined)['status'], 'declined');
      expect(sender.sent, isNull);
      expect(find.text('Email not sent.'), findsOneWidget);

      final approved = generator.emailRequest!(draft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, 'Send email'));
      await tester.pump();
      expect(sender.sent, same(draft));
      expect(sender.from, 'sender@example.com');
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Stop'))
            .onPressed,
        isNull,
      );
      sender.result.complete('message-123');
      await tester.pump();
      expect((await approved)['status'], 'sent');
      expect(
        find.text(
          'Email sent to recipient@example.com. Gmail message ID: message-123',
        ),
        findsOneWidget,
      );
      await generator.output!.close();
      await tester.pump();
    },
  );

  testWidgets('prompt input grows to at most two lines', (tester) async {
    final generator = FakeGenerator()..loading.complete();
    await tester.pumpWidget(LlmTextApp(generator: generator));

    final promptInput = tester.widget<TextField>(
      find.byKey(const Key('prompt-input')),
    );
    expect(promptInput.minLines, 1);
    expect(promptInput.maxLines, 2);
  });

  testWidgets('email send failures remain visible even if generation fails', (
    tester,
  ) async {
    final generator = FakeGenerator()..loading.complete();
    final sender = FakeGmailSender();
    await tester.pumpWidget(
      LlmTextApp(generator: generator, gmailSender: sender),
    );
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Send email');
    await tester.pump();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    final request = generator.emailRequest!(
      const GmailDraft(to: 'recipient@example.com', subject: 'Hi', body: 'x'),
    );
    final expectation = expectLater(request, throwsA(isA<StateError>()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Send email'));
    await tester.pump();
    sender.result.completeError(StateError('Outcome unknown'));
    await tester.pump();
    await expectation;
    generator.output!.addError(StateError('Generation failed'));
    await generator.output!.close();
    await tester.pump();
    expect(
      find.textContaining('Outcome unknown', findRichText: false),
      findsWidgets,
    );
    expect(find.textContaining('check Sent before retrying'), findsOneWidget);
  });

  testWidgets('GPU choice is applied on the next generation', (tester) async {
    final generator = FakeGenerator()..loading.complete();
    await tester.pumpWidget(LlmTextApp(generator: generator));
    final gpu = find.byKey(const Key('gpu-checkbox'));
    expect(tester.widget<CheckboxListTile>(gpu).value, isFalse);

    await tester.enterText(find.byKey(const Key('prompt-input')), 'First');
    await tester.pump();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(generator.useGpu, isFalse);
    expect(tester.widget<CheckboxListTile>(gpu).onChanged, isNull);
    generator.output!.add(const GenerationChunk(text: 'First answer'));
    await generator.output!.close();
    await tester.pump();

    await tester.ensureVisible(gpu);
    await tester.tap(gpu);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Second');
    await tester.pump();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(generator.useGpu, isTrue);
    generator.output!.add(const GenerationChunk(text: 'Second answer'));
    await generator.output!.close();
    await tester.pump();
    expect(find.text('First answer'), findsOneWidget);
    expect(find.text('Second answer'), findsOneWidget);

    await tester.ensureVisible(gpu);
    await tester.tap(gpu);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Third');
    await tester.pump();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(generator.useGpu, isFalse);
    await generator.output!.close();
    await tester.pump();
  });

  testWidgets('projector toggle controls media and model loading', (
    tester,
  ) async {
    final generator = FakeGenerator()..loading.complete();
    await tester.pumpWidget(
      LlmTextApp(generator: generator, media: FakeMediaInput()),
    );
    await tester.tap(find.byType(DropdownButtonFormField<ModelChoice>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Qwen2.5 Omni 3B Q4_K_M').last);
    await tester.pumpAndSettle();
    final projector = find.byKey(const Key('projector-checkbox'));
    final staged = find.byKey(const Key('staged-multimodal-checkbox'));
    expect(tester.widget<CheckboxListTile>(projector).value, isTrue);
    expect(tester.widget<CheckboxListTile>(staged).value, isFalse);
    await tester.ensureVisible(find.text('Add image'));
    await tester.tap(find.text('Add image'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(projector);
    await tester.tap(projector);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(staged).onChanged, isNull);
    expect(find.textContaining('Remove attachments or enable'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Add image'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Generate'))
          .onPressed,
      isNull,
    );
    await tester.ensureVisible(find.byTooltip('Remove attachment'));
    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Hello');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(generator.loadProjector, isFalse);
    expect(generator.generationProjector, isFalse);
    expect(tester.widget<CheckboxListTile>(projector).onChanged, isNull);
    generator.output!.add(const GenerationChunk(text: 'Hello back'));
    await generator.output!.close();
    await tester.pumpAndSettle();
    await tester.ensureVisible(projector);
    await tester.tap(projector);
    await tester.pumpAndSettle();
    await tester.ensureVisible(staged);
    await tester.tap(staged);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('prompt-input')), 'Again');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(generator.loadProjector, isTrue);
    expect(generator.stagedMultimodal, isTrue);
    expect(generator.generationProjector, isTrue);
    await generator.output!.close();
    await tester.pump();
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
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('reasoning-checkbox')))
          .onChanged,
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
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('reasoning-checkbox')))
          .value,
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

    await tester.ensureVisible(find.text('Clear conversation'));
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
    await tester.tap(find.text('Qwen2.5 Omni 3B Q2_K').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('reasoning-checkbox')))
          .onChanged,
      isNull,
    );
    await tester.ensureVisible(find.text('Add image'));
    await tester.tap(find.text('Add image'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add audio file'));
    await tester.tap(find.text('Add audio file'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Record audio'));
    await tester.tap(find.text('Record audio'));
    await tester.pumpAndSettle();
    expect(find.text('Stop recording'), findsOneWidget);
    await tester.tap(find.text('Stop recording'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(generator.model, ModelChoice.omniQ2);
    expect(generator.attachments!.map((a) => a.name), [
      'image',
      'audio',
      'Microphone recording',
    ]);
    await generator.output!.close();
    await tester.pump();
  });

  testWidgets('image downsizing applies only to newly selected images', (
    tester,
  ) async {
    final media = FakeMediaInput();
    final generator = FakeGenerator()..loading.complete();
    await tester.pumpWidget(LlmTextApp(generator: generator, media: media));
    await tester.tap(find.byType(DropdownButtonFormField<ModelChoice>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Qwen2.5 Omni 3B Q2_K').last);
    await tester.pumpAndSettle();

    final checkbox = find.byKey(const Key('downsize-images-checkbox'));
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    await tester.ensureVisible(find.text('Add image'));
    await tester.tap(find.text('Add image'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add image'));
    await tester.tap(find.text('Add image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add audio file'));
    await tester.pumpAndSettle();
    expect(media.resizeChoices, [
      (AttachmentKind.image, false),
      (AttachmentKind.image, true),
      (AttachmentKind.audio, false),
    ]);
  });

  for (final (label, model) in [
    ('Qwen2.5 Omni 3B Q4_K_M', ModelChoice.omniQ4),
    ('Qwen2.5 Omni 3B Q8_0', ModelChoice.omniQ8),
  ]) {
    testWidgets('$label selects the model and accepts media', (tester) async {
      final generator = FakeGenerator()..loading.complete();
      await tester.pumpWidget(
        LlmTextApp(generator: generator, media: FakeMediaInput()),
      );
      await tester.tap(find.byType(DropdownButtonFormField<ModelChoice>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('reasoning-checkbox')),
            )
            .onChanged,
        isNull,
      );
      await tester.ensureVisible(find.text('Add image'));
      await tester.tap(find.text('Add image'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Generate'));
      await tester.tap(find.text('Generate'));
      await tester.pump();
      expect(generator.model, model);
      expect(generator.attachments!.single.kind, AttachmentKind.image);
      await generator.output!.close();
      await tester.pump();
    });
  }
}
