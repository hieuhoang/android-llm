import 'dart:async';
import 'dart:convert';
import 'dart:io';

class GmailDraft {
  const GmailDraft({
    required this.to,
    required this.subject,
    required this.body,
  });

  final String to;
  final String subject;
  final String body;
}

abstract interface class GmailSender {
  Future<String> account();
  Future<String> send(GmailDraft draft, {required String from});
}

abstract interface class ConnectableGmailSender implements GmailSender {
  Future<void> connect(String clientId);
}

final _emailPattern = RegExp(
  r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$",
);

bool isValidEmailAddress(String address) =>
    address.length <= 254 && _emailPattern.hasMatch(address);

class GogGmailSender implements GmailSender {
  GogGmailSender({String? executable})
    : _executable = executable ?? _defaultExecutable();

  final String _executable;

  static String _defaultExecutable() {
    final home = Platform.environment['HOME'];
    if (home != null && File('$home/go/bin/gog').existsSync()) {
      return '$home/go/bin/gog';
    }
    return 'gog';
  }

  @override
  Future<String> account() async {
    final Process process;
    try {
      process = await Process.start(_executable, [
        'auth',
        'status',
        '--json',
        '--no-input',
      ]);
    } on ProcessException {
      throw StateError(
        'Could not start gog. Install and configure gog for Gmail.',
      );
    }
    final stdoutFuture = utf8.decoder.bind(process.stdout).join();
    final stderrFuture = utf8.decoder.bind(process.stderr).join();
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await stdoutFuture;
      await stderrFuture;
      throw StateError('Timed out checking the gog account.');
    }
    final output = await stdoutFuture;
    await stderrFuture;
    if (exitCode != 0) throw StateError('Could not read the gog account.');
    final Object? result;
    try {
      result = jsonDecode(output);
    } on FormatException {
      throw StateError('gog returned an invalid account response.');
    }
    final account = result is Map ? result['account'] : null;
    final email = account is Map ? account['email'] : null;
    if (email is! String || !isValidEmailAddress(email)) {
      throw StateError('Configure a default gog Gmail account before sending.');
    }
    return email;
  }

  @override
  Future<String> send(GmailDraft draft, {required String from}) async {
    if (!isValidEmailAddress(from) || !isValidEmailAddress(draft.to)) {
      throw ArgumentError('Invalid Gmail sender or recipient.');
    }
    final Process process;
    try {
      process = await Process.start(_executable, [
        'gmail',
        'send',
        '--raw-file=-',
        '--account=$from',
        '--no-input',
        '--json',
      ]);
    } on ProcessException {
      throw StateError('Could not start the configured Gmail tool.');
    }

    final stdoutFuture = utf8.decoder.bind(process.stdout).join();
    final stderrFuture = utf8.decoder.bind(process.stderr).join();
    final int exitCode;
    try {
      exitCode = await (() async {
        process.stdin.write(buildGmailMessage(draft, from));
        await process.stdin.close();
        return await process.exitCode;
      })().timeout(const Duration(seconds: 60));
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await stdoutFuture;
      await stderrFuture;
      throw StateError(
        'Gmail timed out; the send outcome is unknown. Check Sent before retrying.',
      );
    } on IOException {
      process.kill();
      await process.exitCode;
      await stdoutFuture;
      await stderrFuture;
      throw StateError(
        'Gmail communication failed; the send outcome is unknown. Check Sent before retrying.',
      );
    }
    final stdout = await stdoutFuture;
    await stderrFuture;
    if (exitCode != 0) {
      throw StateError(
        'Gmail send failed or its outcome is unknown. Check Sent before retrying, and check gog authentication and Gmail permissions.',
      );
    }
    final Object? result;
    try {
      result = jsonDecode(stdout);
    } on FormatException {
      throw StateError(
        'Gmail returned an invalid response; check Sent before retrying.',
      );
    }
    if (result is! Map ||
        result['messageId'] is! String ||
        (result['messageId'] as String).isEmpty) {
      throw StateError(
        'Gmail returned no message ID; check Sent before retrying.',
      );
    }
    return result['messageId'] as String;
  }
}

String buildGmailMessage(GmailDraft draft, String from) {
  final encodedWords = <String>[];
  var bytes = <int>[];
  void addWord() {
    if (bytes.isNotEmpty) {
      encodedWords.add('=?UTF-8?B?${base64.encode(bytes)}?=');
      bytes = <int>[];
    }
  }

  for (final rune in draft.subject.runes) {
    final next = utf8.encode(String.fromCharCode(rune));
    if (bytes.length + next.length > 36) addWord();
    bytes.addAll(next);
  }
  addWord();
  final body = base64.encode(utf8.encode(draft.body));
  final bodyLines = <String>[
    for (var start = 0; start < body.length; start += 76)
      body.substring(start, (start + 76).clamp(0, body.length)),
  ];
  return [
    'From: $from',
    'To: ${draft.to}',
    'Subject: ${encodedWords.join('\r\n ')}',
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    ...bodyLines,
    '',
  ].join('\r\n');
}
