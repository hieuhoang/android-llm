import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_text_app/gmail_sender.dart';
import 'package:llm_text_app/google_gmail_sender.dart';

class FakeGmailAuthorization implements GmailAuthorization {
  String? token = 'test-token';
  String? clientId;
  String? invalidatedToken;
  int automaticConnections = 0;
  Object? connectionError;

  @override
  Future<String> ensureConnected(String clientId) async {
    automaticConnections++;
    this.clientId = clientId;
    if (connectionError case final error?) throw error;
    token = 'test-token';
    return 'sender@example.com';
  }

  @override
  Future<String?> accessToken() async => token;

  @override
  Future<void> invalidateToken(String token) async {
    invalidatedToken = token;
    this.token = null;
  }
}

void main() {
  const draft = GmailDraft(
    to: 'recipient@example.com',
    subject: 'Hi',
    body: 'Hello',
  );
  test('sends the confirmed message through the Gmail API', () async {
    final authorization = FakeGmailAuthorization();
    var requests = 0;
    final sender = GoogleGmailSender(
      authorization: authorization,
      clientFactory: () => MockClient((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://gmail.googleapis.com/gmail/v1/users/me/messages/send',
        );
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer test-token');
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        final mime = utf8.decode(
          base64Url.decode(base64Url.normalize(payload['raw'] as String)),
        );
        expect(
          mime,
          contains('From: sender@example.com\r\nTo: recipient@example.com\r\n'),
        );
        expect(mime, contains('Subject: =?UTF-8?B?SGk=?='));
        expect(mime, contains('SGVsbG8='));
        return http.Response('{"id":"gmail-id"}', 200);
      }),
    );
    expect(await sender.account(), 'sender@example.com');
    expect(authorization.clientId, gmailWebClientId);
    expect(await sender.send(draft, from: 'sender@example.com'), 'gmail-id');
    expect(requests, 1);
  });

  test(
    'connects on demand and reconnects only when authorization is missing',
    () async {
      final authorization = FakeGmailAuthorization();
      final sender = GoogleGmailSender(authorization: authorization);
      expect(await sender.account(), 'sender@example.com');
      expect(authorization.clientId, gmailWebClientId);
      expect(authorization.automaticConnections, 1);
      expect(await sender.account(), 'sender@example.com');
      expect(authorization.automaticConnections, 1);
      authorization.token = null;
      expect(await sender.account(), 'sender@example.com');
      expect(authorization.automaticConnections, 2);
    },
  );

  test('connection failure does not send an email', () async {
    final authorization = FakeGmailAuthorization()
      ..connectionError = StateError('Sign-in cancelled');
    var requests = 0;
    final sender = GoogleGmailSender(
      authorization: authorization,
      clientFactory: () => MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(sender.account(), throwsA(isA<StateError>()));
    await expectLater(
      sender.send(draft, from: 'sender@example.com'),
      throwsA(isA<StateError>()),
    );
    expect(requests, 0);
  });

  test(
    'does not send without authorization or with a different account',
    () async {
      final authorization = FakeGmailAuthorization();
      var requests = 0;
      final sender = GoogleGmailSender(
        authorization: authorization,
        clientFactory: () => MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      await sender.account();
      authorization.token = null;
      await expectLater(
        sender.send(draft, from: 'sender@example.com'),
        throwsA(isA<StateError>()),
      );
      authorization.token = 'test-token';
      await expectLater(
        sender.send(draft, from: 'other@example.com'),
        throwsA(isA<StateError>()),
      );
      expect(requests, 0);
    },
  );

  test('reports uncertain Gmail outcomes without retrying', () async {
    for (final response in [
      http.Response('{"error":"unavailable"}', 500),
      http.Response('{}', 200),
      http.Response('invalid', 200),
    ]) {
      var requests = 0;
      final sender = GoogleGmailSender(
        authorization: FakeGmailAuthorization(),
        clientFactory: () => MockClient((_) async {
          requests++;
          return response;
        }),
      );
      await sender.account();
      await expectLater(
        sender.send(draft, from: 'sender@example.com'),
        throwsA(
          predicate(
            (error) => error.toString().contains('check Sent before retrying'),
          ),
        ),
      );
      expect(requests, 1);
    }
  });

  test('invalidates a rejected token without retrying the send', () async {
    final authorization = FakeGmailAuthorization();
    var requests = 0;
    final sender = GoogleGmailSender(
      authorization: authorization,
      clientFactory: () => MockClient((_) async {
        requests++;
        return http.Response('{}', 401);
      }),
    );
    await sender.account();
    await expectLater(
      sender.send(draft, from: 'sender@example.com'),
      throwsA(isA<StateError>()),
    );
    expect(authorization.invalidatedToken, 'test-token');
    expect(requests, 1);
    expect(await sender.account(), 'sender@example.com');
    expect(authorization.automaticConnections, 2);
    expect(requests, 1);
  });
}
