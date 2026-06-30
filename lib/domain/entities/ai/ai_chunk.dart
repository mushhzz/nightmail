import 'package:equatable/equatable.dart';

import 'ai_tool_call.dart';
import 'ai_tool_result.dart';

/// A single streaming delta from an AI inference stream.
///
/// Deltas are appended into the compose editor live; the terminal chunk
/// ([done] == true) carries [finishReason] and usage counts. When the round
/// ends in a tool call, the terminal chunk also carries assembled [toolCalls]
/// (with [finishReason] `tool_calls`/`tool_use`).
class AiChunk extends Equatable {
  const AiChunk({
    required this.delta,
    this.done = false,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
    this.toolCalls,
    this.toolResult,
  });

  final String delta;
  final bool done;
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;

  /// Tool calls assembled by the adapter on the round's terminal chunk
  /// (null when the round produced only text).
  final List<AiToolCall>? toolCalls;

  /// The structured result of an executed tool call, carried on a tool-result
  /// chunk (finish reason `tool_result`); null on all other chunks.
  final AiToolResult? toolResult;

  @override
  List<Object?> get props => [
        delta,
        done,
        finishReason,
        promptTokens,
        completionTokens,
        toolCalls,
        toolResult,
      ];
}
