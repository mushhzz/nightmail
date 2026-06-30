import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/ai/inference/google_adapter.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';
import 'package:nightmail/domain/entities/ai/ai_response.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_call.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_definition.dart';

import 'google_adapter_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GoogleAdapter adapter;

  setUp(() {
    // Mockito cannot synthesize dummy values for the Response<T> generics that
    // dio.post returns, so register them explicitly.
    provideDummy<Response<dynamic>>(
      Response<dynamic>(requestOptions: RequestOptions(path: '')),
    );
    provideDummy<Response<ResponseBody>>(
      Response<ResponseBody>(requestOptions: RequestOptions(path: '')),
    );

    mockDio = MockDio();
    adapter = GoogleAdapter(dio: mockDio);
  });

  const baseUrl = 'https://generativelanguage.googleapis.com/v1beta';
  const apiKey = 'AIza-test-key';

  final tRequest = AiRequest(
    providerId: 'google',
    modelId: 'gemini-1.5-flash',
    maxTokens: 256,
    temperature: 0.5,
    messages: const [
      AiMessage(role: AiRole.system, content: 'You are helpful.'),
      AiMessage(role: AiRole.assistant, content: 'Hi, how can I help?'),
      AiMessage(role: AiRole.user, content: 'Hello there.'),
    ],
  );

  DioException dioErrorWithStatus(int status, {Object? data}) => DioException(
        requestOptions: RequestOptions(path: '/models'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/models'),
          statusCode: status,
          data: data,
        ),
        type: DioExceptionType.badResponse,
      );

  group('run', () {
    test('parses a Gemini generateContent response into an AiResponse',
        () async {
      final responseJson = {
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': 'Hello, '},
                {'text': 'world'},
              ],
            },
            'finishReason': 'STOP',
          },
        ],
        'usageMetadata': {
          'promptTokenCount': 11,
          'candidatesTokenCount': 7,
        },
      };

      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: responseJson,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
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
            text: 'Hello, world',
            promptTokens: 11,
            completionTokens: 7,
            finishReason: 'STOP',
          ),
        ),
      );
    });

    test('sends the x-goog-api-key header, builds systemInstruction from the '
        'system message, and maps assistant -> model in contents', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: const {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      await adapter.run(tRequest, apiKey: apiKey, baseUrl: baseUrl);

      final captured = verify(
        mockDio.post<dynamic>(
          captureAny,
          data: captureAnyNamed('data'),
          options: captureAnyNamed('options'),
        ),
      ).captured;

      final path = captured[0] as String;
      final body = captured[1] as Map<String, dynamic>;
      final options = captured[2] as Options;

      // Native generateContent endpoint with the model id baked into the path.
      expect(path, '$baseUrl/models/gemini-1.5-flash:generateContent');

      // Auth header.
      expect(options.headers!['x-goog-api-key'], apiKey);

      // System message hoisted into systemInstruction.
      final systemInstruction =
          body['systemInstruction'] as Map<String, dynamic>;
      final systemParts = (systemInstruction['parts'] as List)
          .cast<Map<String, dynamic>>();
      expect(systemParts.single['text'], 'You are helpful.');

      // contents carry only user/assistant turns; assistant -> model.
      final contents = (body['contents'] as List).cast<Map<String, dynamic>>();
      expect(contents, [
        {
          'role': 'model',
          'parts': [
            {'text': 'Hi, how can I help?'},
          ],
        },
        {
          'role': 'user',
          'parts': [
            {'text': 'Hello there.'},
          ],
        },
      ]);
      expect(
        contents.any((c) => c['role'] == 'system' || c['role'] == 'assistant'),
        isFalse,
        reason: 'system/assistant roles must not appear in contents',
      );

      // generationConfig carries temperature + maxOutputTokens.
      final generationConfig =
          body['generationConfig'] as Map<String, dynamic>;
      expect(generationConfig['temperature'], 0.5);
      expect(generationConfig['maxOutputTokens'], 256);
    });

    test('strips a stale trailing /openai from the base URL', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: const {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/',
      );

      final captured = verify(
        mockDio.post<dynamic>(
          captureAny,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).captured;

      expect(
        captured.single,
        'https://generativelanguage.googleapis.com/v1beta'
        '/models/gemini-1.5-flash:generateContent',
      );
    });

    test('maps a generic HTTP 400 to ProviderUnreachable (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(
        dioErrorWithStatus(
          400,
          data: const {
            'error': {'message': 'Invalid value at generationConfig'},
          },
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<ProviderUnreachable>()),
        (_) => fail('expected a Left'),
      );
    });

    test('maps a 400 "API key not valid" to MissingApiKey (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(
        dioErrorWithStatus(
          400,
          data: const {
            'error': {'message': 'API key not valid. Please pass a valid key.'},
          },
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<MissingApiKey>()),
        (_) => fail('expected a Left'),
      );
    });

    test('maps a 400 context-overflow message to ContextTooLong (Left)',
        () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(
        dioErrorWithStatus(
          400,
          data: const {
            'error': {
              'message': 'The input token count (1052576) exceeds the maximum '
                  'number of tokens allowed (1048576).',
            },
          },
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<ContextTooLong>()),
        (_) => fail('expected a Left'),
      );
    });

    test('maps HTTP 401 and 403 to MissingApiKey (Left)', () async {
      for (final status in const [401, 403]) {
        when(
          mockDio.post<dynamic>(
            any,
            data: anyNamed('data'),
            options: anyNamed('options'),
          ),
        ).thenThrow(dioErrorWithStatus(status));

        final result = await adapter.run(
          tRequest,
          apiKey: apiKey,
          baseUrl: baseUrl,
        );

        expect(result.isLeft(), isTrue, reason: 'status $status');
        result.match(
          (failure) =>
              expect(failure, isA<MissingApiKey>(), reason: 'status $status'),
          (_) => fail('expected a Left for status $status'),
        );
      }
    });

    test('maps a 5xx to ProviderUnreachable (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(dioErrorWithStatus(503));

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<ProviderUnreachable>()),
        (_) => fail('expected a Left'),
      );
    });

    test('a null or empty apiKey returns MissingApiKey before any network call',
        () async {
      final result = await adapter.run(tRequest, apiKey: '', baseUrl: baseUrl);

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<MissingApiKey>()),
        (_) => fail('expected a Left'),
      );
      verifyNever(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      );
    });

    test('a non-Map response body yields ProviderUnreachable (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: 'not a json object',
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<ProviderUnreachable>()),
        (_) => fail('expected a Left'),
      );
    });

    test('an empty candidates list surfaces promptFeedback.blockReason as the '
        'finishReason', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: const {
            'candidates': <dynamic>[],
            'promptFeedback': {'blockReason': 'SAFETY'},
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isRight(), isTrue);
      final response = result.getOrElse((_) => throw StateError('left'));
      expect(response.text, '');
      expect(response.finishReason, 'SAFETY');
    });

    test('a models/-prefixed modelId does not double the /models path segment',
        () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: const {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      await adapter.run(
        const AiRequest(
          providerId: 'google',
          modelId: 'models/gemini-1.5-flash',
          messages: [AiMessage(role: AiRole.user, content: 'Hi')],
        ),
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      final captured = verify(
        mockDio.post<dynamic>(
          captureAny,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).captured;

      expect(
        captured.single,
        '$baseUrl/models/gemini-1.5-flash:generateContent',
      );
    });

    test('maps HTTP 429 to RateLimited (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(dioErrorWithStatus(429));

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<RateLimited>()),
        (_) => fail('expected a Left'),
      );
    });

    test('maps a connection error to ProviderUnreachable (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/models'),
          type: DioExceptionType.connectionError,
          message: 'Connection refused',
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<ProviderUnreachable>()),
        (_) => fail('expected a Left'),
      );
    });
  });

  group('stream', () {
    Uint8List sse(String s) => Uint8List.fromList(utf8.encode(s));

    test('concatenates candidate part text and emits exactly one terminal done '
        'chunk with finishReason and usage', () async {
      final events = <Uint8List>[
        sse(
          'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}\n\n',
        ),
        sse(
          'data: {"candidates":[{"content":{"parts":[{"text":", world"}]}}]}'
          '\n\n',
        ),
        sse(
          'data: {"candidates":[{"content":{"parts":[{"text":"!"}]},'
          '"finishReason":"STOP"}],'
          '"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":12}}'
          '\n\n',
        ),
      ];

      final responseBody = ResponseBody(Stream.fromIterable(events), 200);

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: responseBody,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      // No Left chunks.
      expect(chunks.every((c) => c.isRight()), isTrue);

      final aiChunks = chunks
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .toList();

      // Deltas concatenate to the full text.
      final text = aiChunks.map((c) => c.delta).join();
      expect(text, 'Hello, world!');

      // Exactly one terminal chunk carrying done + finishReason + usage.
      expect(aiChunks.where((c) => c.done).length, 1);
      final done = aiChunks.last;
      expect(done.done, isTrue);
      expect(done.delta, '');
      expect(done.finishReason, 'STOP');
      expect(done.promptTokens, 7);
      expect(done.completionTokens, 12);

      // The visible deltas precede the terminal chunk.
      expect(
        aiChunks.takeWhile((c) => !c.done).map((c) => c.delta).toList(),
        const ['Hello', ', world', '!'],
      );
    });

    test('uses a streaming responseType + SSE endpoint and the api-key header',
        () async {
      final responseBody = ResponseBody(
        Stream.fromIterable(<Uint8List>[
          sse(
            'data: {"candidates":[{"content":{"parts":[{"text":"hi"}]},'
            '"finishReason":"STOP"}]}\n\n',
          ),
        ]),
        200,
      );

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: responseBody,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      final captured = verify(
        mockDio.post<ResponseBody>(
          captureAny,
          data: anyNamed('data'),
          options: captureAnyNamed('options'),
        ),
      ).captured;

      final path = captured[0] as String;
      final options = captured[1] as Options;

      expect(
        path,
        '$baseUrl/models/gemini-1.5-flash:streamGenerateContent?alt=sse',
      );
      expect(options.responseType, ResponseType.stream);
      expect(options.receiveTimeout, Duration.zero);
      expect(options.headers!['x-goog-api-key'], apiKey);
      expect(options.headers!['accept'], 'text/event-stream');
    });

    test('yields ProviderUnreachable when the response body is null', () async {
      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: null,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks, hasLength(1));
      chunks.single.match(
        (failure) => expect(failure, isA<ProviderUnreachable>()),
        (_) => fail('expected a Left'),
      );
    });

    test('maps a DioException during the request to a Left failure', () async {
      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(dioErrorWithStatus(429));

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks, hasLength(1));
      chunks.single.match(
        (failure) => expect(failure, isA<RateLimited>()),
        (_) => fail('expected a Left'),
      );
    });

    test('decodes a multibyte code point split across two byte chunks',
        () async {
      // "😀" (U+1F600) encodes to 4 UTF-8 bytes. Frame the SSE event so the
      // emoji's bytes straddle a chunk boundary; a stateful utf8.decoder must
      // carry the partial code point over rather than emitting U+FFFD.
      final full = utf8.encode(
        'data: {"candidates":[{"content":{"parts":[{"text":"hi😀"}]},'
        '"finishReason":"STOP"}]}\n\n',
      );
      final splitAt = full.indexOf(0xF0); // first byte of the emoji
      final events = <Uint8List>[
        Uint8List.fromList(full.sublist(0, splitAt + 2)),
        Uint8List.fromList(full.sublist(splitAt + 2)),
      ];

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: ResponseBody(Stream.fromIterable(events), 200),
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks.every((c) => c.isRight()), isTrue);
      final text = chunks
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .map((c) => c.delta)
          .join();
      expect(text, 'hi😀');
    });

    test('a delta-only stream with no finishReason emits exactly one terminal '
        'done chunk with a null finishReason', () async {
      final events = <Uint8List>[
        sse('data: {"candidates":[{"content":{"parts":[{"text":"a"}]}}]}\n\n'),
        sse('data: {"candidates":[{"content":{"parts":[{"text":"b"}]}}]}\n\n'),
      ];

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: ResponseBody(Stream.fromIterable(events), 200),
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks.every((c) => c.isRight()), isTrue);
      final aiChunks = chunks
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .toList();

      expect(aiChunks.map((c) => c.delta).join(), 'ab');
      final done = aiChunks.where((c) => c.done).toList();
      expect(done, hasLength(1));
      expect(done.single.delta, '');
      expect(done.single.finishReason, isNull);
    });

    test('a mid-stream error event yields a Left and stops the stream',
        () async {
      final events = <Uint8List>[
        sse('data: {"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}\n\n'),
        sse(
          'data: {"error":{"code":429,"message":"RESOURCE_EXHAUSTED",'
          '"status":"RESOURCE_EXHAUSTED"}}\n\n',
        ),
        sse(
          'data: {"candidates":[{"content":{"parts":[{"text":"never"}]},'
          '"finishReason":"STOP"}]}\n\n',
        ),
      ];

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: ResponseBody(Stream.fromIterable(events), 200),
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      // The first delta is emitted, then a Left, and nothing after it.
      expect(chunks.last.isLeft(), isTrue);
      chunks.last.match(
        (failure) => expect(failure, isA<RateLimited>()),
        (_) => fail('expected the terminal emission to be a Left'),
      );
      // No terminal done chunk after the error.
      final rights = chunks
          .where((c) => c.isRight())
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .toList();
      expect(rights.any((c) => c.done), isFalse);
      expect(rights.map((c) => c.delta).join(), 'hi');
    });

    test('a null or empty apiKey yields MissingApiKey before any network call',
        () async {
      final chunks = await adapter
          .stream(tRequest, apiKey: '', baseUrl: baseUrl)
          .toList();

      expect(chunks, hasLength(1));
      chunks.single.match(
        (failure) => expect(failure, isA<MissingApiKey>()),
        (_) => fail('expected a Left'),
      );
      verifyNever(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      );
    });
  });

  group('tool support (§7)', () {
    Uint8List sse(String s) => Uint8List.fromList(utf8.encode(s));

    const listEmailsTool = AiToolDefinition(
      name: 'list_emails',
      description: 'List emails in the current folder.',
      parametersSchema: {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer'},
        },
        'required': ['limit'],
      },
    );

    // Stub a benign non-stream generateContent response so `run` reaches the
    // body-building path without throwing; the tests only inspect the captured
    // request body, not the response.
    void stubOkResponse() {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: const {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );
    }

    Map<String, dynamic> capturedBody() {
      final captured = verify(
        mockDio.post<dynamic>(
          any,
          data: captureAnyNamed('data'),
          options: anyNamed('options'),
        ),
      ).captured;
      return captured.single as Map<String, dynamic>;
    }

    test('advertises request tools as a single functionDeclarations block',
        () async {
      stubOkResponse();

      await adapter.run(
        const AiRequest(
          providerId: 'google',
          modelId: 'gemini-1.5-flash',
          messages: [
            AiMessage(role: AiRole.user, content: 'What is in my inbox?'),
          ],
          tools: [listEmailsTool],
        ),
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      final body = capturedBody();

      expect(body['tools'], [
        {
          'functionDeclarations': [
            {
              'name': 'list_emails',
              'description': 'List emails in the current folder.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'limit': {'type': 'integer'},
                },
                'required': ['limit'],
              },
            },
          ],
        },
      ]);
    });

    test('omits the tools key entirely when no tools are supplied', () async {
      stubOkResponse();

      await adapter.run(
        const AiRequest(
          providerId: 'google',
          modelId: 'gemini-1.5-flash',
          messages: [AiMessage(role: AiRole.user, content: 'Hi')],
        ),
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(capturedBody().containsKey('tools'), isFalse);
    });

    test(
        'encodes an assistant tool call as a model functionCall part and a '
        'tool result as a user functionResponse part', () async {
      stubOkResponse();

      await adapter.run(
        const AiRequest(
          providerId: 'google',
          modelId: 'gemini-1.5-flash',
          tools: [listEmailsTool],
          messages: [
            AiMessage(role: AiRole.user, content: 'Summarize my unread mail.'),
            AiMessage(
              role: AiRole.assistant,
              content: '',
              toolCalls: [
                AiToolCall(
                  id: 'list_emails-0',
                  name: 'list_emails',
                  arguments: {'limit': 5},
                ),
              ],
            ),
            AiMessage(
              role: AiRole.tool,
              content: 'Found 3 unread emails.',
              name: 'list_emails',
              toolCallId: 'list_emails-0',
            ),
          ],
        ),
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      final contents =
          (capturedBody()['contents'] as List).cast<Map<String, dynamic>>();

      // The assistant turn (spelled `model`) carries a functionCall part with
      // the call's name + parsed args, and no spurious empty text part.
      final modelTurn = contents.firstWhere((c) => c['role'] == 'model');
      final modelParts =
          (modelTurn['parts'] as List).cast<Map<String, dynamic>>();
      expect(modelParts, [
        {
          'functionCall': {
            'name': 'list_emails',
            'args': {'limit': 5},
          },
        },
      ]);

      // The tool-result turn maps to a user-role functionResponse part keyed
      // back to the function by name, with the result wrapped in {result: ...}.
      final responseTurn = contents.lastWhere(
        (c) => (c['parts'] as List)
            .any((p) => (p as Map).containsKey('functionResponse')),
      );
      expect(responseTurn['role'], 'user');
      final responseParts =
          (responseTurn['parts'] as List).cast<Map<String, dynamic>>();
      expect(responseParts.single['functionResponse'], {
        'name': 'list_emails',
        'response': {'result': 'Found 3 unread emails.'},
      });

      // No tool-result content leaks out as a plain assistant/model text part.
      expect(
        modelParts.any((p) => p.containsKey('text')),
        isFalse,
        reason: 'an empty assistant content must not emit a text part',
      );
    });

    test(
        'assembles streamed functionCall parts into toolCalls on a single '
        'terminal chunk with a tool_calls finishReason', () async {
      final events = <Uint8List>[
        sse(
          'data: {"candidates":[{"content":{"role":"model","parts":['
          '{"functionCall":{"name":"list_emails","args":{"limit":5}}},'
          '{"functionCall":{"name":"get_email","args":{"id":"42"}}}'
          ']},"finishReason":"STOP"}],'
          '"usageMetadata":{"promptTokenCount":40,"candidatesTokenCount":9}}'
          '\n\n',
        ),
      ];

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: ResponseBody(Stream.fromIterable(events), 200),
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks.every((c) => c.isRight()), isTrue);
      final aiChunks = chunks
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .toList();

      // A pure tool-call round emits no visible text deltas, only the terminal.
      expect(aiChunks.where((c) => !c.done).any((c) => c.delta.isNotEmpty),
          isFalse);

      final done = aiChunks.singleWhere((c) => c.done);
      expect(done.delta, '');
      // The Gemini finishReason (STOP) is overridden with the normalized
      // tool_calls signal so the agent loop knows to execute the calls.
      expect(done.finishReason, 'tool_calls');
      expect(done.promptTokens, 40);
      expect(done.completionTokens, 9);

      // Both functionCall parts are assembled, in order, with synthesized
      // `<name>-<ordinal>` ids and parsed argument maps.
      expect(done.toolCalls, [
        const AiToolCall(
          id: 'list_emails-0',
          name: 'list_emails',
          arguments: {'limit': 5},
        ),
        const AiToolCall(
          id: 'get_email-1',
          name: 'get_email',
          arguments: {'id': '42'},
        ),
      ]);
    });

    test(
        'emits leading text deltas and still assembles a trailing functionCall '
        'into the terminal toolCalls', () async {
      final events = <Uint8List>[
        sse(
          'data: {"candidates":[{"content":{"role":"model","parts":['
          '{"text":"Let me check. "}]}}]}\n\n',
        ),
        sse(
          'data: {"candidates":[{"content":{"role":"model","parts":['
          '{"functionCall":{"name":"list_emails","args":{}}}'
          ']},"finishReason":"STOP"}]}\n\n',
        ),
      ];

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: ResponseBody(Stream.fromIterable(events), 200),
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      final aiChunks = chunks
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .toList();

      // The pre-call narration is streamed as a visible delta.
      expect(
        aiChunks.takeWhile((c) => !c.done).map((c) => c.delta).join(),
        'Let me check. ',
      );

      // Exactly one terminal chunk, carrying the empty-args call and the
      // tool_calls finishReason.
      final done = aiChunks.singleWhere((c) => c.done);
      expect(done.finishReason, 'tool_calls');
      expect(done.toolCalls, [
        const AiToolCall(
          id: 'list_emails-0',
          name: 'list_emails',
          arguments: <String, dynamic>{},
        ),
      ]);
    });
  });
}
