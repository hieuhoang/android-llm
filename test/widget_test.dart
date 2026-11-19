import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:llm_text_app/main.dart';

void main() {
  testWidgets('shows prompt input and output area', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LlmTextApp());

    expect(find.byKey(const Key('prompt-input')), findsOneWidget);
    expect(find.byKey(const Key('output-area')), findsOneWidget);
    expect(find.text('Generated text will appear here.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('prompt-input')),
      'Summarize this article',
    );
    expect(find.text('Summarize this article'), findsOneWidget);
  });
}
