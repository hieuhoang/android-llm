import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import 'gmail_sender.dart';

typedef EmailRequest = Future<Map<String, String>> Function(GmailDraft draft);

class Calculation {
  const Calculation(this.left, this.operator, this.right, this.result);

  final num left;
  final String operator;
  final num right;
  final double result;

  String get description {
    final symbol = switch (operator) {
      'add' => '+',
      'subtract' => '-',
      'multiply' => '*',
      'divide' => '/',
      _ => throw StateError('Unknown calculator operator.'),
    };
    return '$left $symbol $right = $result';
  }
}

class LocalAgent {
  LocalAgent({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const tools = [
    ToolDefinition(
      name: 'get_current_time',
      description: 'Get the current local date, time and time zone.',
      parameters: [],
    ),
  ];

  static final _calculatorTool = ToolDefinition(
    name: 'calculate',
    description:
        'Calculate the result of an arithmetic operation on two numbers.',
    parameters: [
      ToolParam.number('left', description: 'First number', required: true),
      ToolParam.enumType(
        'operator',
        values: ['add', 'subtract', 'multiply', 'divide'],
        description: 'Arithmetic operation',
        required: true,
      ),
      ToolParam.number('right', description: 'Second number', required: true),
    ],
  );

  static final _gmailTool = ToolDefinition(
    name: 'gmail_send',
    description: 'Request user approval to send an email using Gmail. Supply one recipient, a subject, and a plain-text body.',
    parameters: [
      ToolParam.string(
        'to',
        description: 'One recipient email address',
        required: true,
      ),
      ToolParam.string('subject', description: 'Email subject', required: true),
      ToolParam.string(
        'body',
        description: 'Plain-text email body',
        required: true,
      ),
    ],
  );

  Future<LlamaToolLoopResult> run(
    ChatSession session,
    String prompt, {
    required bool enableThinking,
    required bool genericToolPrompt,
    required GenerationParams params,
    required bool Function() isCancelled,
    EmailRequest? onEmailRequest,
    void Function(Calculation)? onCalculation,
  }) async {
    var emailRequested = false;
    final availableTools = [
      ...tools,
      _calculatorTool,
      if (onEmailRequest != null) _gmailTool,
    ];
    final previousSystemPrompt = session.systemPrompt;
    if (genericToolPrompt) {
      session.systemPrompt = [
        ?previousSystemPrompt,
        'You can use these tools: ${jsonEncode(availableTools.map((tool) => tool.toJson()).toList())}\n'
            'To use a tool, reply only with JSON in this format: '
            '{"tool_call":{"name":"tool name","arguments":{"parameter":"value"}}}. '
            'Use the tool result to answer. For a final answer, reply only with '
            '{"response":"your answer"}.',
      ].join('\n\n');
    }
    try {
      return await session.sendWithTools(
        prompt,
        tools: availableTools,
        maxRounds: 3,
        enableThinking: enableThinking,
        params: params,
        onToolCall: (call) async {
          if (isCancelled()) throw StateError('Agent stopped.');
          final arguments = jsonDecode(call.rawJson);
          if (arguments is! Map) {
            throw const FormatException(
              'Tool arguments must be a JSON object.',
            );
          }
          if (call.name == 'calculate') {
            final calculation = _calculate(arguments);
            onCalculation?.call(calculation);
            return {'result': calculation.result};
          }
          if (call.name == 'gmail_send' && onEmailRequest != null) {
            if (emailRequested) {
              throw StateError('Only one email may be requested per turn.');
            }
            emailRequested = true;
            final draft = _emailDraft(arguments);
            if (isCancelled()) throw StateError('Agent stopped.');
            return await onEmailRequest(draft);
          }
          if (call.name != 'get_current_time') {
            throw StateError('Unknown agent tool: ${call.name}.');
          }
          if (arguments.isNotEmpty) {
            throw FormatException(
              'get_current_time does not accept arguments.',
            );
          }
          final now = _clock().toLocal();
          return {
            'local_time': now.toIso8601String(),
            'time_zone': now.timeZoneName,
            'utc_offset_seconds': now.timeZoneOffset.inSeconds,
          };
        },
        onToolError: (call, error, stackTrace) =>
            Error.throwWithStackTrace(error, stackTrace),
      );
    } finally {
      session.systemPrompt = previousSystemPrompt;
    }
  }

  Calculation _calculate(Map arguments) {
    final left = arguments['left'];
    final right = arguments['right'];
    final operator = arguments['operator'];
    if (arguments.length != 3 ||
        left is! num ||
        right is! num ||
        !left.isFinite ||
        !right.isFinite ||
        operator is! String ||
        !const ['add', 'subtract', 'multiply', 'divide'].contains(operator)) {
      throw const FormatException(
        'Calculator requires two finite numbers and a valid operator.',
      );
    }
    if (operator == 'divide' && right == 0) {
      throw const FormatException('Cannot divide by zero.');
    }
    final a = left.toDouble();
    final b = right.toDouble();
    final result = switch (operator) {
      'add' => a + b,
      'subtract' => a - b,
      'multiply' => a * b,
      'divide' => a / b,
      _ => throw StateError('Unknown calculator operator.'),
    };
    if (!result.isFinite) {
      throw const FormatException('Calculator result is not finite.');
    }
    return Calculation(left, operator, right, result);
  }

  GmailDraft _emailDraft(Map arguments) {
    final to = arguments['to'];
    final subject = arguments['subject'];
    final body = arguments['body'];
    if (arguments.length != 3 ||
        to is! String ||
        !isValidEmailAddress(to) ||
        subject is! String ||
        subject.trim().isEmpty ||
        subject.length > 200 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(subject) ||
        body is! String ||
        body.trim().isEmpty ||
        body.length > 10000 ||
        body.contains('\x00')) {
      throw const FormatException(
        'Expected one email address, a nonempty single-line subject and a nonempty body.',
      );
    }
    return GmailDraft(to: to, subject: subject, body: body);
  }
}
