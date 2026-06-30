import 'package:equatable/equatable.dart';

/// A tool/function call requested by the model on an assistant turn.
///
/// Adapters assemble these from streamed partial tool-call JSON and surface
/// them on the round's terminal [AiChunk]. The agent loop executes the matching
/// [AgentTool] and feeds the result back as a `tool`-role [AiMessage].
class AiToolCall extends Equatable {
  const AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// Provider-assigned call id, echoed back on the tool-result message.
  final String id;

  /// The name of the tool/function the model wants to invoke.
  final String name;

  /// The parsed JSON arguments object for the call.
  final Map<String, dynamic> arguments;

  @override
  List<Object?> get props => [id, name, arguments];
}
