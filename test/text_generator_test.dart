import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llm_text_app/local_agent.dart';
import 'package:llm_text_app/model_storage.dart';
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
  final toolCalls = <List<LlamaCompletionChunkToolCall>>[];
  final requestedTools = <List<ToolDefinition>?>[];
  LlamaModel? loadedModel;
  bool failNext = false;
  bool failAfterReply = false;
  int tokensPerMessage = 400;
  String finishReason = 'stop';

  @override
  Future<void> setModel(
    LlamaModel model, {
    ModelParams params = const ModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    loadedModel = model;
  }

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
    requestedTools.add(tools);
    thinkingModes.add(enableThinking);
    parameters.add(params);
    if (failNext) {
      failNext = false;
      return Stream.error(StateError('Generation failed'));
    }
    final calls = toolCalls.isEmpty
        ? <LlamaCompletionChunkToolCall>[]
        : toolCalls.removeAt(0);
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
            toolCalls: calls,
          ),
          finishReason: calls.isEmpty ? finishReason : 'tool_calls',
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

class FakeModelStore implements AppModelFileStore {
  final artifacts = <ModelArtifact>[];

  @override
  Future<String> obtain(
    ModelArtifact artifact, {
    required int completedBytes,
    required int totalBytes,
    required void Function(double?) onProgress,
    required ModelDownloadCancelToken cancelToken,
  }) async {
    artifacts.add(artifact);
    return '/models/${artifact.filename}';
  }

  @override
  void cancel() {}
}

