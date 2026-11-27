import 'dart:async';
import 'dart:convert';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'gmail_sender.dart';

const gmailWebClientId =
    '780666505557-3bar3kbseund8icf1qet1g61c7465f3g.apps.googleusercontent.com';

abstract interface class GmailAuthorization {
  Future<String> ensureConnected(String clientId);
  Future<String?> accessToken();
  Future<void> invalidateToken(String token);
}

class GoogleGmailAuthorization implements GmailAuthorization {
  static const _scopes = ['https://www.googleapis.com/auth/gmail.send'];
  final _signIn = GoogleSignIn.instance;
  GoogleSignInAccount? _account;
  String? _initializedClientId;

  Future<void> _initialize(String clientId) async {
    if (_initializedClientId != null && _initializedClientId != clientId) {
      throw StateError('Restart the app to use the new Google client ID.');
    }
    if (_initializedClientId == null) {
      await _signIn.initialize(serverClientId: clientId);
      _initializedClientId = clientId;
    }
  }

  @override
  Future<String> ensureConnected(String clientId) async {
    await _initialize(clientId);
    final account =
        _account ??
        await _signIn.attemptLightweightAuthentication(
          reportAllExceptions: true,
        ) ??
        await _signIn.authenticate();
    await account.authorizationClient.authorizationForScopes(_scopes) ??
        await account.authorizationClient.authorizeScopes(_scopes);
    _account = account;
    return account.email;
  }

  @override
  Future<String?> accessToken() async {
    final account = _account;
    if (account == null) return null;
    final authorization = await account.authorizationClient
        .authorizationForScopes(_scopes);
    return authorization?.accessToken;
  }

  @override
  Future<void> invalidateToken(String token) async {
    final account = _account;
    if (account == null) {
      throw StateError('Gmail is not connected.');
    }
    await account.authorizationClient.clearAuthorizationToken(
      accessToken: token,
    );
  }
}

class GoogleGmailSender implements GmailSender {
  GoogleGmailSender({
    GmailAuthorization? authorization,
    http.Client Function()? clientFactory,
  }) : _authorization = authorization ?? GoogleGmailAuthorization(),
       _clientFactory = clientFactory ?? http.Client.new;

  final GmailAuthorization _authorization;
  final http.Client Function() _clientFactory;
  String? _account;

  @override
  Future<String> account() async {
    if (_account != null) {
      final token = await _authorization.accessToken();
      if (token != null && token.isNotEmpty) return _account!;
    }
    _account = null;
    final account = await _authorization.ensureConnected(gmailWebClientId);
    if (!isValidEmailAddress(account)) {
      throw StateError('Google returned an invalid account address.');
    }
    _account = account;
    return account;
  }

  @override
  Future<String> send(GmailDraft draft, {required String from}) async {
    if (_account != from ||
        !isValidEmailAddress(from) ||
        !isValidEmailAddress(draft.to)) {
      throw StateError(
        'Gmail account changed or email address is invalid; email not sent.',
      );
    }
    final token = await _authorization.accessToken();
    if (token == null || token.isEmpty) {
      throw StateError(
        'Gmail authorization expired. Email not sent; request it again to reconnect.',
      );
    }
    final client = _clientFactory();
    try {
      final response = await (() async {
        final request =
            http.Request(
                'POST',
                Uri.https(
                  'gmail.googleapis.com',
                  '/gmail/v1/users/me/messages/send',
                ),
              )
              ..followRedirects = false
              ..headers['Authorization'] = 'Bearer $token'
              ..headers['Content-Type'] = 'application/json; charset=utf-8'
              ..body = jsonEncode({
                'raw': base64Url
                    .encode(utf8.encode(buildGmailMessage(draft, from)))
                    .replaceAll('=', ''),
              });
        return http.Response.fromStream(await client.send(request));
      })().timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401) {
          await _authorization.invalidateToken(token);
        }
        throw StateError(
          'Gmail returned HTTP ${response.statusCode}; check Sent before retrying. Gmail will reconnect on the next request if needed.',
        );
      }
      final Object? result;
      try {
        result = jsonDecode(response.body);
      } on FormatException {
        throw StateError(
          'Gmail returned an invalid response; check Sent before retrying.',
        );
      }
      final id = result is Map ? result['id'] : null;
      if (id is! String || id.isEmpty) {
        throw StateError(
          'Gmail returned no message ID; check Sent before retrying.',
        );
      }
      return id;
    } on TimeoutException {
      throw StateError(
        'Gmail timed out; the send outcome is unknown. Check Sent before retrying.',
      );
    } on http.ClientException {
      throw StateError(
        'Gmail connection failed; the send outcome is unknown. Check Sent before retrying.',
      );
    } finally {
      client.close();
    }
  }
}
