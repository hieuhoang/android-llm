import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llm_text_app/text_generator.dart';

class IdleBackend implements LlamaBackend {
  @override
  void cancelGeneration() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class RecordingEngine extends LlamaEngine {
  RecordingEngine() : super(IdleBackend());

  final requests = <List<LlamaChatMessage>>[];
  final replies = <String>[];
  final reasonings = <String>[];
  final thinkingModes = <bool>[];
  final parameters = <GenerationParams?>[];
  bool failNext = false;
  bool failAfterReply = false;
  int tokensPerMessage = 400;
  String finishReason = 'stop';

  @override
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    Map<String, dynamic>? jsonSchema,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? customTemplate,
    String? sourceLangCode,
    String? targetLangCode,
    bool includeTokenCount = true,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async => LlamaChatTemplateResult(
    prompt: '',
    tokenCount: messages.length * tokensPerMessage,
  );

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) {
    requests.add(List.of(messages));
    thinkingModes.add(enableThinking);
    parameters.add(params);
    if (failNext) {
      failNext = false;
      return Stream.error(StateError('Generation failed'));
    }
    final chunk = LlamaCompletionChunk(
      id: 'test',
      object: 'chat.completion.chunk',
      created: 0,
      model: 'test',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            content: replies.removeAt(0),
            thinking: reasonings.isEmpty ? null : reasonings.removeAt(0),
          ),
          finishReason: finishReason,
        ),
      ],
    );
    if (failAfterReply) {
      failAfterReply = false;
      return () async* {
        yield chunk;
        throw StateError('Generation failed after output');
      }();
    }
    return Stream.value(chunk);
  }
}