void main() {
  LlamaCompletionChunkToolCall toolCall(
    String name,
    String arguments, {
    int index = 0,
  }) => LlamaCompletionChunkToolCall(
    index: index,
    id: 'call_$index',
    type: 'function',
    function: LlamaCompletionChunkFunction(name: name, arguments: arguments),
  );

  test(
    'offline agent runs its clock tool and retains a clean conversation',
    () async {
      final engine = RecordingEngine()
        ..replies.addAll(['', 'It is today.', 'Follow-up.'])
        ..toolCalls.add([toolCall('get_current_time', '{}')]);
      final generator = LocalTextGenerator(engine: engine);

      final answer = await generator
          .generate('What time is it?', useAgent: true)
          .map((chunk) => chunk.text)
          .join();
      expect(answer, 'It is today.');
      expect(
        engine.requestedTools.first!.map((tool) => tool.name),
        contains('get_current_time'),
      );
      final toolResult =
          engine.requests[1].last.parts.single as LlamaToolResultContent;
      expect(toolResult.name, 'get_current_time');
      expect((toolResult.result as Map)['local_time'], isA<String>());

      await generator.generate('Next').drain<void>();
      expect(engine.requests.last.map((message) => message.role), [
        LlamaChatRole.user,
        LlamaChatRole.assistant,
        LlamaChatRole.user,
      ]);
      expect(engine.requests.last[1].content, 'It is today.');
    },
  );

  for (final model in [
    ModelChoice.omniQ2,
    ModelChoice.omniQ4,
    ModelChoice.omniQ8,
  ]) {
    test(
      '$model agent supplies tool definitions and runs the calculator',
      () async {
        final engine = RecordingEngine()
          ..replies.addAll(['', 'Six.', 'Next.'])
          ..toolCalls.add([
            toolCall('calculate', '{"left":2,"operator":"multiply","right":3}'),
          ]);
        final generator = LocalTextGenerator(engine: engine);
        Calculation? calculation;
        final answer = await generator
            .generate(
              'Multiply 2 by 3.',
              model: model,
              useAgent: true,
              onCalculation: (value) => calculation = value,
            )
            .map((chunk) => chunk.text)
            .join();
        expect(answer, 'Six.');
        expect(calculation?.result, 6);
        expect(engine.requests.first.first.role, LlamaChatRole.system);
        expect(engine.requests.first.first.content, contains('"calculate"'));
        expect(engine.thinkingModes, [false, false]);
        await generator.generate('Next', model: model).drain<void>();
        expect(engine.requests.last.first.role, LlamaChatRole.user);
      },
    );
  }

  test(
    'agent rejects current and previous media without losing history',
    () async {
      final engine = RecordingEngine()..replies.addAll(['Seen', 'Answer']);
      final generator = LocalTextGenerator(engine: engine);
      const image = PromptAttachment(
        kind: AttachmentKind.image,
        path: '/test/image.jpg',
        name: 'image.jpg',
      );
      await expectLater(
        generator
            .generate(
              'Describe',
              model: ModelChoice.omniQ2,
              useAgent: true,
              attachments: [image],
            )
            .drain<void>(),
        throwsArgumentError,
      );
      await generator
          .generate('Describe', model: ModelChoice.omniQ2, attachments: [image])
          .drain<void>();
      await expectLater(
        generator
            .generate('Follow up', model: ModelChoice.omniQ2, useAgent: true)
            .drain<void>(),
        throwsArgumentError,
      );
      await generator
          .generate(
            'Follow up',
            model: ModelChoice.omniQ2,
            loadProjector: false,
            useAgent: true,
          )
          .drain<void>();
      expect(engine.requests.last[1].content, 'Describe\n[Image attached]');
    },
  );

  test(
    'offline agent rejects unknown tools and restores prior history',
    () async {
      final engine = RecordingEngine()
        ..replies.addAll(['First answer', '', 'Next answer'])
        ..toolCalls.addAll([
          [],
          [toolCall('send_email', '{}')],
        ]);
      final generator = LocalTextGenerator(engine: engine);
      await generator.generate('First').drain<void>();
      await expectLater(
        generator.generate('Send email', useAgent: true).drain<void>(),
        throwsA(isA<StateError>()),
      );
      await generator.generate('Next').drain<void>();
      expect(engine.requests.last.map((message) => message.content), [
        'First',
        'First answer',
        'Next',
      ]);
    },
  );

  test('offline agent rejects unexpected clock arguments', () async {
    final engine = RecordingEngine()
      ..replies.add('')
      ..toolCalls.add([toolCall('get_current_time', '{"unexpected":true}')]);
    final generator = LocalTextGenerator(engine: engine);

    await expectLater(
      generator.generate('Time?', useAgent: true).drain<void>(),
      throwsA(isA<FormatException>()),
    );
    expect(engine.requests, hasLength(1));
  });

  test(
    'calculator runs each operation and returns its result to the model',
    () async {
      for (final (operator, expected) in [
        ('add', 9.0),
        ('subtract', 3.0),
        ('multiply', 18.0),
        ('divide', 2.0),
      ]) {
        final engine = RecordingEngine()
          ..tokensPerMessage = 50
          ..replies.addAll(['', 'Done'])
          ..toolCalls.add([
            toolCall(
              'calculate',
              '{"left":6,"operator":"$operator","right":3}',
            ),
          ]);
        final descriptions = <String>[];
        await LocalTextGenerator(engine: engine)
            .generate(
              'Calculate',
              useAgent: true,
              onCalculation: (calculation) {
                descriptions.add(calculation.description);
              },
            )
            .drain<void>();
        final result =
            engine.requests[1].last.parts.single as LlamaToolResultContent;
        expect(result.name, 'calculate');
        expect((result.result as Map)['result'], expected);
        expect(descriptions.single, contains('= $expected'));
      }
    },
  );

  test(
    'calculator rejects malformed arguments, division by zero and overflow',
    () async {
      for (final arguments in [
        '{"left":1,"operator":"divide","right":0}',
        '{"left":1,"operator":"power","right":2}',
        '{"left":"1","operator":"add","right":2}',
        '{"left":1,"operator":"add","right":2,"extra":1}',
        '{"left":1e308,"operator":"multiply","right":1e308}',
      ]) {
        final engine = RecordingEngine()
          ..replies.add('')
          ..toolCalls.add([toolCall('calculate', arguments)]);
        var callbacks = 0;
        await expectLater(
          LocalTextGenerator(engine: engine)
              .generate(
                'Calculate',
                useAgent: true,
                onCalculation: (_) => callbacks++,
              )
              .drain<void>(),
          throwsA(isA<FormatException>()),
        );
        expect(callbacks, 0);
      }
    },
  );

  test(
    'agent requests approval once and passes the result back to the model',
    () async {
      final engine = RecordingEngine()
        ..tokensPerMessage = 50
        ..replies.addAll(['', 'Done'])
        ..toolCalls.add([
          toolCall(
            'gmail_send',
            '{"to":"person@example.com","subject":"Hello","body":"Hi"}',
          ),
        ]);
      final generator = LocalTextGenerator(engine: engine);
      var requests = 0;
      await generator
          .generate(
            'Email',
            useAgent: true,
            onEmailRequest: (draft) async {
              requests++;
              expect(draft.to, 'person@example.com');
              expect(draft.subject, 'Hello');
              expect(draft.body, 'Hi');
              return {'status': 'declined'};
            },
          )
          .drain<void>();
      expect(requests, 1);
      expect(
        engine.requestedTools.first!.map((t) => t.name),
        contains('gmail_send'),
      );
      final result =
          engine.requests[1].last.parts.single as LlamaToolResultContent;
      expect((result.result as Map)['status'], 'declined');
    },
  );

  test('agent rejects malformed email and repeated proposals', () async {
    for (final arguments in [
      '{"to":"person@example.com\\r\\nBcc: other@example.com","subject":"Hi","body":"x"}',
      '{"to":"person@example.com","subject":"Hi\\nBcc: x","body":"x"}',
      '{"to":"person@example.com","subject":"Hi","body":"x","bcc":"other@example.com"}',
    ]) {
      final engine = RecordingEngine()
        ..replies.add('')
        ..toolCalls.add([toolCall('gmail_send', arguments)]);
      var requests = 0;
      await expectLater(
        LocalTextGenerator(engine: engine)
            .generate(
              'Email',
              useAgent: true,
              onEmailRequest: (draft) async {
                requests++;
                return {'status': 'sent'};
              },
            )
            .drain<void>(),
        throwsA(isA<FormatException>()),
      );
      expect(requests, 0);
    }
    final engine = RecordingEngine()
      ..tokensPerMessage = 50
      ..replies.addAll(['', ''])
      ..toolCalls.addAll(
        List.generate(
          2,
          (_) => [
            toolCall(
              'gmail_send',
              '{"to":"person@example.com","subject":"Hi","body":"x"}',
            ),
          ],
        ),
      );
    var requests = 0;
    await expectLater(
      LocalTextGenerator(engine: engine)
          .generate(
            'Email',
            useAgent: true,
            onEmailRequest: (draft) async {
              requests++;
              return {'status': 'declined'};
            },
          )
          .drain<void>(),
      throwsA(isA<StateError>()),
    );
    expect(requests, 1);
  });

  test('concurrent email proposals cannot send more than one email', () async {
    const arguments = '{"to":"person@example.com","subject":"Hi","body":"x"}';
    final engine = RecordingEngine()
      ..replies.add('')
      ..toolCalls.add([
        toolCall('gmail_send', arguments),
        toolCall('gmail_send', arguments, index: 1),
      ]);
    final approval = Completer<Map<String, String>>();
    var requests = 0;
    final result = LocalTextGenerator(engine: engine)
        .generate(
          'Email',
          useAgent: true,
          onEmailRequest: (draft) {
            requests++;
            return approval.future;
          },
        )
        .drain<void>();
    final expectation = expectLater(result, throwsA(isA<StateError>()));
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    approval.complete({'status': 'sent'});
    await expectation;
    expect(requests, 1);
  });

  test('offline agent stops repeated calls at its round limit', () async {
    final engine = RecordingEngine()
      ..tokensPerMessage = 50
      ..replies.addAll(['', '', '', '', 'Next answer'])
      ..toolCalls.addAll(
        List.generate(4, (_) => [toolCall('get_current_time', '{}')]),
      );
    final generator = LocalTextGenerator(engine: engine);
    await expectLater(
      generator.generate('Time?', useAgent: true).drain<void>(),
      throwsA(isA<StateError>()),
    );
    expect(engine.requests, hasLength(4));
    await generator.generate('Next').drain<void>();
    expect(engine.requests.last.single.content, 'Next');
  });

  test('loads Linux models from the local model store', () async {
    final store = FakeModelStore();
    final engine = RecordingEngine();
    final generator = LocalTextGenerator(engine: engine, modelStore: store);

    await generator.load((_) {});

    expect(store.artifacts.single.key, 'qwen3');
    expect(engine.loadedModel, isNotNull);
  }, skip: !Platform.isLinux);

  for (final model in [
    ModelChoice.omniQ2,
    ModelChoice.omniQ4,
    ModelChoice.omniQ8,
  ]) {
    test(
      '$model uses the 8192-token budget and switches back to Qwen3 limits',
      () async {
        final engine = RecordingEngine()
          ..replies.addAll(['A1', 'A2', 'A3', 'A4', 'A5']);
        final generator = LocalTextGenerator(engine: engine);

        await generator.generate('P1', model: model).drain<void>();
        await generator.generate('P2', model: model).drain<void>();
        engine.tokensPerMessage = 1536;
        await generator.generate('P3', model: model).drain<void>();
        expect(engine.requests.last.map((message) => message.content), [
          'P1',
          'A1',
          'P2',
          'A2',
          'P3',
        ]);

        engine.tokensPerMessage = 1098;
        await generator.generate('P4', model: model).drain<void>();
        expect(engine.requests.last.map((message) => message.content), [
          'P2',
          'A2',
          'P3',
          'A3',
          'P4',
        ]);

        engine.tokensPerMessage = 600;
        await generator.generate('P5', model: ModelChoice.qwen3).drain<void>();
        expect(engine.requests.last.map((message) => message.content), ['P5']);
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

  test(
    'Omni without a projector uses media placeholders and rejects attachments',
    () async {
      final engine = RecordingEngine()
        ..tokensPerMessage = 100
        ..replies.addAll(['Seen', 'Text reply', 'Another reply']);
      final generator = LocalTextGenerator(engine: engine);
      const image = PromptAttachment(
        kind: AttachmentKind.image,
        path: '/test/image.jpg',
        name: 'image.jpg',
      );
      await generator
          .generate('Describe', model: ModelChoice.omniQ4, attachments: [image])
          .drain<void>();
      await expectLater(
        generator
            .generate(
              'Describe',
              model: ModelChoice.omniQ4,
              loadProjector: false,
              attachments: [image],
            )
            .drain<void>(),
        throwsArgumentError,
      );
      await generator
          .generate(
            'Follow up',
            model: ModelChoice.omniQ4,
            loadProjector: false,
          )
          .drain<void>();
      expect(engine.requests.last.first.content, 'Describe\n[Image attached]');
      expect(
        engine.requests.last.first.parts.every(
          (part) => part is LlamaTextContent,
        ),
        isTrue,
      );
      await generator.generate('Next', model: ModelChoice.omniQ4).drain<void>();
      expect(engine.requests.last.first.content, 'Describe\n[Image attached]');
    },
  );

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
