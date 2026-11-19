import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:llm_text_app/main.dart';

void main() {
  testWidgets('generating requires a prompt and reports no model', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LlmTextApp());

    expect(find.byKey(const Key('prompt-input')), findsOneWidget);
    expect(find.byKey(const Key('output-area')), findsOneWidget);
    expect(find.text('Generated text will appear here.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const Key('prompt-input')), '   ');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('prompt-input')),
      'Summarize this article',
    );
    await tester.pump();
    expect(find.text('Summarize this article'), findsOneWidget);
    await tester.tap(find.text('Generate'));
    await tester.pump();
    expect(
      find.text('No model is connected yet. Text generation is not available.'),
      findsOneWidget,
    );
    expect(find.text('Generated text will appear here.'), findsNothing);
  });
}