void main() {
  for (final model in [
    ModelChoice.omniQ2,
    ModelChoice.omniQ4,
    ModelChoice.omniQ8,
  ]) {
    test(
      '$model retains more history and switches back to Qwen3 limits',
      () async {
        final engine = RecordingEngine()
          ..tokensPerMessage = 600
          ..replies.addAll(['A1', 'A2', 'A3', 'A4']);
        final generator = LocalTextGenerator(engine: engine);

        await generator.generate('P1', model: model).drain<void>();
        await generator.generate('P2', model: model).drain<void>();
        await generator.generate('P3', model: model).drain<void>();
        expect(engine.requests.last.map((message) => message.content), [
          'P1',
          'A1',
          'P2',
          'A2',
          'P3',
        ]);

        await generator.generate('P4', model: ModelChoice.qwen3).drain<void>();
        expect(engine.requests.last.map((message) => message.content), ['P4']);
      },
    );
  }

  test(
    'follow-ups include previous turns and trim the oldest when full',
    () async {
      final engine = RecordingEngine()
        ..replies.addAll(['First answer', 'Second answer', 'Third answer']);
      final generator = LocalTextGenerator(engine: engine);

      expect(
        await generator.generate('First prompt').map((c) => c.text).join(),
        'First answer',
      );
      expect(
        await generator.generate('Second prompt').map((c) => c.text).join(),
        'Second answer',
      );
      expect(
        engine.requests[1].map((message) => (message.role, message.content)),
        [
          (LlamaChatRole.user, 'First prompt'),
          (LlamaChatRole.assistant, 'First answer'),
          (LlamaChatRole.user, 'Second prompt'),
        ],
      );

      expect(
        await generator.generate('Third prompt').map((c) => c.text).join(),
        'Third answer',
      );
      expect(
        engine.requests[2].map((message) => (message.role, message.content)),
        [
          (LlamaChatRole.user, 'Second prompt'),
          (LlamaChatRole.assistant, 'Second answer'),
          (LlamaChatRole.user, 'Third prompt'),
        ],
      );
    },
  );

  test('streams reasoning but excludes it from later model requests', () async {
    final engine = RecordingEngine()
      ..replies.addAll(['Answer', 'Follow-up answer'])
      ..reasonings.add('Private prior thought');
    final generator = LocalTextGenerator(engine: engine);
    final chunks = await generator.generate('Question').toList();
    expect(chunks.single.reasoning, 'Private prior thought');
    expect(chunks.single.text, 'Answer');
    expect(engine.thinkingModes.single, isTrue);
    expect(engine.parameters.single!.thinkingBudget!.maxTokens, 256);

    await generator.generate('Follow-up').drain<void>();
    final previousAnswer = engine.requests.last[1];
    expect(previousAnswer.content, 'Answer');
    expect(previousAnswer.reasoning, isNull);
  });

  test('disabling reasoning removes the thinking budget', () async {
    final engine = RecordingEngine()..replies.add('Answer');
    final generator = LocalTextGenerator(engine: engine);
    await generator.generate('Question', enableReasoning: false).drain<void>();
    expect(engine.thinkingModes.single, isFalse);
    expect(engine.parameters.single!.thinkingBudget, isNull);
  });

  test(
    'Omni sends media and text-only follow-up replaces it with placeholders',
    () async {
      final engine = RecordingEngine()
        ..replies.addAll([
          'Seen',
          'Another answer',
          'Third answer',
          'Follow-up',
        ])
        ..tokensPerMessage = 200;
      final generator = LocalTextGenerator(engine: engine);
      await generator
          .generate(
            'Describe',
            model: ModelChoice.omniQ2,
            attachments: const [
              PromptAttachment(
                kind: AttachmentKind.image,
                path: '/test/image.jpg',
                name: 'image.jpg',
              ),
              PromptAttachment(
                kind: AttachmentKind.audio,
                path: '/test/audio.wav',
                name: 'audio.wav',
              ),
            ],
          )
          .drain<void>();
      expect(
        engine.requests.first.single.parts.map((part) => part.runtimeType),
        [LlamaTextContent, LlamaImageContent, LlamaAudioContent],
      );
      expect(engine.thinkingModes.first, isFalse);
      expect(engine.parameters.first!.thinkingBudget, isNull);
      await generator
          .generate('Another question', model: ModelChoice.omniQ4)
          .drain<void>();
      expect(engine.requests.last.first.parts.map((part) => part.runtimeType), [
        LlamaTextContent,
        LlamaImageContent,
        LlamaAudioContent,
      ]);
      await generator
          .generate('Third question', model: ModelChoice.omniQ8)
          .drain<void>();
      expect(engine.requests.last.first.parts.map((part) => part.runtimeType), [
        LlamaTextContent,
        LlamaImageContent,
        LlamaAudioContent,
      ]);
      expect(engine.thinkingModes, [false, false, false]);
      await generator.generate('Follow up').drain<void>();
      expect(engine.requests.last.map((message) => message.content), [
        'Describe\n[Image attached]\n[Audio attached]',
        'Seen',
        'Another question',
        'Another answer',
        'Third question',
        'Third answer',
        'Follow up',
      ]);
    },
  );

  test('text model rejects new media', () async {
    final generator = LocalTextGenerator(engine: RecordingEngine());
    await expectLater(
      generator
          .generate(
            'Question',
            attachments: const [
              PromptAttachment(
                kind: AttachmentKind.image,
                path: '/test/image.jpg',
                name: 'image.jpg',
              ),
            ],
          )
          .drain<void>(),
      throwsArgumentError,
    );
  });

  test('reasoning without a final answer is not added to history', () async {
    final engine = RecordingEngine()
      ..replies.addAll(['', 'Next answer'])
      ..reasonings.add('Unfinished thought');
    final generator = LocalTextGenerator(engine: engine);
    await generator.generate('Unfinished question').drain<void>();
    await generator.generate('Next question').drain<void>();
    expect(engine.requests.last.map((message) => message.content), [
      'Next question',
    ]);
  });

  test('failed partial answer retains text but not reasoning', () async {
    final engine = RecordingEngine()
      ..replies.addAll(['Partial answer', 'Next answer'])
      ..reasonings.add('Partial reasoning')
      ..failAfterReply = true;
    final generator = LocalTextGenerator(engine: engine);
    await expectLater(
      generator.generate('Question').drain<void>(),
      throwsStateError,
    );
    await generator.generate('Next question').drain<void>();
    expect(engine.requests.last.map((message) => message.content), [
      'Question',
      'Partial answer',
      'Next question',
    ]);
    expect(engine.requests.last[1].reasoning, isNull);
  });

  test('a truncated response is reported', () async {
    final engine = RecordingEngine()
      ..replies.add('Incomplete answer')
      ..finishReason = 'length';
    final generator = LocalTextGenerator(engine: engine);
    final chunks = await generator.generate('Question').toList();
    expect(chunks.single.text, 'Incomplete answer');
    expect(chunks.single.truncated, isTrue);
  });

  test('cancelled reasoning-only output restores earlier history', () async {
    final engine = RecordingEngine()
      ..replies.addAll(['Earlier answer', '', 'Next answer'])
      ..reasonings.addAll(['', 'Unfinished reasoning']);
    final generator = LocalTextGenerator(engine: engine);
    await generator.generate('Earlier question').drain<void>();
    await generator.generate('Stopped question').take(1).toList();
    await generator.generate('Next question').drain<void>();
    expect(engine.requests.last.map((message) => message.content), [
      'Earlier question',
      'Earlier answer',
      'Next question',
    ]);
  });

  test('a failed request does not leave a duplicate turn in history', () async {
    final engine = RecordingEngine()
      ..replies.addAll(['First answer', 'Retry answer']);
    final generator = LocalTextGenerator(engine: engine);
    await generator.generate('First prompt').drain<void>();
    engine.failNext = true;
    await expectLater(
      generator.generate('Retry prompt').drain<void>(),
      throwsStateError,
    );
    await generator.generate('Retry prompt').drain<void>();
    expect(engine.requests.last.map((message) => message.content), [
      'First prompt',
      'First answer',
      'Retry prompt',
    ]);
  });

  test(
    'clearing history excludes previous turns from the next request',
    () async {
      final engine = RecordingEngine()
        ..replies.addAll(['Answer', 'New answer']);
      final generator = LocalTextGenerator(engine: engine);
      await generator.generate('Old prompt').drain<void>();

      generator.clearHistory();
      await generator.generate('New prompt').drain<void>();

      expect(
        engine.requests.last.map((message) => (message.role, message.content)),
        [(LlamaChatRole.user, 'New prompt')],
      );
    },
  );
}
