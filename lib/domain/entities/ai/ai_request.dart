import 'package:equatable/equatable.dart';

import 'ai_message.dart';
import 'ai_tool_definition.dart';

/// The wire shape an adapter should use for a request.
///
/// - [completions]: the OpenAI Chat Completions API (`/chat/completions`).
/// - [responses]: the OpenAI Responses API (`/responses`).
///
/// Resolved per-model from the provider catalog (a model's `providerOverride`
/// may declare `shape: 'responses'`); features never set this directly.
enum AiRequestShape { completions, responses }

/// A normalized inference request handed to an [AiAdapter].
///
/// Adapters map this to their provider's wire format; features never construct
/// provider-specific shapes.
class AiRequest extends Equatable {
  const AiRequest({
    required this.messages,
    required this.providerId,
    required this.modelId,
    this.temperature,
    this.maxTokens,
    this.stream = false,
    this.shape = AiRequestShape.completions,
    this.tools,
  });

  final List<AiMessage> messages;
  final String providerId;
  final String modelId;
  final double? temperature;
  final int? maxTokens;
  final bool stream;

  /// The wire shape the adapter should use (completions vs responses).
  final AiRequestShape shape;

  /// Tools the model may call (null = no tools). When present, adapters
  /// advertise them and use an implicit `tool_choice: auto`.
  final List<AiToolDefinition>? tools;

  AiRequest copyWith({
    List<AiMessage>? messages,
    String? providerId,
    String? modelId,
    double? temperature,
    int? maxTokens,
    bool? stream,
    AiRequestShape? shape,
    List<AiToolDefinition>? tools,
  }) {
    return AiRequest(
      messages: messages ?? this.messages,
      providerId: providerId ?? this.providerId,
      modelId: modelId ?? this.modelId,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      stream: stream ?? this.stream,
      shape: shape ?? this.shape,
      tools: tools ?? this.tools,
    );
  }

  @override
  List<Object?> get props => [
        messages,
        providerId,
        modelId,
        temperature,
        maxTokens,
        stream,
        shape,
        tools,
      ];
}
