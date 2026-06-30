import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_capability.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_model.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_call.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/domain/repositories/ai/ai_catalog_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_inference_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_settings_repository.dart';
import 'package:nightmail/domain/usecases/get_email.dart';
import 'package:nightmail/domain/usecases/get_emails.dart';
import 'package:nightmail/domain/usecases/get_mail_folders.dart';
import 'package:nightmail/domain/usecases/search_emails.dart';
import 'package:nightmail/domain/usecases/ai/run_folder_agent.dart';

import 'run_folder_agent_test.mocks.dart';

// We mock the inference repository (its `stream()` is scripted per round via a
// queue of canned streams), the settings/catalog repositories, and the four
// read-only email use cases the agent wraps as tools. This lets each test drive
// the loop deterministically: round N's tool-call → the matching use case is
// invoked → round N+1's text answer is streamed through.
@GenerateMocks([
  AiInferenceRepository,
  AiSettingsRepository,
  AiCatalogRepository,
  GetEmails,
  GetEmail,
  SearchEmails,
  GetMailFolders,
])
void main() {
  late RunFolderAgent useCase;
  late MockAiInferenceRepository mockInference;
  late MockAiSettingsRepository mockSettings;
  late MockAiCatalogRepository mockCatalog;
  late MockGetEmails mockGetEmails;
  late MockGetEmail mockGetEmail;
  late MockSearchEmails mockSearchEmails;
  late MockGetMailFolders mockGetMailFolders;

  const tRouting = (providerId: 'openai', modelId: 'gpt-4o');

  /// A queue of canned streams; each `inference.stream()` call dequeues one.
  /// Tests fill this in declaration (round) order before calling the agent.
  late List<Stream<Either<Failure, AiChunk>>> scriptedRounds;

  /// Provider descriptor of the requested privacy [kind]; only `kind` matters.
  AiProvider provider(AiProviderKind kind) => AiProvider(
        id: 'openai',
        name: 'OpenAI',
        npm: '@ai-sdk/openai',
        doc: 'https://example.com/docs',
        env: const ['OPENAI_API_KEY'],
        kind: kind,
        wireProtocol: AiWireProtocol.openai,
        source: AiProviderSource.catalog,
      );

  /// Minimal model whose only load-bearing flag is [toolCall].
  AiModel model({required bool toolCall}) => AiModel(
        id: 'gpt-4o',
        providerId: 'openai',
        name: 'GPT-4o',
        attachment: false,
        reasoning: false,
        toolCall: toolCall,
        openWeights: false,
        releaseDate: '2024-01-01',
        lastUpdated: '2024-01-01',
        inputModalities: const ['text'],
        outputModalities: const ['text'],
        contextLimit: 128000,
        outputLimit: 4096,
      );

  Email email({
    String id = 'msg1',
    String body = 'FULL-BODY',
    String preview = 'PREVIEW-TEXT',
  }) =>
      Email(
        id: id,
        subject: 'Subject $id',
        from: const EmailAddress(address: 'sender@example.com', name: 'Sender'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: preview,
        body: body,
        bodyType: EmailBodyType.text,
        isRead: false,
        receivedDateTime: DateTime.utc(2026, 6, 29, 12),
        importance: EmailImportance.normal,
      );

  /// A round-terminal stream that emits assembled tool [calls] (no text).
  Stream<Either<Failure, AiChunk>> toolCallRound(List<AiToolCall> calls) =>
      Stream<Either<Failure, AiChunk>>.fromIterable([
        Right(AiChunk(
          delta: '',
          done: true,
          finishReason: 'tool_calls',
          toolCalls: calls,
        )),
      ]);

  /// A round that streams [deltas] of text then a terminal `stop` chunk.
  Stream<Either<Failure, AiChunk>> textRound(List<String> deltas) =>
      Stream<Either<Failure, AiChunk>>.fromIterable([
        for (var i = 0; i < deltas.length; i++)
          Right(AiChunk(
            delta: deltas[i],
            done: i == deltas.length - 1,
            finishReason: i == deltas.length - 1 ? 'stop' : null,
          )),
      ]);

  /// All `AiRequest`s handed to `inference.stream()`, in call order.
  List<AiRequest> capturedRequests() =>
      verify(mockInference.stream(captureAny)).captured.cast<AiRequest>();

  AiChunk? rightChunk(Either<Failure, AiChunk> e) => e.getRight().toNullable();

  /// All transient tool-activity (started) chunks emitted, in call order.
  List<AiChunk> startedEvents(List<Either<Failure, AiChunk>> emitted) => emitted
      .map(rightChunk)
      .whereType<AiChunk>()
      .where((c) => c.finishReason == RunFolderAgent.toolActivityFinishReason)
      .toList();

  /// All tool-result (finished) chunks emitted, in call order. Each carries an
  /// [AiToolResult] with the originating call id, serialized output, and the
  /// error flag.
  List<AiChunk> finishedEvents(List<Either<Failure, AiChunk>> emitted) => emitted
      .map(rightChunk)
      .whereType<AiChunk>()
      .where((c) => c.finishReason == RunFolderAgent.toolResultFinishReason)
      .toList();

  setUp(() {
    // Mockito cannot synthesise dummies for sealed/abstract return types.
    provideDummy<Either<Failure, AiRouting?>>(const Right(null));
    provideDummy<Either<Failure, bool>>(const Right(false));
    provideDummy<Either<Failure, int>>(const Right(0));
    provideDummy<Either<Failure, AiProvider>>(
      Right(provider(AiProviderKind.cloud)),
    );
    provideDummy<Either<Failure, AiModel>>(Right(model(toolCall: true)));
    provideDummy<Either<Failure, List<Email>>>(const Right([]));
    provideDummy<Either<Failure, Email>>(Right(email()));
    provideDummy<Either<Failure, List<EmailFolder>>>(const Right([]));
    provideDummy<Stream<Either<Failure, AiChunk>>>(
      const Stream<Either<Failure, AiChunk>>.empty(),
    );

    mockInference = MockAiInferenceRepository();
    mockSettings = MockAiSettingsRepository();
    mockCatalog = MockAiCatalogRepository();
    mockGetEmails = MockGetEmails();
    mockGetEmail = MockGetEmail();
    mockSearchEmails = MockSearchEmails();
    mockGetMailFolders = MockGetMailFolders();

    useCase = RunFolderAgent(
      settingsRepository: mockSettings,
      inferenceRepository: mockInference,
      catalogRepository: mockCatalog,
      getEmails: mockGetEmails,
      getEmail: mockGetEmail,
      searchEmails: mockSearchEmails,
      getMailFolders: mockGetMailFolders,
    );

    // Sensible defaults; individual tests override what they care about.
    when(mockSettings.getRouting(AiCapability.compose))
        .thenAnswer((_) async => const Right(tRouting));
    when(mockSettings.getAllowCloudForBodies())
        .thenAnswer((_) async => const Right(false));
    // Configurable safety bounds (§3): default to today's compile-time
    // constants so the existing tests keep their original behaviour.
    when(mockSettings.getAgentMaxRounds())
        .thenAnswer((_) async => const Right(RunFolderAgent.defaultMaxRounds));
    when(mockSettings.getAgentMaxToolCallsPerRound()).thenAnswer(
      (_) async => const Right(RunFolderAgent.defaultMaxToolCallsPerRound),
    );
    when(mockCatalog.getProvider('openai'))
        .thenAnswer((_) async => Right(provider(AiProviderKind.cloud)));
    when(mockCatalog.getModel(
      providerId: anyNamed('providerId'),
      modelId: anyNamed('modelId'),
    )).thenAnswer((_) async => Right(model(toolCall: true)));

    // Email use cases default to empty / a stock email.
    when(mockGetEmails.call(any)).thenAnswer((_) async => const Right([]));
    when(mockGetEmail.call(any)).thenAnswer((_) async => Right(email()));
    when(mockSearchEmails.call(any)).thenAnswer((_) async => const Right([]));
    when(mockGetMailFolders.call(any))
        .thenAnswer((_) async => const Right([]));

    // `stream()` dequeues the next scripted round; empty when exhausted.
    scriptedRounds = [];
    when(mockInference.stream(any)).thenAnswer((_) {
      return scriptedRounds.isNotEmpty
          ? scriptedRounds.removeAt(0)
          : const Stream<Either<Failure, AiChunk>>.empty();
    });
  });

  group('RunFolderAgent — tool-call round trip (§3)', () {
    test(
        'round 1 emits a get_email tool call → the GetEmail use case is invoked '
        'with the parsed id, then round 2 streams the final answer through',
        () async {
      // Local provider so bodies are permitted — lets us also assert the tool
      // result (with body) is fed back into round 2.
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.local)));
      when(mockGetEmail.call(any)).thenAnswer(
        (_) async => Right(email(id: 'msg1', body: 'CONFIDENTIAL-BODY')),
      );

      scriptedRounds = [
        toolCallRound(const [
          AiToolCall(id: 'call_1', name: 'get_email', arguments: {'id': 'msg1'}),
        ]),
        textRound(const ['Your ', 'message ', 'says hello.']),
      ];

      final emitted = await useCase
          .call(history: const [], userInstruction: 'What does msg1 say?')
          .toList();

      // The matching use case ran with the parsed argument.
      verify(mockGetEmail.call(const GetEmailParams(id: 'msg1'))).called(1);

      // No hard failure surfaced.
      expect(emitted.every((e) => e.isRight()), isTrue);

      // Exactly one transient tool-activity (started) chunk for the call; it
      // carries the originating tool call but is not part of the answer.
      final started = startedEvents(emitted);
      expect(started, hasLength(1));
      expect(started.single.toolCalls!.single.name, 'get_email');
      expect(started.single.toolCalls!.single.id, 'call_1');

      // And exactly one finished (tool-result) chunk for that same call: a
      // success (isError == false) whose output is the serialized tool result.
      final finished = finishedEvents(emitted);
      expect(finished, hasLength(1));
      expect(finished.single.toolResult!.callId, 'call_1');
      expect(finished.single.toolResult!.isError, isFalse);
      expect(finished.single.toolResult!.output, contains('CONFIDENTIAL-BODY'));

      // The round-1 terminal (tool-call) chunk is NOT forwarded as answer text,
      // nor are the started/finished tool chunks. The streamed answer is exactly
      // round 2's text deltas, in order.
      final answer = emitted
          .map(rightChunk)
          .where((c) =>
              c != null &&
              c.finishReason != RunFolderAgent.toolActivityFinishReason &&
              c.finishReason != RunFolderAgent.toolResultFinishReason)
          .map((c) => c!.delta)
          .join();
      expect(answer, 'Your message says hello.');

      // Two model rounds were streamed: tool-call round, then answer round.
      final requests = capturedRequests();
      expect(requests, hasLength(2));

      // Round 1 advertised the read-only tools.
      expect(requests[0].tools, isNotNull);
      expect(
        requests[0].tools!.map((t) => t.name),
        containsAll(
            <String>['list_emails', 'get_email', 'search_emails', 'list_folders']),
      );

      // Round 2 carries the assistant tool-call turn + the tool-result turn,
      // proving the result was fed back into the conversation.
      final toolMsg =
          requests[1].messages.firstWhere((m) => m.role == AiRole.tool);
      expect(toolMsg.toolCallId, 'call_1');
      expect(toolMsg.name, 'get_email');
      expect(toolMsg.content, contains('CONFIDENTIAL-BODY'));
      expect(
        requests[1].messages.any(
            (m) => m.role == AiRole.assistant && (m.toolCalls?.isNotEmpty ?? false)),
        isTrue,
      );
    });
  });

  group('RunFolderAgent — bounds (§3)', () {
    test(
        'every round returns a tool call → the loop stops at maxRounds with a '
        "'max_rounds' closing chunk instead of looping forever", () async {
      // Always return a fresh tool-call round, regardless of how many rounds run.
      when(mockInference.stream(any)).thenAnswer(
        (_) => toolCallRound(const [
          AiToolCall(id: 'c', name: 'list_emails', arguments: {}),
        ]),
      );

      final emitted = await useCase
          .call(history: const [], userInstruction: 'Loop please')
          .toList();

      // Bounded: exactly maxRounds model streams, one tool execution per round.
      verify(mockInference.stream(any)).called(RunFolderAgent.defaultMaxRounds);
      verify(mockGetEmails.call(any)).called(RunFolderAgent.defaultMaxRounds);

      // Each round emits a started + a finished event; every list_emails call
      // succeeds, so all finished events are marked not-error.
      expect(startedEvents(emitted), hasLength(RunFolderAgent.defaultMaxRounds));
      final finished = finishedEvents(emitted);
      expect(finished, hasLength(RunFolderAgent.defaultMaxRounds));
      expect(finished.every((c) => c.toolResult!.isError == false), isTrue);

      // The turn terminates with the max-rounds closing chunk, not a Left.
      expect(emitted.last.isRight(), isTrue);
      final last = rightChunk(emitted.last)!;
      expect(last.finishReason, 'max_rounds');
      expect(last.done, isTrue);
      expect(emitted.any((e) => e.isLeft()), isFalse);
    });
  });

  group('RunFolderAgent — configurable caps (§6)', () {
    test(
        'a configured getAgentMaxRounds() => 2 stops the loop after 2 tool-call '
        "rounds and emits the 'max_rounds' close note (overriding the default)",
        () async {
      when(mockSettings.getAgentMaxRounds())
          .thenAnswer((_) async => const Right(2));

      // Always return a fresh tool-call round, so only the cap can stop it.
      when(mockInference.stream(any)).thenAnswer(
        (_) => toolCallRound(const [
          AiToolCall(id: 'c', name: 'list_emails', arguments: {}),
        ]),
      );

      final emitted = await useCase
          .call(history: const [], userInstruction: 'Loop please')
          .toList();

      // Bounded by the configured value (2), not the default (5): exactly two
      // model streams, one tool execution per round.
      verify(mockInference.stream(any)).called(2);
      verify(mockGetEmails.call(any)).called(2);

      // One started + one finished event per round, all successful.
      expect(startedEvents(emitted), hasLength(2));
      final finished = finishedEvents(emitted);
      expect(finished, hasLength(2));
      expect(finished.every((c) => c.toolResult!.isError == false), isTrue);

      // The turn terminates with the max-rounds closing chunk, not a Left.
      expect(emitted.any((e) => e.isLeft()), isFalse);
      expect(emitted.last.isRight(), isTrue);
      final last = rightChunk(emitted.last)!;
      expect(last.finishReason, 'max_rounds');
      expect(last.done, isTrue);
    });

    test(
        'a configured getAgentMaxToolCallsPerRound() => 1 caps a single round: '
        'the first call executes, the 2nd receives the cap-exceeded error result',
        () async {
      when(mockSettings.getAgentMaxToolCallsPerRound())
          .thenAnswer((_) async => const Right(1));

      // Two calls in one round — one more than the configured cap allows.
      scriptedRounds = [
        toolCallRound(const [
          AiToolCall(id: 'c0', name: 'list_emails', arguments: {}),
          AiToolCall(id: 'c1', name: 'list_emails', arguments: {}),
        ]),
        textRound(const ['done']),
      ];

      final emitted = await useCase
          .call(history: const [], userInstruction: 'Call two tools')
          .toList();

      expect(emitted.any((e) => e.isLeft()), isFalse);

      // Only the first call actually ran the use case (cap == 1).
      verify(mockGetEmails.call(any)).called(1);

      // One finished event per call: the first succeeds, the second is a cap
      // error carrying the per-round-limit envelope.
      final finished = finishedEvents(emitted);
      expect(finished, hasLength(2));

      final first = finished.first;
      expect(first.toolResult!.callId, 'c0');
      expect(first.toolResult!.isError, isFalse);

      final overflow = finished.last;
      expect(overflow.toolResult!.callId, 'c1');
      expect(overflow.toolResult!.isError, isTrue);
      final decoded =
          jsonDecode(overflow.toolResult!.output) as Map<String, dynamic>;
      expect(decoded['error'] as String, contains('per-round tool-call limit'));
    });
  });

  group('RunFolderAgent — tool errors (§3)', () {
    test(
        'a tool returning Left(failure) is serialized into the tool-result '
        'message and the loop continues (does not abort the stream)', () async {
      when(mockGetEmail.call(any)).thenAnswer(
        (_) async =>
            const Left(ServerFailure(message: 'mailbox temporarily offline')),
      );

      scriptedRounds = [
        toolCallRound(const [
          AiToolCall(id: 'call_err', name: 'get_email', arguments: {'id': 'x'}),
        ]),
        textRound(const ['Sorry, ', 'I could not read it.']),
      ];

      final emitted = await useCase
          .call(history: const [], userInstruction: 'Read email x')
          .toList();

      // The stream was NOT aborted: no Left surfaced and the loop ran round 2.
      expect(emitted.any((e) => e.isLeft()), isFalse);
      final requests = capturedRequests();
      expect(requests, hasLength(2));

      // The failure was serialized into the tool-result turn as JSON `error`.
      final toolMsg =
          requests[1].messages.firstWhere((m) => m.role == AiRole.tool);
      final decoded = jsonDecode(toolMsg.content) as Map<String, dynamic>;
      expect(decoded['error'], 'mailbox temporarily offline');

      // The finished (tool-result) chunk for the same call is marked as an
      // error and its output is the serialized error envelope.
      final finished = finishedEvents(emitted);
      expect(finished, hasLength(1));
      expect(finished.single.toolResult!.callId, 'call_err');
      expect(finished.single.toolResult!.isError, isTrue);
      final outErr =
          jsonDecode(finished.single.toolResult!.output) as Map<String, dynamic>;
      expect(outErr['error'], 'mailbox temporarily offline');

      // Round 2's recovery text was streamed through.
      final answer = emitted
          .map(rightChunk)
          .where((c) =>
              c != null &&
              c.finishReason != RunFolderAgent.toolActivityFinishReason &&
              c.finishReason != RunFolderAgent.toolResultFinishReason)
          .map((c) => c!.delta)
          .join();
      expect(answer, 'Sorry, I could not read it.');
    });

    test(
        'a call to an unknown tool → finished event isError==true with an '
        'unknown-tool error envelope; no use case is invoked', () async {
      scriptedRounds = [
        toolCallRound(const [
          AiToolCall(id: 'call_x', name: 'no_such_tool', arguments: {}),
        ]),
        textRound(const ['handled.']),
      ];

      final emitted = await useCase
          .call(history: const [], userInstruction: 'Use a bogus tool')
          .toList();

      // The stream was not aborted and no real tool ran.
      expect(emitted.any((e) => e.isLeft()), isFalse);
      verifyNever(mockGetEmails.call(any));
      verifyNever(mockGetEmail.call(any));
      verifyNever(mockSearchEmails.call(any));
      verifyNever(mockGetMailFolders.call(any));

      // The finished chunk is an error carrying the unknown-tool envelope.
      final finished = finishedEvents(emitted);
      expect(finished, hasLength(1));
      expect(finished.single.toolResult!.callId, 'call_x');
      expect(finished.single.toolResult!.isError, isTrue);
      final decoded =
          jsonDecode(finished.single.toolResult!.output) as Map<String, dynamic>;
      expect(decoded['error'], contains('no_such_tool'));

      // The same envelope is fed back as the tool-result turn (every assistant
      // tool call still gets a matching reply).
      final toolMsg =
          capturedRequests()[1].messages.firstWhere((m) => m.role == AiRole.tool);
      expect(toolMsg.toolCallId, 'call_x');
    });

    test(
        'tool calls beyond maxToolCallsPerRound → the overflow finished events '
        'are isError==true (cap envelope) while earlier calls succeed', () async {
      // One more call than the per-round cap allows, all in a single round.
      final calls = [
        for (var i = 0; i < RunFolderAgent.defaultMaxToolCallsPerRound + 1; i++)
          AiToolCall(id: 'c$i', name: 'list_emails', arguments: const {}),
      ];

      scriptedRounds = [
        toolCallRound(calls),
        textRound(const ['done']),
      ];

      final emitted = await useCase
          .call(history: const [], userInstruction: 'Call many tools')
          .toList();

      expect(emitted.any((e) => e.isLeft()), isFalse);

      // Only the first maxToolCallsPerRound calls actually ran the use case.
      verify(mockGetEmails.call(any))
          .called(RunFolderAgent.defaultMaxToolCallsPerRound);

      // One finished event per call: the first N succeed, the overflow is a cap
      // error.
      final finished = finishedEvents(emitted);
      expect(finished, hasLength(RunFolderAgent.defaultMaxToolCallsPerRound + 1));
      expect(
        finished
            .take(RunFolderAgent.defaultMaxToolCallsPerRound)
            .every((c) => c.toolResult!.isError == false),
        isTrue,
      );

      final overflow = finished.last;
      expect(overflow.toolResult!.callId, 'c${RunFolderAgent.defaultMaxToolCallsPerRound}');
      expect(overflow.toolResult!.isError, isTrue);
      final decoded =
          jsonDecode(overflow.toolResult!.output) as Map<String, dynamic>;
      expect(decoded['error'] as String, contains('per-round tool-call limit'));
    });
  });

  group('RunFolderAgent — capability gating (§5)', () {
    test(
        'toolCall==false on a BYO/local provider → optimistic agent path: tool '
        'capability is not published by models.dev for live-discovered models, '
        'so the catalog flag is not authoritative — tools are still attempted',
        () async {
      // Local/BYO provider (e.g. Ollama qwen). The model is discovered live, so
      // its catalog toolCall flag defaults to false — that means "unknown", not
      // "unsupported", and must NOT gate tools off.
      when(mockCatalog.getModel(
        providerId: anyNamed('providerId'),
        modelId: anyNamed('modelId'),
      )).thenAnswer((_) async => Right(model(toolCall: false)));
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.local)));
      when(mockGetEmail.call(any))
          .thenAnswer((_) async => Right(email(id: 'msg1', body: 'BODY')));

      scriptedRounds = [
        toolCallRound(const [
          AiToolCall(id: 'call_1', name: 'get_email', arguments: {'id': 'msg1'}),
        ]),
        textRound(const ['Done.']),
      ];

      final emitted = await useCase
          .call(history: const [], userInstruction: 'Read msg1')
          .toList();

      // The agent loop ran: the first request advertised tools, and the model's
      // tool call was actually executed against the real use case.
      final requests = capturedRequests();
      expect(requests.first.tools, isNotNull);
      expect(requests.first.tools, isNotEmpty);
      verify(mockGetEmail.call(const GetEmailParams(id: 'msg1'))).called(1);

      // The final answer streamed through (excluding the transient
      // started/finished tool chunks).
      final answer = emitted
          .map(rightChunk)
          .whereType<AiChunk>()
          .where((c) =>
              c.finishReason != RunFolderAgent.toolActivityFinishReason &&
              c.finishReason != RunFolderAgent.toolResultFinishReason)
          .map((c) => c.delta)
          .join();
      expect(answer, 'Done.');
    });

    test(
        'toolCall==false on a cloud provider without opt-in → fallback context '
        'is withheld (includeBodies=false), instruction still sent', () async {
      when(mockCatalog.getModel(
        providerId: anyNamed('providerId'),
        modelId: anyNamed('modelId'),
      )).thenAnswer((_) async => Right(model(toolCall: false)));
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.cloud)));
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(false));

      scriptedRounds = [textRound(const ['ok'])];

      await useCase
          .call(
            history: const [],
            userInstruction: 'Summarise the folder',
            fallbackEmailsContext: 'SECRET-FOLDER-CONTEXT',
          )
          .toList();

      final request = capturedRequests().single;
      expect(request.tools, isNull);

      final userTurn =
          request.messages.lastWhere((m) => m.role == AiRole.user);
      expect(userTurn.content, isNot(contains('SECRET-FOLDER-CONTEXT')));
      expect(userTurn.content, contains('Summarise the folder'));
    });
  });

  group('RunFolderAgent — get_email privacy redaction (§4)', () {
    test(
        'cloud provider + getAllowCloudForBodies=false → includeBodies flows '
        'false to GetEmailTool: the body is withheld, preview/note returned',
        () async {
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.cloud)));
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(false));
      when(mockGetEmail.call(any)).thenAnswer(
        (_) async => Right(email(
          id: 'msg1',
          body: 'TOP-SECRET-BODY',
          preview: 'harmless preview',
        )),
      );

      scriptedRounds = [
        toolCallRound(const [
          AiToolCall(id: 'call_1', name: 'get_email', arguments: {'id': 'msg1'}),
        ]),
        textRound(const ['done']),
      ];

      await useCase
          .call(history: const [], userInstruction: 'Read msg1')
          .toList();

      // The tool-result message that round 2 sees must not leak the body.
      final toolMsg = capturedRequests()[1]
          .messages
          .firstWhere((m) => m.role == AiRole.tool && m.name == 'get_email');
      final decoded = jsonDecode(toolMsg.content) as Map<String, dynamic>;

      expect(toolMsg.content, isNot(contains('TOP-SECRET-BODY')));
      expect(decoded.containsKey('body'), isFalse);
      expect(decoded['preview'], 'harmless preview');
      expect(decoded['note'], isNotNull);
    });

    test(
        'cloud provider + getAllowCloudForBodies=true → includeBodies flows '
        'true: the full body is included in the tool result', () async {
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.cloud)));
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(true));
      when(mockGetEmail.call(any)).thenAnswer(
        (_) async => Right(email(id: 'msg1', body: 'ALLOWED-BODY')),
      );

      scriptedRounds = [
        toolCallRound(const [
          AiToolCall(id: 'call_1', name: 'get_email', arguments: {'id': 'msg1'}),
        ]),
        textRound(const ['done']),
      ];

      await useCase
          .call(history: const [], userInstruction: 'Read msg1')
          .toList();

      final toolMsg = capturedRequests()[1]
          .messages
          .firstWhere((m) => m.role == AiRole.tool && m.name == 'get_email');
      final decoded = jsonDecode(toolMsg.content) as Map<String, dynamic>;
      expect(decoded['body'], 'ALLOWED-BODY');
    });
  });
}
