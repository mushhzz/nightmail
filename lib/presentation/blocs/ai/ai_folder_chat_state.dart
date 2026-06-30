import 'package:equatable/equatable.dart';

import '../../../core/error/failures.dart';

/// A single displayable item in the folder AI chat transcript.
///
/// The transcript is heterogeneous and persistent: user/assistant text bubbles
/// ([AiTextMessage]) interleave with inline tool-call cards ([AiToolItem]). The
/// panel switches on the concrete subtype to render each. Unlike the previous
/// design — where tool progress was a transient label discarded once answer
/// text resumed — every tool call now enters the transcript as its own item and
/// stays there.
sealed class AiChatItem extends Equatable {
  const AiChatItem();

  /// Stable identity used by the panel to reconcile items across rebuilds.
  String get id;
}

/// A user or assistant text bubble (the former `AiChatMessage`).
///
/// The assistant bubble's [text] grows while the turn streams.
final class AiTextMessage extends AiChatItem {
  const AiTextMessage({
    required this.id,
    required this.isUser,
    required this.text,
  });

  @override
  final String id;

  /// True for a user turn, false for an assistant turn.
  final bool isUser;

  /// The bubble's current text (grows while an assistant turn streams).
  final String text;

  AiTextMessage copyWith({String? text}) => AiTextMessage(
        id: id,
        isUser: isUser,
        text: text ?? this.text,
      );

  @override
  List<Object?> get props => [id, isUser, text];
}

/// An inline tool-call card: a single read-only tool the agent invoked, with
/// its arguments, lifecycle [status], and (once finished) serialized [output].
///
/// Created in the [AiToolStatus.running] state when the agent starts a call,
/// then updated to [AiToolStatus.complete] / [AiToolStatus.error] with the
/// result. Display-only — never re-sent to the model.
final class AiToolItem extends AiChatItem {
  const AiToolItem({
    required this.id,
    required this.callId,
    required this.name,
    required this.args,
    this.output,
    required this.status,
  });

  @override
  final String id;

  /// The originating [AiToolCall.id], used to match the finished result back to
  /// this running card.
  final String callId;

  /// The tool/function name (e.g. `search_emails`).
  final String name;

  /// The parsed JSON arguments the model passed to the call.
  final Map<String, dynamic> args;

  /// The serialized tool result (success value or error envelope), or null
  /// while the call is still running.
  final String? output;

  /// The call's lifecycle state.
  final AiToolStatus status;

  AiToolItem copyWith({String? output, AiToolStatus? status}) => AiToolItem(
        id: id,
        callId: callId,
        name: name,
        args: args,
        output: output ?? this.output,
        status: status ?? this.status,
      );

  @override
  List<Object?> get props => [id, callId, name, args, output, status];
}

/// Lifecycle of an [AiToolItem].
enum AiToolStatus { running, complete, error }

/// State for [AiFolderCubit], driving the multi-turn folder agent chat.
///
/// Carries the full displayable transcript ([messages]) — a heterogeneous list
/// of text bubbles and inline tool cards — so the panel renders the
/// conversation directly from state, plus an [isStreaming] flag and an optional
/// [failure] for the last turn. The transient tool-activity label is gone: a
/// running tool now lives in the transcript as an [AiToolItem].
class AiFolderChatState extends Equatable {
  const AiFolderChatState({
    this.messages = const [],
    this.isStreaming = false,
    this.failure,
  });

  /// The displayable transcript, oldest first.
  final List<AiChatItem> messages;

  /// Whether an agent turn is currently streaming.
  final bool isStreaming;

  /// Set when the last turn aborted with a hard provider failure (null
  /// otherwise). Cleared when a new turn starts.
  final Failure? failure;

  AiFolderChatState copyWith({
    List<AiChatItem>? messages,
    bool? isStreaming,
    Failure? failure,
    bool clearFailure = false,
  }) {
    return AiFolderChatState(
      messages: messages ?? this.messages,
      isStreaming: isStreaming ?? this.isStreaming,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }

  @override
  List<Object?> get props => [messages, isStreaming, failure];
}
