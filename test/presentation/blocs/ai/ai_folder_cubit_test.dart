import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_call.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_result.dart';
import 'package:nightmail/domain/usecases/ai/run_folder_agent.dart';
import 'package:nightmail/presentation/blocs/ai/ai_folder_cubit.dart';
import 'package:nightmail/presentation/blocs/ai/ai_folder_chat_state.dart';

import 'ai_folder_cubit_test.mocks.dart';

/// Convenience accessors for the text-bubble fields on a transcript item.
///
/// The transcript is now a sealed [AiChatItem] family (text bubbles + inline
/// tool cards), so `isUser` / `text` live on [AiTextMessage] rather than the
/// base type. These extension getters keep the text-bubble assertions terse and
/// will throw a cast error if an item is unexpectedly an [AiToolItem].
extension _AsText on AiChatItem {
  bool get isUser => (this as AiTextMessage).isUser;
  String get text => (this as AiTextMessage).text;
}

// We mock the RunFolderAgent use case and feed each turn's
// `Stream<Either<Failure, AiChunk>>` from a StreamController so the test owns
// the timing of every delta, the terminal `done` chunk, and the started /
// finished tool chunks. Each call to the agent gets a fresh controller
// (appended to [controllers]) so multi-turn tests can drive turn 1 and turn 2
// independently.
@GenerateMocks([RunFolderAgent])
void main() {
  late AiFolderCubit cubit;
  late MockRunFolderAgent mockRunFolderAgent;
  late List<StreamController<Either<Failure, AiChunk>>> controllers;

  setUp(() {
    // Mockito cannot synthesise a dummy for RunFolderAgent.call's non-nullable
    // Stream return type, so register an empty one for any unstubbed call.
    provideDummy<Stream<Either<Failure, AiChunk>>>(
      const Stream<Either<Failure, AiChunk>>.empty(),
    );

    mockRunFolderAgent = MockRunFolderAgent();
    cubit = AiFolderCubit(runFolderAgent: mockRunFolderAgent);

    // Hand out a brand-new controller per agent call so each turn has its own
    // independently-controlled stream.
    controllers = [];
    when(mockRunFolderAgent.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      currentFolderId: anyNamed('currentFolderId'),
      fallbackEmailsContext: anyNamed('fallbackEmailsContext'),
    )).thenAnswer((_) {
      final controller = StreamController<Either<Failure, AiChunk>>();
      controllers.add(controller);
      return controller.stream;
    });
  });

  tearDown(() async {
    await cubit.close();
    for (final c in controllers) {
      if (!c.isClosed) await c.close();
    }
  });

  group('AiFolderCubit.send', () {
    test(
        'appends the user turn, lazily creates the assistant bubble on the '
        'first delta, accumulates streamed text, and commits on done', () async {
      final states = <AiFolderChatState>[];
      final sub = cubit.stream.listen(states.add);

      cubit.send(
        'What is urgent?',
        currentFolderId: 'inbox',
        fallbackEmailsContext: 'ctx',
      );
      // First synchronous emission: the user bubble only. The assistant bubble
      // is created lazily on the first text delta (so tool cards can render
      // above the eventual answer), so it is absent here.
      await pumpEventQueue();
      final opening = cubit.state;
      expect(opening.isStreaming, isTrue);
      expect(opening.messages, hasLength(1));
      expect(opening.messages[0].isUser, isTrue);
      expect(opening.messages[0].text, 'What is urgent?');

      controllers[0].add(const Right(AiChunk(delta: 'You have ')));
      await pumpEventQueue();
      // The first delta materialises the in-flight assistant bubble.
      expect(cubit.state.messages, hasLength(2));
      expect(cubit.state.messages[1].isUser, isFalse);
      expect(cubit.state.messages[1].text, 'You have ');
      expect(cubit.state.isStreaming, isTrue);

      controllers[0].add(const Right(AiChunk(delta: '2 urgent emails')));
      await pumpEventQueue();
      expect(cubit.state.messages[1].text, 'You have 2 urgent emails');

      controllers[0].add(
        const Right(AiChunk(delta: '.', done: true, finishReason: 'stop')),
      );
      await pumpEventQueue();

      // Settled: assistant turn carries the full accumulated text, streaming
      // cleared, no extra bubbles.
      final settled = cubit.state;
      expect(settled.isStreaming, isFalse);
      expect(settled.messages, hasLength(2));
      expect(settled.messages[1].isUser, isFalse);
      expect(settled.messages[1].text, 'You have 2 urgent emails.');

      // The first turn is sent with an empty prior history and forwards the
      // panel's folder + fallback context verbatim.
      verify(mockRunFolderAgent.call(
        history: argThat(isEmpty, named: 'history'),
        userInstruction: 'What is urgent?',
        currentFolderId: 'inbox',
        fallbackEmailsContext: 'ctx',
      )).called(1);

      // The terminal chunk must have torn the subscription down.
      expect(controllers[0].hasListener, isFalse);

      await sub.cancel();
    });

    test('ignores an empty / whitespace-only instruction (no agent call)',
        () async {
      cubit.send('   ');
      await pumpEventQueue();

      expect(controllers, isEmpty);
      expect(cubit.state.messages, isEmpty);
      verifyNever(mockRunFolderAgent.call(
        history: anyNamed('history'),
        userInstruction: anyNamed('userInstruction'),
        currentFolderId: anyNamed('currentFolderId'),
        fallbackEmailsContext: anyNamed('fallbackEmailsContext'),
      ));
    });

    test(
        'a second send() passes the accumulated history (prior user + assistant '
        'turns) to the agent', () async {
      // --- Turn 1 -----------------------------------------------------------
      cubit.send('First question');
      await pumpEventQueue();
      controllers[0].add(
        const Right(AiChunk(delta: 'First answer', done: true)),
      );
      await pumpEventQueue();

      // Turn 1 must be fully settled before turn 2 (send is a no-op while a turn
      // is still streaming).
      expect(cubit.state.isStreaming, isFalse);

      // --- Turn 2 -----------------------------------------------------------
      cubit.send('Second question');
      await pumpEventQueue();
      controllers[1].add(
        const Right(AiChunk(delta: 'Second answer', done: true)),
      );
      await pumpEventQueue();

      // Capture the `history` argument from BOTH agent calls, in order.
      final captured = verify(mockRunFolderAgent.call(
        history: captureAnyNamed('history'),
        userInstruction: anyNamed('userInstruction'),
        currentFolderId: anyNamed('currentFolderId'),
        fallbackEmailsContext: anyNamed('fallbackEmailsContext'),
      )).captured;

      expect(captured, hasLength(2));

      // Turn 1 saw an empty history.
      final firstHistory = captured[0] as List<AiMessage>;
      expect(firstHistory, isEmpty);

      // Turn 2's history grew to include turn 1's user + assistant turns (and
      // excludes the new user turn, which the agent appends itself).
      final secondHistory = captured[1] as List<AiMessage>;
      expect(secondHistory, hasLength(2));
      expect(secondHistory[0].role, AiRole.user);
      expect(secondHistory[0].content, 'First question');
      expect(secondHistory[1].role, AiRole.assistant);
      expect(secondHistory[1].content, 'First answer');

      // The transcript now holds both turns: 2 user + 2 assistant bubbles.
      expect(cubit.state.messages, hasLength(4));
      expect(cubit.state.messages.map((m) => m.text).toList(), const [
        'First question',
        'First answer',
        'Second question',
        'Second answer',
      ]);
    });
  });

  group('AiFolderCubit.reset', () {
    test('clears the transcript and history back to the empty New-Chat state',
        () async {
      // Build up a completed turn first.
      cubit.send('Anything?');
      await pumpEventQueue();
      controllers[0].add(const Right(AiChunk(delta: 'Yes', done: true)));
      await pumpEventQueue();
      expect(cubit.state.messages, isNotEmpty);

      cubit.reset();
      await pumpEventQueue();

      // Back to the default empty state.
      expect(cubit.state, const AiFolderChatState());
      expect(cubit.state.messages, isEmpty);
      expect(cubit.state.isStreaming, isFalse);
      expect(cubit.state.failure, isNull);

      // History was cleared too: the next turn is sent with an empty history.
      cubit.send('Fresh question');
      await pumpEventQueue();
      final captured = verify(mockRunFolderAgent.call(
        history: captureAnyNamed('history'),
        userInstruction: 'Fresh question',
        currentFolderId: anyNamed('currentFolderId'),
        fallbackEmailsContext: anyNamed('fallbackEmailsContext'),
      )).captured;
      expect(captured.single as List<AiMessage>, isEmpty);
    });
  });

  group('AiFolderCubit inline tool cards', () {
    test(
        'started → running tool card appended; finished → it becomes complete '
        'with output; the answer bubble follows the tool card; tool items '
        'persist and are never re-sent in history', () async {
      cubit.send('Find the invoice', currentFolderId: 'inbox');
      await pumpEventQueue();

      // Only the user bubble so far — the assistant bubble is lazy.
      expect(cubit.state.messages, hasLength(1));
      expect(cubit.state.messages[0].isUser, isTrue);

      // STARTED chunk: sentinel finish reason + the originating call.
      const call = AiToolCall(
        id: 'call_1',
        name: 'search_emails',
        arguments: {'query': 'invoice'},
      );
      controllers[0].add(const Right(AiChunk(
        delta: 'Searching for "invoice"…',
        finishReason: RunFolderAgent.toolActivityFinishReason,
        toolCalls: [call],
      )));
      await pumpEventQueue();

      // A running tool card is appended to the transcript; no answer bubble yet.
      expect(cubit.state.messages, hasLength(2));
      final running = cubit.state.messages[1];
      expect(running, isA<AiToolItem>());
      running as AiToolItem;
      expect(running.status, AiToolStatus.running);
      expect(running.callId, 'call_1');
      expect(running.name, 'search_emails');
      expect(running.args, const {'query': 'invoice'});
      expect(running.output, isNull);
      expect(cubit.state.isStreaming, isTrue);

      // FINISHED chunk: structured result matched back by callId.
      controllers[0].add(const Right(AiChunk(
        delta: '',
        finishReason: RunFolderAgent.toolResultFinishReason,
        toolResult: AiToolResult(
          callId: 'call_1',
          output: '{"results":[{"subject":"Invoice #42"}]}',
          isError: false,
        ),
      )));
      await pumpEventQueue();

      // Same card, now complete with its output — still no new item appended.
      expect(cubit.state.messages, hasLength(2));
      final finished = cubit.state.messages[1] as AiToolItem;
      expect(finished.status, AiToolStatus.complete);
      expect(finished.output, '{"results":[{"subject":"Invoice #42"}]}');

      // Answer text now streams: the assistant bubble is created lazily AFTER
      // the tool card (ordering: user, tool, assistant).
      controllers[0].add(const Right(AiChunk(delta: 'Found the invoice')));
      await pumpEventQueue();
      expect(cubit.state.messages, hasLength(3));
      expect(cubit.state.messages[1], isA<AiToolItem>());
      expect(cubit.state.messages[2], isA<AiTextMessage>());
      expect(cubit.state.messages[2].isUser, isFalse);
      expect(cubit.state.messages[2].text, 'Found the invoice');

      controllers[0].add(const Right(AiChunk(delta: '.', done: true)));
      await pumpEventQueue();

      // Settled: tool card persists, final ordering is user → tool → assistant.
      expect(cubit.state.isStreaming, isFalse);
      expect(cubit.state.messages, hasLength(3));
      expect(cubit.state.messages[0], isA<AiTextMessage>());
      expect(cubit.state.messages[1], isA<AiToolItem>());
      expect(cubit.state.messages[2], isA<AiTextMessage>());
      expect(cubit.state.messages[2].text, 'Found the invoice.');

      // The next turn's history contains ONLY text turns — the tool card is
      // display-only and is never re-sent to the agent.
      cubit.send('Anything else?');
      await pumpEventQueue();
      final captured = verify(mockRunFolderAgent.call(
        history: captureAnyNamed('history'),
        userInstruction: anyNamed('userInstruction'),
        currentFolderId: anyNamed('currentFolderId'),
        fallbackEmailsContext: anyNamed('fallbackEmailsContext'),
      )).captured;
      final secondHistory = captured.last as List<AiMessage>;
      expect(secondHistory, hasLength(2));
      expect(
        secondHistory.every(
          (m) => m.role == AiRole.user || m.role == AiRole.assistant,
        ),
        isTrue,
      );
      expect(secondHistory[0].role, AiRole.user);
      expect(secondHistory[0].content, 'Find the invoice');
      expect(secondHistory[1].role, AiRole.assistant);
      expect(secondHistory[1].content, 'Found the invoice.');
    });

    test(
        'interleaved text → tool → text preserves order: a preamble bubble, '
        'then the tool card, then a SEPARATE answer bubble below it', () async {
      cubit.send('Find the invoice', currentFolderId: 'inbox');
      await pumpEventQueue();

      // 1) The model narrates BEFORE calling a tool ("Let me check…").
      controllers[0].add(const Right(AiChunk(delta: 'Let me check. ')));
      await pumpEventQueue();
      expect(cubit.state.messages, hasLength(2)); // user + preamble bubble
      expect(cubit.state.messages[1], isA<AiTextMessage>());
      expect(cubit.state.messages[1].text, 'Let me check. ');

      // 2) Then it calls a tool.
      const call = AiToolCall(
        id: 'c1',
        name: 'search_emails',
        arguments: {'query': 'invoice'},
      );
      controllers[0].add(const Right(AiChunk(
        delta: 'Searching…',
        finishReason: RunFolderAgent.toolActivityFinishReason,
        toolCalls: [call],
      )));
      await pumpEventQueue();
      expect(cubit.state.messages, hasLength(3)); // user + preamble + tool card
      expect(cubit.state.messages[2], isA<AiToolItem>());

      controllers[0].add(const Right(AiChunk(
        delta: '',
        finishReason: RunFolderAgent.toolResultFinishReason,
        toolResult: AiToolResult(
          callId: 'c1',
          output: '{"results":[{"subject":"Invoice #42"}]}',
          isError: false,
        ),
      )));
      await pumpEventQueue();

      // 3) The model resumes with its answer AFTER the tool. This must land in a
      // NEW bubble below the tool card — not merge into the preamble bubble.
      controllers[0].add(const Right(
        AiChunk(delta: 'You have 3 unpaid invoices', done: true),
      ));
      await pumpEventQueue();

      final m = cubit.state.messages;
      expect(m, hasLength(4));
      expect(m[0], isA<AiTextMessage>()); // user
      expect(m[1], isA<AiTextMessage>()); // preamble
      expect(m[1].isUser, isFalse);
      expect(m[1].text.trim(), 'Let me check.');
      expect(m[2], isA<AiToolItem>()); // tool card
      expect(m[3], isA<AiTextMessage>()); // answer, BELOW the tool card
      expect(m[3].isUser, isFalse);
      expect(m[3].text, 'You have 3 unpaid invoices');

      // History carries the whole turn's assistant text (both segments), so the
      // model remembers what it said.
      cubit.send('Anything else?');
      await pumpEventQueue();
      final captured = verify(mockRunFolderAgent.call(
        history: captureAnyNamed('history'),
        userInstruction: anyNamed('userInstruction'),
        currentFolderId: anyNamed('currentFolderId'),
        fallbackEmailsContext: anyNamed('fallbackEmailsContext'),
      )).captured;
      final secondHistory = captured.last as List<AiMessage>;
      expect(secondHistory, hasLength(2));
      expect(secondHistory[1].role, AiRole.assistant);
      expect(secondHistory[1].content, contains('Let me check.'));
      expect(secondHistory[1].content, contains('You have 3 unpaid invoices'));
    });

    test('a finished chunk with isError marks the tool card as error', () async {
      cubit.send('Read message 42', currentFolderId: 'inbox');
      await pumpEventQueue();

      const call = AiToolCall(
        id: 'call_err',
        name: 'get_email',
        arguments: {'id': '42'},
      );
      controllers[0].add(const Right(AiChunk(
        delta: 'Reading an email…',
        finishReason: RunFolderAgent.toolActivityFinishReason,
        toolCalls: [call],
      )));
      await pumpEventQueue();
      expect((cubit.state.messages[1] as AiToolItem).status,
          AiToolStatus.running);

      controllers[0].add(const Right(AiChunk(
        delta: '',
        finishReason: RunFolderAgent.toolResultFinishReason,
        toolResult: AiToolResult(
          callId: 'call_err',
          output: '{"error":"Email not found."}',
          isError: true,
        ),
      )));
      await pumpEventQueue();

      final errored = cubit.state.messages[1] as AiToolItem;
      expect(errored.status, AiToolStatus.error);
      expect(errored.output, '{"error":"Email not found."}');
      expect(cubit.state.isStreaming, isTrue);
    });

    test(
        'a turn that ends (done) with a tool card still running marks it as '
        'error so the UI stops spinning', () async {
      cubit.send('Find the invoice', currentFolderId: 'inbox');
      await pumpEventQueue();

      const call = AiToolCall(
        id: 'call_1',
        name: 'search_emails',
        arguments: {'query': 'invoice'},
      );
      controllers[0].add(const Right(AiChunk(
        delta: 'Searching…',
        finishReason: RunFolderAgent.toolActivityFinishReason,
        toolCalls: [call],
      )));
      await pumpEventQueue();
      expect((cubit.state.messages[1] as AiToolItem).status,
          AiToolStatus.running);

      // The turn ends WITHOUT a tool result ever arriving.
      controllers[0].add(const Right(AiChunk(delta: 'Done.', done: true)));
      await pumpEventQueue();

      expect(cubit.state.isStreaming, isFalse);
      final settled = cubit.state.messages[1] as AiToolItem;
      expect(settled.status, AiToolStatus.error);
    });

    test(
        'cancel() settles a still-running tool card to error instead of leaving '
        'it spinning', () async {
      cubit.send('Find the invoice', currentFolderId: 'inbox');
      await pumpEventQueue();

      const call = AiToolCall(
        id: 'call_1',
        name: 'search_emails',
        arguments: {'query': 'invoice'},
      );
      controllers[0].add(const Right(AiChunk(
        delta: 'Searching…',
        finishReason: RunFolderAgent.toolActivityFinishReason,
        toolCalls: [call],
      )));
      await pumpEventQueue();
      expect((cubit.state.messages[1] as AiToolItem).status,
          AiToolStatus.running);

      cubit.cancel();
      await pumpEventQueue();

      expect(cubit.state.isStreaming, isFalse);
      expect((cubit.state.messages[1] as AiToolItem).status,
          AiToolStatus.error);
    });

    test(
        'a failure mid-turn settles a still-running tool card to error',
        () async {
      cubit.send('Find the invoice', currentFolderId: 'inbox');
      await pumpEventQueue();

      const call = AiToolCall(
        id: 'call_1',
        name: 'search_emails',
        arguments: {'query': 'invoice'},
      );
      controllers[0].add(const Right(AiChunk(
        delta: 'Searching…',
        finishReason: RunFolderAgent.toolActivityFinishReason,
        toolCalls: [call],
      )));
      await pumpEventQueue();
      expect((cubit.state.messages[1] as AiToolItem).status,
          AiToolStatus.running);

      controllers[0]
          .add(const Left(ProviderUnreachable(message: 'boom')));
      await pumpEventQueue();

      expect(cubit.state.isStreaming, isFalse);
      expect(cubit.state.failure, isA<ProviderUnreachable>());
      expect((cubit.state.messages[1] as AiToolItem).status,
          AiToolStatus.error);
    });

    test('a started chunk renders one running card per tool call', () async {
      cubit.send('Find the invoice', currentFolderId: 'inbox');
      await pumpEventQueue();

      controllers[0].add(const Right(AiChunk(
        delta: 'Searching…',
        finishReason: RunFolderAgent.toolActivityFinishReason,
        toolCalls: [
          AiToolCall(id: 'c1', name: 'search_emails', arguments: {'q': 'a'}),
          AiToolCall(id: 'c2', name: 'get_email', arguments: {'id': '1'}),
        ],
      )));
      await pumpEventQueue();

      // user + two tool cards.
      expect(cubit.state.messages, hasLength(3));
      final first = cubit.state.messages[1] as AiToolItem;
      final second = cubit.state.messages[2] as AiToolItem;
      expect(first.callId, 'c1');
      expect(first.status, AiToolStatus.running);
      expect(second.callId, 'c2');
      expect(second.status, AiToolStatus.running);
    });
  });
}
