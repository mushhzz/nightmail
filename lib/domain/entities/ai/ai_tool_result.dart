import 'package:equatable/equatable.dart';

/// The structured outcome of a single executed tool call, surfaced on the
/// stream so the presentation layer can render a persistent tool card.
///
/// [callId] matches the originating [AiToolCall.id]; [output] is the serialized
/// tool result (success value or error envelope); [isError] is `true` when the
/// outcome was an error (tool `Left`, unknown tool, or per-round cap).
class AiToolResult extends Equatable {
  const AiToolResult({
    required this.callId,
    required this.output,
    required this.isError,
  });

  final String callId;
  final String output;
  final bool isError;

  @override
  List<Object?> get props => [callId, output, isError];
}
