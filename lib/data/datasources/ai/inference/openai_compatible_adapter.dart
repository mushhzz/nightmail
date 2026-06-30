import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import '../../../../domain/entities/ai/ai_chunk.dart';
import '../../../../domain/entities/ai/ai_message.dart';
import '../../../../domain/entities/ai/ai_provider.dart';
import '../../../../domain/entities/ai/ai_request.dart';
import '../../../../domain/entities/ai/ai_response.dart';
import '../../../../domain/entities/ai/ai_tool_call.dart';
import '../../../../domain/entities/ai/ai_tool_definition.dart';
import 'ai_adapter.dart';

/// Fallback base URL used only when an empty [baseUrl] is supplied.
const _kDefaultOpenAiBaseUrl = 'https://api.openai.com/v1';

/// Wire adapter for any OpenAI-compatible Chat Completions endpoint.
///
/// Covers OpenAI itself plus self-hosted / proxy backends that speak the same
/// schema (Groq, OpenRouter, vLLM, LM Studio, …). A single instance serves
/// every provider on the [AiWireProtocol.openai] protocol — credentials and the
/// endpoint are passed per call. The shared [Dio] singleton is injected once and
/// never rebuilt.
///
/// Ollama ([AiWireProtocol.ollama]) is also served here — its `/v1`
/// OpenAI-compatibility surface accepts the same `tools` array, so the §7
/// tool-calling wire work in this adapter covers Ollama too (no separate adapter).
class OpenAiCompatibleAdapter implements AiAdapter {
  const OpenAiCompatibleAdapter({
    required Dio dio,
    this.useApiKeyHeader = false,
  }) : _dio = dio;

  final Dio _dio;

  /// When true the key is sent as the `api-key` header instead of
  /// `Authorization: Bearer` — required by Azure OpenAI / AI Foundry, where
  /// Bearer is reserved for Entra ID (AAD) tokens.
  final bool useApiKeyHeader;

  @override
  AiWireProtocol get protocol =>
      useApiKeyHeader ? AiWireProtocol.azure : AiWireProtocol.openai;

  /// Resolves the request endpoint for the given [shape], tolerating a trailing
  /// slash and falling back to OpenAI's public URL only if [baseUrl] is blank.
  ///
  /// - [AiRequestShape.completions] → `{base}/chat/completions`
  /// - [AiRequestShape.responses]   → `{base}/responses` (OpenAI Responses API)
  String _endpoint(String baseUrl, AiRequestShape shape) {
    final base = baseUrl.trim().isEmpty ? _kDefaultOpenAiBaseUrl : baseUrl.trim();
    final normalized =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final path = shape == AiRequestShape.responses
        ? '/responses'
        : '/chat/completions';
    return '$normalized$path';
  }

  Map<String, String> _headers(String? apiKey, {bool sse = false}) {
    final hasKey = apiKey != null && apiKey.isNotEmpty;
    return {
      'Content-Type': 'application/json',
      'Accept': sse ? 'text/event-stream' : 'application/json',
      if (hasKey && useApiKeyHeader) 'api-key': apiKey,
      if (hasKey && !useApiKeyHeader) 'Authorization': 'Bearer $apiKey',
    };
  }

  Map<String, dynamic> _baseBody(AiRequest request) => {
        'model': request.modelId,
        'messages': request.messages.map(_encodeMessage).toList(),
        if (request.temperature != null) 'temperature': request.temperature,
        if (request.maxTokens != null) 'max_tokens': request.maxTokens,
        if (request.tools != null && request.tools!.isNotEmpty) ...{
          'tools': request.tools!.map(_encodeTool).toList(),
          'tool_choice': 'auto',
        },
      };

  /// Request body for the OpenAI Responses API (`/responses`).
  ///
  /// The Responses schema differs from Chat Completions: messages are passed as
  /// `input` (it accepts the same `{role, content}` item shape) and the token
  /// cap is `max_output_tokens` rather than `max_tokens`.
  Map<String, dynamic> _responsesBody(AiRequest request) => {
        'model': request.modelId,
        'input': request.messages.map(_encodeMessage).toList(),
        if (request.temperature != null) 'temperature': request.temperature,
        if (request.maxTokens != null) 'max_output_tokens': request.maxTokens,
        // Tool calling is NOT yet implemented for the Responses shape: the
        // Responses API uses a different `tools` schema (flat
        // `{type, name, description, parameters}`, not the Chat-Completions
        // `{type:'function', function:{…}}` shape produced by [_encodeTool]),
        // and the Responses parsers do not yet read tool-call output. Attaching
        // the Chat-Completions wiring here would send malformed tools and
        // silently drop any tool calls, so it is intentionally omitted — a
        // responses request simply runs without tools until proper Responses
        // tool wiring + parsing lands.
      };

