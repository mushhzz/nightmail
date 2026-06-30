import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/blocs/ai/ai_folder_chat_state.dart';
import 'package:nightmail/presentation/widgets/ai/tool_call_card.dart';

Widget _wrap(AiToolItem item) {
  return MaterialApp(
    home: Scaffold(
      // Width-bounded so the collapsed one-liner can lay out its Flexible
      // preview without unbounded-width errors.
      body: SizedBox(width: 360, child: ToolCallCard(item: item)),
    ),
  );
}

void main() {
  group('ToolCallCard', () {
    testWidgets(
      'complete item renders collapsed, then expands to reveal input/output JSON',
      (tester) async {
        const item = AiToolItem(
          id: 'item-1',
          callId: 'call-1',
          name: 'search_emails',
          args: {'query': 'invoices'},
          output: '{"count": 3}',
          status: AiToolStatus.complete,
        );

        await tester.pumpWidget(_wrap(item));

        // Collapsed one-liner: humanized name, arg preview, done glyph.
        expect(find.text('Searched emails'), findsOneWidget);
        expect(find.text('invoices'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

        // Body is hidden while collapsed.
        expect(find.text('INPUT'), findsNothing);
        expect(find.text('OUTPUT'), findsNothing);
        expect(find.textContaining('"count"'), findsNothing);

        // Tap the header to expand.
        await tester.tap(find.byType(InkWell));
        await tester.pump();

        // Body now reveals the input args and output JSON.
        expect(find.text('INPUT'), findsOneWidget);
        expect(find.text('OUTPUT'), findsOneWidget);
        expect(find.textContaining('"query"'), findsOneWidget);
        expect(find.textContaining('"count"'), findsOneWidget);
      },
    );

    testWidgets(
      'error item renders auto-expanded showing the error text',
      (tester) async {
        const item = AiToolItem(
          id: 'item-2',
          callId: 'call-2',
          name: 'get_email',
          args: {'id': 'msg-99'},
          output: '{"error": "mailbox unavailable"}',
          status: AiToolStatus.error,
        );

        await tester.pumpWidget(_wrap(item));

        // Forced open: no tap required to see the body and the error glyph.
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        expect(find.text('INPUT'), findsOneWidget);
        expect(find.text('OUTPUT'), findsOneWidget);
        expect(find.textContaining('mailbox unavailable'), findsOneWidget);

        // Tapping an error card must not collapse it.
        await tester.tap(find.byType(InkWell));
        await tester.pump();
        expect(find.text('OUTPUT'), findsOneWidget);
        expect(find.textContaining('mailbox unavailable'), findsOneWidget);
      },
    );

    testWidgets(
      'pretty-print falls back to the raw string for non-JSON output',
      (tester) async {
        const item = AiToolItem(
          id: 'item-3',
          callId: 'call-3',
          name: 'list_folders',
          args: {},
          output: 'not valid json <<<',
          status: AiToolStatus.complete,
        );

        await tester.pumpWidget(_wrap(item));

        // Expand to render the output section.
        await tester.tap(find.byType(InkWell));
        await tester.pump();

        // Raw string rendered verbatim, no exception thrown.
        expect(find.textContaining('not valid json <<<'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
