import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_text_app/main.dart';
import 'package:llm_text_app/text_generator.dart';

class FakeGenerator implements TextGenerator {
  final loading = Completer<void>();
  final output = StreamController<String>();
  void Function(double?)? progress;
  String? prompt;
  bool cancelled = false;

  @override
  Future<void> load(void Function(double?) onProgress) {
    progress = onProgress;
    return loading.future;
  }

  @override
  Stream<String> generate(String prompt) {
    this.prompt = prompt;
    return output.stream;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    await output.close();
  }
}

void main() {
  testWidgets('loads model and streams output for a nonempty prompt', (
    tester,
  ) async {
    final generator = FakeGenerator();
    await tester.pumpWidget(LlmTextApp(generator: generator));
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
    generator.progress!(0.5);
    await tester.pump();
    expect(find.text('Downloading model: 50%'), findsOneWidget);

    generator.loading.complete();
    await tester.pump();
    expect(generator.prompt, 'Hello');
    generator.output.add('Hi');
    await tester.pump();
    expect(find.text('Hi'), findsOneWidget);
    generator.output.add(' there');
    await tester.pump();
    expect(find.text('Hi there'), findsOneWidget);
    await generator.output.close();
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
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
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('stop cancels loading and leaves the prompt available', (
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
    expect(find.text('Stopped. Tap Generate to retry.'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
  });
}
