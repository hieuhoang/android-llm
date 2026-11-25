import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import 'gmail_sender.dart';

typedef EmailRequest = Future<Map<String, String>> Function(GmailDraft draft);

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
    required GenerationParams params,
    required bool Function() isCancelled,
    EmailRequest? onEmailRequest,
  }) {
    var emailRequested = false;
    return session.sendWithTools(
      prompt,
      tools: [...tools, if (onEmailRequest != null) _gmailTool],
      maxRounds: 3,
      enableThinking: enableThinking,
      params: params,
      onToolCall: (call) async {
        if (isCancelled()) throw StateError('Agent stopped.');
        final arguments = jsonDecode(call.rawJson);
        if (arguments is! Map) {
          throw const FormatException('Tool arguments must be a JSON object.');
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
          throw FormatException('get_current_time does not accept arguments.');
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
