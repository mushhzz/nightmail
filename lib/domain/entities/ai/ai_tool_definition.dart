import 'package:equatable/equatable.dart';

/// A tool the model is allowed to call, advertised on an [AiRequest].
///
/// [parametersSchema] is a JSON-Schema object describing the tool's arguments.
/// Adapters map this to their provider's tool/function declaration wire shape.
class AiToolDefinition extends Equatable {
  const AiToolDefinition({
    required this.name,
    required this.description,
    required this.parametersSchema,
  });

  /// The tool name the model references when calling it.
  final String name;

  /// A natural-language description of what the tool does.
  final String description;

  /// JSON-Schema object describing the tool's argument shape.
  final Map<String, dynamic> parametersSchema;

  @override
  List<Object?> get props => [name, description, parametersSchema];
}
