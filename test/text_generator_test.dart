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
  bool failNext = false;

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
  }) async =>
      LlamaChatTemplateResult(prompt: '', tokenCount: messages.length * 400);

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
    if (failNext) {
      failNext = false;
      return Stream.error(StateError('Generation failed'));
    }
    return Stream.value(
      LlamaCompletionChunk(
        id: 'test',
        object: 'chat.completion.chunk',
        created: 0,
        model: 'test',
        choices: [
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(content: replies.removeAt(0)),
            finishReason: 'stop',
          ),
        ],
      ),
    );
  }
}

void main() {
  test(
    'follow-ups include previous turns and trim the oldest when full',
    () async {
      final engine = RecordingEngine()
        ..replies.addAll(['First answer', 'Second answer', 'Third answer']);
      final generator = LocalTextGenerator(engine: engine);

      expect(await generator.generate('First prompt').join(), 'First answer');
      expect(await generator.generate('Second prompt').join(), 'Second answer');
      expect(
        engine.requests[1].map((message) => (message.role, message.content)),
        [
          (LlamaChatRole.user, 'First prompt'),
          (LlamaChatRole.assistant, 'First answer'),
          (LlamaChatRole.user, 'Second prompt'),
        ],
      );

      expect(await generator.generate('Third prompt').join(), 'Third answer');
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
}
