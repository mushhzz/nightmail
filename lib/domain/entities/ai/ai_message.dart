import 'package:equatable/equatable.dart';

import 'ai_tool_call.dart';

/// The role of a message in an AI conversation.
///
/// [tool] is a tool-result turn: it carries the output of an executed tool
/// call, keyed back to the originating call via [AiMessage.toolCallId].
enum AiRole { system, user, assistant, tool }

/// A single message in an AI inference request.
class AiMessage extends Equatable {
  const AiMessage({
    required this.role,
    required this.content,
    this.toolCalls,
    this.toolCallId,
    this.name,
  });

  final AiRole role;
  final String content;

  /// Tool calls requested on an assistant turn (null otherwise).
  final List<AiToolCall>? toolCalls;

  /// On a [AiRole.tool] result turn, the id of the call this answers.
  final String? toolCallId;

  /// On a [AiRole.tool] result turn, the name of the tool that produced it.
  final String? name;

  AiMessage copyWith({
    AiRole? role,
    String? content,
    List<AiToolCall>? toolCalls,
    String? toolCallId,
    String? name,
  }) {
    return AiMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId ?? this.toolCallId,
      name: name ?? this.name,
    );
  }

  @override
  List<Object?> get props => [role, content, toolCalls, toolCallId, name];
}