  /// Encodes an [AiToolDefinition] into the OpenAI `function`-tool wire shape.
  Map<String, dynamic> _encodeTool(AiToolDefinition tool) => {
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parametersSchema,
        },
      };

  Map<String, dynamic> _encodeMessage(AiMessage m) {
    // A `tool`-role turn carries the result of an executed tool call, keyed
    // back to the originating call via `tool_call_id`.
    if (m.role == AiRole.tool) {
      return {
        'role': 'tool',
        if (m.toolCallId != null) 'tool_call_id': m.toolCallId,
        'content': m.content,
      };
    }

    // An assistant turn requesting tools emits `tool_calls`; its textual
    // `content` may be empty/null when the model only asked for tools.
    final toolCalls = m.toolCalls;
    if (m.role == AiRole.assistant &&
        toolCalls != null &&
        toolCalls.isNotEmpty) {
      return {
        'role': 'assistant',
        'content': m.content.isEmpty ? null : m.content,
        'tool_calls': [
          for (final call in toolCalls)
            {
              'id': call.id,
              'type': 'function',
              'function': {
                'name': call.name,
                'arguments': jsonEncode(call.arguments),
              },
            },
        ],
      };
    }

    return {
      'role': m.role.name,
      'content': m.content,
    };
  }

  // --------------------------------------------------------------------------
  // Single-shot
  // --------------------------------------------------------------------------

  @override
  Future<Either<Failure, AiResponse>> run(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async {
    final isResponses = request.shape == AiRequestShape.responses;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        _endpoint(baseUrl, request.shape),
        data: isResponses
            ? {..._responsesBody(request), 'stream': false}
            : {..._baseBody(request), 'stream': false},
        options: Options(headers: _headers(apiKey)),
      );

      final data = response.data;
      if (data == null) {
        return const Left(
          ProviderUnreachable(message: 'Empty response from provider.'),
        );
      }

      return isResponses
          ? _parseResponsesBody(data)
          : _parseCompletionsBody(data);
    } on DioException catch (e) {
      return Left(_mapDioError(e));
    } catch (e) {
      // L12: log the raw cause; surface a fixed user-safe message.
      debugPrint('OpenAiCompatibleAdapter.run failed: $e');
      return const Left(
        ProviderUnreachable(message: 'The AI request failed unexpectedly.'),
      );
    }
  }

  /// Parses a Chat Completions (`/chat/completions`) single-shot body.
  Either<Failure, AiResponse> _parseCompletionsBody(
    Map<String, dynamic> data,
  ) {
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) {
      return const Left(
        ProviderUnreachable(
          message: 'Provider response contained no choices.',
        ),
      );
    }

    final choice = choices.first as Map<String, dynamic>;
    final message = choice['message'];
    final content = (message is Map) ? message['content'] : null;
    final finishReason = choice['finish_reason'] as String?;

    int? promptTokens;
    int? completionTokens;
    final usage = data['usage'];
    if (usage is Map) {
      promptTokens = (usage['prompt_tokens'] as num?)?.toInt();
      completionTokens = (usage['completion_tokens'] as num?)?.toInt();
    }

    return Right(
      AiResponse(
        text: content is String ? content : '',
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        finishReason: finishReason,
      ),
    );
  }

  /// Parses a Responses API (`/responses`) single-shot body.
  ///
  /// Accepts both the SDK convenience `output_text` field and the raw `output`
  /// array of message items (each carrying `content[].type == 'output_text'`).
  /// Usage uses the Responses token names (`input_tokens` / `output_tokens`).
  Either<Failure, AiResponse> _parseResponsesBody(Map<String, dynamic> data) {
    var text = '';
    final outputText = data['output_text'];
    if (outputText is String) {
      text = outputText;
    } else if (outputText is List) {
      text = outputText.whereType<String>().join();
    } else {
      final output = data['output'];
      if (output is List) {
        final buffer = StringBuffer();
        for (final item in output) {
          if (item is! Map) continue;
          final content = item['content'];
          if (content is! List) continue;
          for (final part in content) {
            if (part is Map && part['type'] == 'output_text') {
              final t = part['text'];
              if (t is String) buffer.write(t);
            }
          }
        }
        text = buffer.toString();
      }
    }

    final status = data['status'];
    final finishReason = status is String ? status : null;

    int? promptTokens;
    int? completionTokens;
    final usage = data['usage'];
    if (usage is Map) {
      promptTokens = (usage['input_tokens'] as num?)?.toInt();
      completionTokens = (usage['output_tokens'] as num?)?.toInt();
    }

    return Right(
      AiResponse(
        text: text,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        finishReason: finishReason,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Streaming (SSE over Dio)
  // --------------------------------------------------------------------------

  @override
  Stream<Either<Failure, AiChunk>> stream(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async* {
    final isResponses = request.shape == AiRequestShape.responses;
    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        _endpoint(baseUrl, request.shape),
        data: isResponses
            ? {..._responsesBody(request), 'stream': true}
            : {
                ..._baseBody(request),
                'stream': true,
                'stream_options': {'include_usage': true},
              },
        options: Options(
          headers: _headers(apiKey, sse: true),
          responseType: ResponseType.stream,
          // M2-stream: the shared Dio singleton carries a 60s `receiveTimeout`
          // (a sane default for one-shot calls) which would otherwise cut a
          // long generation off mid-stream. Disable the per-call receive
          // timeout so the stream runs to its natural end; the connect timeout
          // still bounds the handshake.
          receiveTimeout: Duration.zero,
        ),
      );
    } on DioException catch (e) {
      yield Left(_mapDioError(e));
      return;
    } catch (e) {
      // L12: log the raw cause; surface a fixed user-safe message.
      debugPrint('OpenAiCompatibleAdapter.stream request failed: $e');
      yield const Left(
        ProviderUnreachable(message: 'The AI request failed unexpectedly.'),
      );
      return;
    }

    final body = response.data;
    if (body == null) {
      yield const Left(
        ProviderUnreachable(message: 'Empty stream from provider.'),
      );
      return;
    }

    // Decode the byte stream with a single stateful `utf8.decoder` so multibyte
    // code points split across dio/TCP chunk boundaries carry over; the
    // `LineSplitter` then yields whole SSE lines regardless of byte framing.
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    if (isResponses) {
      yield* _parseResponsesSse(lines);
    } else {
      yield* _parseCompletionsSse(lines);
    }
  }

  /// Parses the Chat Completions SSE stream (`data:` JSON with `choices[].delta`,
  /// terminated by `data: [DONE]`).
  Stream<Either<Failure, AiChunk>> _parseCompletionsSse(
    Stream<String> lines,
  ) async* {
    String? finishReason;
    int? promptTokens;
    int? completionTokens;
    var terminated = false;

    // Streamed `delta.tool_calls[]` fragments accumulated by their `index`:
    // the id + function.name arrive on first sight, while function.arguments
    // is delivered as a sequence of string fragments that we concatenate.
    final toolIds = <int, String>{};
    final toolNames = <int, String>{};
    final toolArgs = <int, StringBuffer>{};

    // Assembles the accumulated fragments into [AiToolCall]s, JSON-decoding
    // each arguments string into a Map (empty Map if blank or unparseable).
    // Returns null when no tool-call fragments were seen.
    List<AiToolCall>? buildToolCalls() {
      final indices = <int>{
        ...toolIds.keys,
        ...toolNames.keys,
        ...toolArgs.keys,
      }.toList()
        ..sort();
      if (indices.isEmpty) return null;

      final calls = <AiToolCall>[];
      for (final i in indices) {
        final argStr = toolArgs[i]?.toString() ?? '';
        Map<String, dynamic> args;
        try {
          final decoded =
              argStr.trim().isEmpty ? <String, dynamic>{} : jsonDecode(argStr);
          args = decoded is Map
              ? Map<String, dynamic>.from(decoded)
              : <String, dynamic>{};
        } catch (_) {
          args = <String, dynamic>{};
        }
        calls.add(
          AiToolCall(
            id: toolIds[i] ?? '',
            name: toolNames[i] ?? '',
            arguments: args,
          ),
        );
      }
      return calls;
    }

    try {
      await for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || !line.startsWith('data:')) continue;

        final payload = line.substring(5).trim();
        if (payload == '[DONE]') {
          terminated = true;
          final calls = buildToolCalls();
          yield Right(
            AiChunk(
              delta: '',
              done: true,
              finishReason: calls != null ? 'tool_calls' : finishReason,
              promptTokens: promptTokens,
              completionTokens: completionTokens,
              toolCalls: calls,
            ),
          );
          return;
        }

        Map<String, dynamic> json;
        try {
          json = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          // Skip keep-alive / non-JSON SSE comment lines.
          continue;
        }

        final usage = json['usage'];
        if (usage is Map) {
          promptTokens = (usage['prompt_tokens'] as num?)?.toInt();
          completionTokens = (usage['completion_tokens'] as num?)?.toInt();
        }

        final choices = json['choices'];
        if (choices is List && choices.isNotEmpty) {
          final choice = choices.first as Map<String, dynamic>;
          final fr = choice['finish_reason'];
          if (fr is String) finishReason = fr;

          final delta = choice['delta'];
          if (delta is Map) {
            final content = delta['content'];
            if (content is String && content.isNotEmpty) {
              yield Right(AiChunk(delta: content));
            }

            final fragments = delta['tool_calls'];
            if (fragments is List) {
              for (final fragment in fragments) {
                if (fragment is! Map) continue;
                final index = (fragment['index'] as num?)?.toInt() ?? 0;
                final id = fragment['id'];
                if (id is String && id.isNotEmpty) toolIds[index] = id;
                final function = fragment['function'];
                if (function is Map) {
                  final name = function['name'];
                  if (name is String && name.isNotEmpty) {
                    toolNames[index] = name;
                  }
                  final args = function['arguments'];
                  if (args is String) {
                    (toolArgs[index] ??= StringBuffer()).write(args);
                  }
                }
              }
            }
          }

          // A terminal `tool_calls` round: emit the assembled calls and stop.
          if (finishReason == 'tool_calls') {
            terminated = true;
            yield Right(
              AiChunk(
                delta: '',
                done: true,
                finishReason: 'tool_calls',
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                toolCalls: buildToolCalls(),
              ),
            );
            return;
          }
        }
      }
    } on DioException catch (e) {
      yield Left(_mapDioError(e));
      return;
    } catch (e) {
      // L12: log the raw cause; surface a fixed user-safe message.
      debugPrint('OpenAiCompatibleAdapter completions stream interrupted: $e');
      yield const Left(
        ProviderUnreachable(message: 'The AI response stream was interrupted.'),
      );
      return;
    }

    // Some compatible servers close the stream without an explicit `[DONE]`.
    // If tool-call fragments accumulated without a `tool_calls` finish_reason,
    // still surface them as a terminal tool-call chunk.
    if (!terminated) {
      final calls = buildToolCalls();
      yield Right(
        AiChunk(
          delta: '',
          done: true,
          finishReason: calls != null ? 'tool_calls' : finishReason,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          toolCalls: calls,
        ),
      );
    }
  }

  /// Parses the Responses API SSE stream. Each `data:` line is a typed event:
  /// `response.output_text.delta` carries an incremental `delta`, and
  /// `response.completed` is terminal (carrying final `status` + usage under
  /// `response`). `response.failed` / `error` surface a fixed failure.
  Stream<Either<Failure, AiChunk>> _parseResponsesSse(
    Stream<String> lines,
  ) async* {
    String? finishReason;
    int? promptTokens;
    int? completionTokens;
    var terminated = false;

    try {
      await for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || !line.startsWith('data:')) continue;

        final payload = line.substring(5).trim();
        // The Responses stream terminates via `response.completed`, but tolerate
        // a trailing `[DONE]` sentinel emitted by some proxies.
        if (payload == '[DONE]') {
          if (!terminated) {
            terminated = true;
            yield Right(
              AiChunk(
                delta: '',
                done: true,
                finishReason: finishReason,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
              ),
            );
          }
          return;
        }

        Map<String, dynamic> json;
        try {
          json = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          // Skip keep-alive / non-JSON SSE comment lines.
          continue;
        }

        final type = json['type'];
        if (type == 'response.output_text.delta') {
          final delta = json['delta'];
          if (delta is String && delta.isNotEmpty) {
            yield Right(AiChunk(delta: delta));
          }
        } else if (type == 'response.completed') {
          final completed = json['response'];
          if (completed is Map) {
            final status = completed['status'];
            if (status is String) finishReason = status;
            final usage = completed['usage'];
            if (usage is Map) {
              promptTokens = (usage['input_tokens'] as num?)?.toInt();
              completionTokens = (usage['output_tokens'] as num?)?.toInt();
            }
          }
          terminated = true;
          yield Right(
            AiChunk(
              delta: '',
              done: true,
              finishReason: finishReason,
              promptTokens: promptTokens,
              completionTokens: completionTokens,
            ),
          );
          return;
        } else if (type == 'response.failed' || type == 'error') {
          // L12: do not echo the provider's raw error body; fixed message.
          yield const Left(
            ProviderUnreachable(
              message: 'The AI provider failed to complete the response.',
            ),
          );
          return;
        }
      }
    } on DioException catch (e) {
      yield Left(_mapDioError(e));
      return;
    } catch (e) {
      // L12: log the raw cause; surface a fixed user-safe message.
      debugPrint('OpenAiCompatibleAdapter responses stream interrupted: $e');
      yield const Left(
        ProviderUnreachable(message: 'The AI response stream was interrupted.'),
      );
      return;
    }

    // Some servers close the stream without an explicit `response.completed`.
    if (!terminated) {
      yield Right(
        AiChunk(
          delta: '',
          done: true,
          finishReason: finishReason,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
        ),
      );
    }
  }

  // --------------------------------------------------------------------------
  // Error normalization
  // --------------------------------------------------------------------------

  Failure _mapDioError(DioException e) {
    final status = e.response?.statusCode;

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
        // L12: log the raw cause for diagnostics; surface a fixed, user-safe
        // message (never the raw `e.message`, which can leak URLs/details).
        debugPrint('OpenAiCompatibleAdapter transport error: ${e.type.name}: '
            '${e.message}');
        return const ProviderUnreachable(
          message: 'Could not reach the AI provider. '
              'Check your connection and try again.',
        );
      case DioExceptionType.cancel:
        return const ProviderUnreachable(message: 'AI request was cancelled.');
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }

    if (status == null) {
      debugPrint('OpenAiCompatibleAdapter transport error: ${e.type.name}: '
          '${e.message}');
      return const ProviderUnreachable(
        message: 'Could not reach the AI provider. '
            'Check your connection and try again.',
      );
    }

    // L12: extract the provider's error text for *classification only* — the
    // 400 context-overflow heuristic needs it — but never surface it verbatim,
    // since 4xx bodies can echo request fragments. Log it for diagnostics.
    final detail = _extractErrorMessage(e.response?.data);
    if (detail != null) {
      debugPrint('OpenAiCompatibleAdapter provider error (HTTP $status): '
          '$detail');
    }

    if (status == 401 || status == 403) {
      return MissingApiKey(
        message: 'The AI provider rejected the API key (HTTP $status). '
            'Check it in AI settings.',
      );
    }
    if (status == 429) {
      return const RateLimited(
        message: 'The AI provider is rate limiting requests (HTTP 429). '
            'Try again shortly.',
      );
    }
    if (status == 400 && _looksLikeContextOverflow(detail)) {
      return const ContextTooLong(
        message: 'This message is too long for the selected model. '
            'Shorten it and try again.',
      );
    }

    return ProviderUnreachable(
      message: 'The AI provider returned an error (HTTP $status).',
    );
  }

  /// Best-effort extraction of a human message from an OpenAI-style error body,
  /// used only to classify failures (e.g. context-overflow) and for diagnostic
  /// logging — never surfaced to the user verbatim (see [_mapDioError]).
  ///
  /// Tolerates the body being a parsed Map, a raw JSON string, or absent.
  String? _extractErrorMessage(Object? data) {
    if (data == null) return null;

    Object? decoded = data;
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.isEmpty) return null;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        return trimmed;
      }
    }

    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        final msg = error['message'];
        if (msg is String && msg.isNotEmpty) return msg;
      }
      if (error is String && error.isNotEmpty) return error;
      final msg = decoded['message'];
      if (msg is String && msg.isNotEmpty) return msg;
    }
    return null;
  }

  /// Heuristic for distinguishing a context-window 400 from other bad requests.
  bool _looksLikeContextOverflow(String? detail) {
    if (detail == null) return false;
    final d = detail.toLowerCase();
    return d.contains('context_length_exceeded') ||
        d.contains('context length') ||
        d.contains('context window') ||
        d.contains('maximum context') ||
        d.contains('reduce the length') ||
        d.contains('too many tokens') ||
        (d.contains('token') && d.contains('maximum'));
  }
}
