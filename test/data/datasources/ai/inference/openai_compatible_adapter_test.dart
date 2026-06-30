import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/ai/inference/openai_compatible_adapter.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';
import 'package:nightmail/domain/entities/ai/ai_response.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_call.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_definition.dart';

import 'openai_compatible_adapter_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late OpenAiCompatibleAdapter adapter;
  late MockDio mockDio;

  const baseUrl = 'https://api.openai.com/v1';
  const apiKey = 'sk-test';

  final tRequest = AiRequest(
    messages: const [AiMessage(role: AiRole.user, content: 'Hello')],
    providerId: 'openai',
    modelId: 'gpt-4o-mini',
  );

  setUp(() {
    // Mockito needs a dummy value to return from the generic `post` while a
    // `when(...)` stub is being recorded; the real value comes from thenAnswer.
    provideDummy<Response<Map<String, dynamic>>>(
      Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: ''),
      ),
    );
    provideDummy<Response<ResponseBody>>(
      Response<ResponseBody>(requestOptions: RequestOptions(path: '')),
    );
    mockDio = MockDio();
    adapter = OpenAiCompatibleAdapter(dio: mockDio);
  });

  RequestOptions ro() => RequestOptions(path: '$baseUrl/chat/completions');

  group('run', () {
    test('parses a normal OpenAI chat completion into an AiResponse', () async {
      final body = <String, dynamic>{
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'Hi there!'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 11,
          'completion_tokens': 3,
          'total_tokens': 14,
        },
      };

      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: ro(),
          statusCode: 200,
          data: body,
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(
        result,
        const Right<Failure, AiResponse>(
          AiResponse(
            text: 'Hi there!',
            promptTokens: 11,
            completionTokens: 3,
            finishReason: 'stop',
          ),
        ),
      );
    });

    test('maps HTTP 401 to MissingApiKey', () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenThrow(
        DioException(
          requestOptions: ro(),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: ro(),
            statusCode: 401,
            data: {
              'error': {'message': 'Invalid API key'},
            },
          ),
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: 'bad',
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (f) => expect(f, isA<MissingApiKey>()),
        (_) => fail('expected Left'),
      );
    });

    test('maps HTTP 429 to RateLimited', () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenThrow(
        DioException(
          requestOptions: ro(),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: ro(),
            statusCode: 429,
            data: {
              'error': {'message': 'Slow down'},
            },
          ),
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (f) => expect(f, isA<RateLimited>()),
        (_) => fail('expected Left'),
      );
    });

    test('maps a connection error to ProviderUnreachable', () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenThrow(
        DioException(
          requestOptions: ro(),
          type: DioExceptionType.connectionError,
          message: 'Failed host lookup',
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (f) => expect(f, isA<ProviderUnreachable>()),
        (_) => fail('expected Left'),
      );
    });

    // L15: the 400 → ContextTooLong heuristic is otherwise unexercised.
    test('maps a context-overflow HTTP 400 to ContextTooLong', () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenThrow(
        DioException(
          requestOptions: ro(),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: ro(),
            statusCode: 400,
            data: {
              'error': {
                'message': "This model's maximum context length is 8192 "
                    'tokens. Reduce the length of the messages.',
              },
            },
          ),
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (f) => expect(f, isA<ContextTooLong>()),
        (_) => fail('expected Left'),
      );
    });

    // M6: a plain 400 (not a context overflow) must NOT be misread as
    // ContextTooLong — it falls through to a generic ProviderUnreachable.
    test('maps a non-context HTTP 400 to ProviderUnreachable', () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenThrow(
        DioException(
          requestOptions: ro(),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: ro(),
            statusCode: 400,
            data: {
              'error': {'message': 'Unsupported parameter: foo'},
            },
          ),
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (f) => expect(f, isA<ProviderUnreachable>()),
        (_) => fail('expected Left'),
      );
    });

    // M6: capture the single-shot request to pin the endpoint, the
    // `Authorization: Bearer` header and the non-streaming body shape.
    test('posts to /chat/completions with a Bearer header and stream:false',
        () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: ro(),
          statusCode: 200,
          data: const <String, dynamic>{
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          },
        ),
      );

      await adapter.run(tRequest, apiKey: apiKey, baseUrl: baseUrl);

      final captured = verify(mockDio.post<Map<String, dynamic>>(
        captureAny,
        data: captureAnyNamed('data'),
        options: captureAnyNamed('options'),
      )).captured;

      final path = captured[0] as String;
      final data = captured[1] as Map<String, dynamic>;
      final options = captured[2] as Options;

      expect(path, '$baseUrl/chat/completions');
      expect(data['model'], 'gpt-4o-mini');
      expect(data['stream'], isFalse);
      expect(options.headers?['Authorization'], 'Bearer $apiKey');
      expect(options.headers?.containsKey('api-key'), isFalse);
    });
  });

  // M6: the Azure variant must authenticate with the `api-key` header and must
  // NOT emit `Authorization: Bearer` (which Azure reserves for Entra ID tokens).
  group('useApiKeyHeader (Azure)', () {
    test('sends api-key header and omits Authorization', () async {
      final azureAdapter =
          OpenAiCompatibleAdapter(dio: mockDio, useApiKeyHeader: true);

      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: ro(),
          statusCode: 200,
          data: const <String, dynamic>{
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          },
        ),
      );

      await azureAdapter.run(tRequest, apiKey: apiKey, baseUrl: baseUrl);

      final captured = verify(mockDio.post<Map<String, dynamic>>(
        captureAny,
        data: anyNamed('data'),
        options: captureAnyNamed('options'),
      )).captured;

      final options = captured[1] as Options;
      expect(options.headers?['api-key'], apiKey);
      expect(options.headers?.containsKey('Authorization'), isFalse);
    });

    test('reports its protocol as azure', () {
      final azureAdapter =
          OpenAiCompatibleAdapter(dio: mockDio, useApiKeyHeader: true);
      expect(azureAdapter.protocol, AiWireProtocol.azure);
    });
  });

  group('stream', () {
    Uint8List sse(String s) => Uint8List.fromList(utf8.encode(s));

    test('emits delta chunks that concatenate and a final done chunk',
        () async {
      final events = <Uint8List>[
        sse('data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n'),
        sse('data: {"choices":[{"delta":{"content":", "}}]}\n\n'),
        sse('data: {"choices":[{"delta":{"content":"world"},'
            '"finish_reason":"stop"}]}\n\n'),
        sse('data: {"choices":[],"usage":'
            '{"prompt_tokens":5,"completion_tokens":2}}\n\n'),
        sse('data: [DONE]\n\n'),
      ];

      final responseBody = ResponseBody(
        Stream<Uint8List>.fromIterable(events),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );

      when(mockDio.post<ResponseBody>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<ResponseBody>(
          requestOptions: ro(),
          statusCode: 200,
          data: responseBody,
        ),
      );

      final results = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      // Every emission is a Right<Failure, AiChunk>.
      final chunks = results.map((e) {
        return e.match(
          (f) => fail('unexpected Left: $f'),
          (chunk) => chunk,
        );
      }).toList();

      final text = chunks
          .where((c) => !c.done)
          .map((c) => c.delta)
          .join();
      expect(text, 'Hello, world');

      final done = chunks.last;
      expect(done.done, isTrue);
      expect(done.finishReason, 'stop');
      expect(done.promptTokens, 5);
      expect(done.completionTokens, 2);
      expect(
        chunks.where((c) => c.done).length,
        1,
        reason: 'exactly one terminal chunk',
      );
    });

    // M6: capture the streaming request to pin the endpoint, the Bearer header
    // and the streaming body (`stream:true` + `stream_options.include_usage`,
    // which the adapter needs so usage is reported on the final SSE event).
    test('posts to /chat/completions with stream:true and include_usage',
        () async {
      final responseBody = ResponseBody(
        Stream<Uint8List>.fromIterable([sse('data: [DONE]\n\n')]),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );

      when(mockDio.post<ResponseBody>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<ResponseBody>(
          requestOptions: ro(),
          statusCode: 200,
          data: responseBody,
        ),
      );

      await adapter.stream(tRequest, apiKey: apiKey, baseUrl: baseUrl).toList();

      final captured = verify(mockDio.post<ResponseBody>(
        captureAny,
        data: captureAnyNamed('data'),
        options: captureAnyNamed('options'),
      )).captured;

      final path = captured[0] as String;
      final data = captured[1] as Map<String, dynamic>;
      final options = captured[2] as Options;

      expect(path, '$baseUrl/chat/completions');
      expect(data['stream'], isTrue);
      expect(data['stream_options'], {'include_usage': true});
      expect(options.headers?['Authorization'], 'Bearer $apiKey');
      expect(options.responseType, ResponseType.stream);
    });

    // L15: some compatible servers close the stream without a `[DONE]` sentinel.
    // The adapter must still emit exactly one terminal chunk carrying the last
    // seen finishReason/usage.
    test('emits a single terminal chunk when the stream closes without [DONE]',
        () async {
      final events = <Uint8List>[
        sse('data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n'),
        sse('data: {"choices":[{"delta":{},"finish_reason":"stop"}],'
            '"usage":{"prompt_tokens":4,"completion_tokens":1}}\n\n'),
        // no `data: [DONE]` — the server just closes the byte stream.
      ];

      final responseBody = ResponseBody(
        Stream<Uint8List>.fromIterable(events),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );

      when(mockDio.post<ResponseBody>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<ResponseBody>(
          requestOptions: ro(),
          statusCode: 200,
          data: responseBody,
        ),
      );

      final results = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      final chunks = results
          .map((e) => e.match((f) => fail('unexpected Left: $f'), (c) => c))
          .toList();

      final terminal = chunks.where((c) => c.done).toList();
      expect(terminal, hasLength(1), reason: 'exactly one terminal chunk');
      expect(terminal.single.finishReason, 'stop');
      expect(terminal.single.promptTokens, 4);
      expect(terminal.single.completionTokens, 1);
      expect(
        chunks.where((c) => !c.done).map((c) => c.delta).join(),
        'Hi',
      );
    });

    // L15: a DioException raised mid-stream (e.g. receive timeout / dropped
    // connection after the first delta) must surface as a single Left and stop —
    // never a duplicate terminal chunk.
    test('maps a mid-stream DioException to a single Left', () async {
      Stream<Uint8List> erroringStream() async* {
        yield sse('data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n');
        throw DioException(
          requestOptions: ro(),
          type: DioExceptionType.receiveTimeout,
          message: 'mid-stream drop',
        );
      }

      final responseBody = ResponseBody(
        erroringStream(),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );

      when(mockDio.post<ResponseBody>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<ResponseBody>(
          requestOptions: ro(),
          statusCode: 200,
          data: responseBody,
        ),
      );

      final results = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      final lefts = results.where((e) => e.isLeft()).toList();
      expect(lefts, hasLength(1), reason: 'a single failure terminates the stream');
      lefts.single.match(
        (f) => expect(f, isA<ProviderUnreachable>()),
        (_) => fail('expected Left'),
      );
      // The failure is terminal: no done chunk is emitted after it.
      expect(
        results.any((e) => e.match((_) => false, (c) => c.done)),
        isFalse,
        reason: 'no terminal done chunk after a mid-stream failure',
      );
    });

    test('maps a connection error to ProviderUnreachable', () async {
      when(mockDio.post<ResponseBody>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenThrow(
        DioException(
          requestOptions: ro(),
          type: DioExceptionType.connectionError,
          message: 'Failed host lookup',
        ),
      );

      final results = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(results, hasLength(1));
      results.single.match(
        (f) => expect(f, isA<ProviderUnreachable>()),
        (_) => fail('expected Left'),
      );
    });
  });

  // responses-shape: with request.shape == responses the adapter must POST the
  // OpenAI Responses API (`/responses`, body keyed on `input`) and parse its
  // typed SSE (`response.output_text.delta` / `response.completed`).
  group('responses shape', () {
    Uint8List sse(String s) => Uint8List.fromList(utf8.encode(s));

    final tResponsesRequest = tRequest.copyWith(shape: AiRequestShape.responses);

    test('run posts to /responses with an input body and parses output_text',
        () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: ro(),
          statusCode: 200,
          data: const <String, dynamic>{
            'output_text': 'Hi there!',
            'status': 'completed',
            'usage': {'input_tokens': 9, 'output_tokens': 3},
          },
        ),
      );

      final result = await adapter.run(
        tResponsesRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      final captured = verify(mockDio.post<Map<String, dynamic>>(
        captureAny,
        data: captureAnyNamed('data'),
        options: anyNamed('options'),
      )).captured;

      final path = captured[0] as String;
      final data = captured[1] as Map<String, dynamic>;

      expect(path, '$baseUrl/responses');
      expect(data.containsKey('input'), isTrue);
      expect(data.containsKey('messages'), isFalse);
      expect(data['stream'], isFalse);

      expect(
        result,
        const Right<Failure, AiResponse>(
          AiResponse(
            text: 'Hi there!',
            promptTokens: 9,
            completionTokens: 3,
            finishReason: 'completed',
          ),
        ),
      );
    });

    test('stream posts to /responses and parses output_text.delta events',
        () async {
      final events = <Uint8List>[
        sse('data: {"type":"response.output_text.delta",'
            '"delta":"Hello"}\n\n'),
        sse('data: {"type":"response.output_text.delta",'
            '"delta":", world"}\n\n'),
        sse('data: {"type":"response.completed","response":'
            '{"status":"completed","usage":'
            '{"input_tokens":7,"output_tokens":2}}}\n\n'),
      ];

      final responseBody = ResponseBody(
        Stream<Uint8List>.fromIterable(events),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );

      when(mockDio.post<ResponseBody>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<ResponseBody>(
          requestOptions: ro(),
          statusCode: 200,
          data: responseBody,
        ),
      );

      final results = await adapter
          .stream(tResponsesRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      final captured = verify(mockDio.post<ResponseBody>(
        captureAny,
        data: captureAnyNamed('data'),
        options: anyNamed('options'),
      )).captured;

      final path = captured[0] as String;
      final data = captured[1] as Map<String, dynamic>;
      expect(path, '$baseUrl/responses');
      expect(data.containsKey('input'), isTrue);
      expect(data['stream'], isTrue);

      final chunks = results
          .map((e) => e.match((f) => fail('unexpected Left: $f'), (c) => c))
          .toList();

      expect(
        chunks.where((c) => !c.done).map((c) => c.delta).join(),
        'Hello, world',
      );

      final terminal = chunks.where((c) => c.done).toList();
      expect(terminal, hasLength(1), reason: 'exactly one terminal chunk');
      expect(terminal.single.finishReason, 'completed');
      expect(terminal.single.promptTokens, 7);
      expect(terminal.single.completionTokens, 2);
    });
  });

  // §7: OpenAI-compatible tool-calling wire work. Two angles — request encoding
  // (tool defs + an assistant tool_calls turn + a tool-role result) and SSE
  // parsing (streamed delta.tool_calls fragments → assembled AiToolCalls).
  group('tool-calling request encoding', () {
    const tListEmailsTool = AiToolDefinition(
      name: 'list_emails',
      description: 'List emails in a folder.',
      parametersSchema: {
        'type': 'object',
        'properties': {
          'folder_id': {'type': 'string'},
          'unread_only': {'type': 'boolean'},
        },
      },
    );

    final tToolRequest = AiRequest(
      providerId: 'openai',
      modelId: 'gpt-4o-mini',
      tools: const [tListEmailsTool],
      messages: const [
        AiMessage(role: AiRole.user, content: 'How many unread?'),
        AiMessage(
          role: AiRole.assistant,
          // Empty content: the model only asked for a tool.
          content: '',
          toolCalls: [
            AiToolCall(
              id: 'call_abc',
              name: 'list_emails',
              arguments: {'folder_id': 'inbox', 'unread_only': true},
            ),
          ],
        ),
        AiMessage(
          role: AiRole.tool,
          content: '[{"id":"1","subject":"Hi"}]',
          toolCallId: 'call_abc',
          name: 'list_emails',
        ),
      ],
    );

    test(
        'encodes tools, tool_choice, the assistant tool_calls and the '
        'tool-role result', () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: ro(),
          statusCode: 200,
          data: const <String, dynamic>{
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'You have 1.'},
                'finish_reason': 'stop',
              },
            ],
          },
        ),
      );

      await adapter.run(tToolRequest, apiKey: apiKey, baseUrl: baseUrl);

      final captured = verify(mockDio.post<Map<String, dynamic>>(
        captureAny,
        data: captureAnyNamed('data'),
        options: anyNamed('options'),
      )).captured;
      final data = captured[1] as Map<String, dynamic>;

      // tools: [{type:'function', function:{name, description, parameters}}]
      final tools = data['tools'] as List;
      expect(tools, hasLength(1));
      final tool = tools.single as Map<String, dynamic>;
      expect(tool['type'], 'function');
      final fn = tool['function'] as Map<String, dynamic>;
      expect(fn['name'], 'list_emails');
      expect(fn['description'], 'List emails in a folder.');
      expect(fn['parameters'], tListEmailsTool.parametersSchema);

      // tool_choice is implicitly 'auto' whenever tools are present.
      expect(data['tool_choice'], 'auto');

      final messages = data['messages'] as List;
      expect(messages, hasLength(3));

      // The assistant turn carries tool_calls; content is null (was empty) and
      // arguments are serialized as a JSON *string*, not a nested object.
      final assistant = messages[1] as Map<String, dynamic>;
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], isNull);
      final calls = assistant['tool_calls'] as List;
      expect(calls, hasLength(1));
      final call = calls.single as Map<String, dynamic>;
      expect(call['id'], 'call_abc');
      expect(call['type'], 'function');
      final callFn = call['function'] as Map<String, dynamic>;
      expect(callFn['name'], 'list_emails');
      expect(callFn['arguments'], isA<String>());
      expect(
        jsonDecode(callFn['arguments'] as String),
        {'folder_id': 'inbox', 'unread_only': true},
      );

      // The tool-result turn: {role:'tool', tool_call_id, content}.
      final toolMsg = messages[2] as Map<String, dynamic>;
      expect(toolMsg['role'], 'tool');
      expect(toolMsg['tool_call_id'], 'call_abc');
      expect(toolMsg['content'], '[{"id":"1","subject":"Hi"}]');
    });

    // A request without tools must NOT advertise an empty tools array or pin a
    // tool_choice — the keys are omitted entirely.
    test('omits tools and tool_choice when no tools are supplied', () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: ro(),
          statusCode: 200,
          data: const <String, dynamic>{
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          },
        ),
      );

      await adapter.run(tRequest, apiKey: apiKey, baseUrl: baseUrl);

      final captured = verify(mockDio.post<Map<String, dynamic>>(
        captureAny,
        data: captureAnyNamed('data'),
        options: anyNamed('options'),
      )).captured;
      final data = captured[1] as Map<String, dynamic>;

      expect(data.containsKey('tools'), isFalse);
      expect(data.containsKey('tool_choice'), isFalse);
    });
  });

  group('tool-calling SSE parsing', () {
    Uint8List sse(String s) => Uint8List.fromList(utf8.encode(s));

    // jsonEncode keeps the embedded-string escaping honest so the adapter sees
    // exactly the bytes a real provider would stream.
    String dataLine(Object json) => 'data: ${jsonEncode(json)}\n\n';

    Future<List<AiChunk>> runStream(List<Uint8List> events) async {
      final responseBody = ResponseBody(
        Stream<Uint8List>.fromIterable(events),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );
      when(mockDio.post<ResponseBody>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer(
        (_) async => Response<ResponseBody>(
          requestOptions: ro(),
          statusCode: 200,
          data: responseBody,
        ),
      );
      final results = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();
      return results
          .map((e) => e.match((f) => fail('unexpected Left: $f'), (c) => c))
          .toList();
    }

    test(
        'assembles a single tool call from fragments split across chunks',
        () async {
      // id + function.name arrive on first sight; function.arguments streams as
      // a sequence of string fragments the adapter must concatenate then decode.
      final events = <Uint8List>[
        sse(dataLine({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_abc',
                    'type': 'function',
                    'function': {'name': 'list_emails', 'arguments': ''},
                  },
                ],
              },
            },
          ],
        })),
        sse(dataLine({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '{"folder_id":'},
                  },
                ],
              },
            },
          ],
        })),
        sse(dataLine({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '"inbox","limit":5}'},
                  },
                ],
              },
            },
          ],
        })),
        sse(dataLine({
          'choices': [
            {'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'},
          ],
        })),
      ];

      final chunks = await runStream(events);

      final terminal = chunks.where((c) => c.done).toList();
      expect(terminal, hasLength(1), reason: 'exactly one terminal chunk');
      expect(terminal.single.finishReason, 'tool_calls');
      expect(
        terminal.single.toolCalls,
        const [
          AiToolCall(
            id: 'call_abc',
            name: 'list_emails',
            arguments: {'folder_id': 'inbox', 'limit': 5},
          ),
        ],
      );
      // A pure tool-call round streams no visible text.
      expect(chunks.where((c) => !c.done && c.delta.isNotEmpty), isEmpty);
    });

    test('assembles multiple parallel tool calls keyed by index, in order',
        () async {
      final events = <Uint8List>[
        sse(dataLine({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_0',
                    'function': {'name': 'list_folders', 'arguments': '{}'},
                  },
                  {
                    'index': 1,
                    'id': 'call_1',
                    'function': {'name': 'search_emails', 'arguments': ''},
                  },
                ],
              },
            },
          ],
        })),
        // The second call's arguments arrive in a later chunk.
        sse(dataLine({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 1,
                    'function': {'arguments': '{"query":"invoice"}'},
                  },
                ],
              },
            },
          ],
        })),
        sse(dataLine({
          'choices': [
            {'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'},
          ],
        })),
      ];

      final chunks = await runStream(events);
      final calls = chunks.firstWhere((c) => c.done).toolCalls;
      expect(calls, isNotNull);
      expect(calls, hasLength(2));
      // Ordered by streamed index, each assembled independently.
      expect(calls![0].id, 'call_0');
      expect(calls[0].name, 'list_folders');
      expect(calls[0].arguments, isEmpty);
      expect(calls[1].id, 'call_1');
      expect(calls[1].name, 'search_emails');
      expect(calls[1].arguments, {'query': 'invoice'});
    });

    test(
        'still emits accumulated tool calls when the stream closes without a '
        'tool_calls finish_reason', () async {
      // Some compatible servers omit the finish_reason and just close the byte
      // stream; the !terminated fallback must still surface the tool call.
      final events = <Uint8List>[
        sse(dataLine({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_z',
                    'function': {
                      'name': 'get_email',
                      'arguments': '{"id":"42"}',
                    },
                  },
                ],
              },
            },
          ],
        })),
        // No finish_reason, no [DONE] — the stream just ends.
      ];

      final chunks = await runStream(events);

      final terminal = chunks.where((c) => c.done).toList();
      expect(terminal, hasLength(1));
      // The fallback terminal chunk re-labels the round as a tool-call round.
      expect(terminal.single.finishReason, 'tool_calls');
      expect(
        terminal.single.toolCalls,
        const [
          AiToolCall(
            id: 'call_z',
            name: 'get_email',
            arguments: {'id': '42'},
          ),
        ],
      );
    });

    test('decodes unparseable arguments to an empty map (never throws)',
        () async {
      final events = <Uint8List>[
        sse(dataLine({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_bad',
                    'function': {
                      'name': 'list_emails',
                      'arguments': '{not json',
                    },
                  },
                ],
              },
            },
          ],
        })),
        sse(dataLine({
          'choices': [
            {'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'},
          ],
        })),
      ];

      final chunks = await runStream(events);
      final calls = chunks.firstWhere((c) => c.done).toolCalls;
      expect(calls, hasLength(1));
      expect(calls!.single.id, 'call_bad');
      expect(calls.single.name, 'list_emails');
      expect(calls.single.arguments, isEmpty);
    });
  });
}
