import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_text_app/gmail_sender.dart';

void main() {
  test('gog adapter sends MIME on stdin and checks the response', () async {
    final dir = await Directory.systemTemp.createTemp('gmail-sender-test-');
    try {
      final script = File('${dir.path}/gog');
      final message = File('${dir.path}/message');
      await script.writeAsString('''
#!/bin/sh
if [ "\$1" = auth ]; then
  echo '{"account":{"email":"sender@example.com"}}'
else
  cat > '${message.path}'
  echo '{"messageId":"test-id"}'
fi
''');
      final chmod = await Process.run('chmod', ['+x', script.path]);
      expect(chmod.exitCode, 0);
      final sender = GogGmailSender(executable: script.path);
      expect(await sender.account(), 'sender@example.com');
      const draft = GmailDraft(
        to: 'recipient@example.com',
        subject: 'Hello',
        body: 'Body',
      );
      expect(await sender.send(draft, from: 'sender@example.com'), 'test-id');
      final content = await message.readAsString();
      expect(
        content,
        contains('From: sender@example.com\r\nTo: recipient@example.com\r\n'),
      );
      expect(content, contains('Subject: =?UTF-8?B?SGVsbG8=?='));
      expect(content, contains('Qm9keQ=='));
      await script.writeAsString("#!/bin/sh\ncat > /dev/null\necho '{}'\n");
      await expectLater(
        sender.send(draft, from: 'sender@example.com'),
        throwsA(
          predicate((e) => e.toString().contains('check Sent before retrying')),
        ),
      );
      await script.writeAsString('#!/bin/sh\ncat > /dev/null\nexit 1\n');
      await expectLater(
        sender.send(draft, from: 'sender@example.com'),
        throwsA(predicate((e) => e.toString().contains('outcome is unknown'))),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isLinux);
}
