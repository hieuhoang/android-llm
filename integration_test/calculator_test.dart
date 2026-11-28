import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llm_text_app/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('local model calls calculator and displays its actual result', (
    tester,
  ) async {
    await tester.pumpWidget(const LlmTextApp());
    await tester.ensureVisible(find.byKey(const Key('prompt-input')));
    await tester.enterText(
      find.byKey(const Key('prompt-input')),
      'Use the calculate tool to multiply 123 by 456.',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Generate'));
    await tester.tap(find.text('Generate'));
    await tester.pump();

    final timeout = Stopwatch()..start();
    final calculation = find.text('Calculator: 123 * 456 = 56088.0');
    var status = '';
    while ((calculation.evaluate().isEmpty || status != 'Ready') &&
        timeout.elapsed < const Duration(minutes: 4)) {
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      status = tester.widget<Text>(find.byKey(const Key('status'))).data ?? '';
      if (status.startsWith('Error:')) {
        fail(status);
      }
    }
    expect(calculation, findsOneWidget);
    expect(status, 'Ready');
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data != null &&
            !widget.data!.startsWith('Calculator:') &&
            widget.data!.replaceAll(',', '').contains('56088'),
      ),
      findsOneWidget,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
