import 'package:equatable/equatable.dart';

import '../../../domain/entities/ai/ai_capability.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import '../../../domain/repositories/ai/ai_settings_repository.dart';

/// Lifecycle of the AI settings screen.
enum AiSettingsStatus { loading, loaded, error }

/// State for [AiSettingsCubit].
///
/// Holds the full provider catalog (catalog ∪ user BYO), the per-capability
/// routing table, and transient status/error information for the AI settings UI.
class AiSettingsState extends Equatable {
  const AiSettingsState({
    this.status = AiSettingsStatus.loading,
    this.providers = const [],
    this.configured = const [],
    this.routing = const {},
    this.allowCloudForBodies = false,
    this.agentMaxRounds = 5,
    this.agentMaxToolCallsPerRound = 8,
    this.errorMessage,
  });

  /// Current lifecycle status.
  final AiSettingsStatus status;

  /// All known providers — the full catalog ∪ user BYO entries, each
  /// `source`-tagged. Used to browse the catalog and look up models.
  final List<AiProvider> providers;

  /// Providers the user has explicitly configured (durable, from the
  /// `ai_config` drift table): every BYO endpoint plus any catalog provider the
  /// user added. These persist regardless of routing.
  final List<AiProvider> configured;

  /// Per-capability routing: which `(providerId, modelId)` each feature uses.
  final Map<AiCapability, AiRouting> routing;

  /// Privacy guard: when `false` (default, safe), the quoted original email
  /// body is omitted from prompts routed to a cloud provider. Set to `true` to
  /// allow sending message bodies to cloud providers.
  final bool allowCloudForBodies;

  /// Folder-agent cap: how many tool-calling rounds the agent may run per turn.
  /// Default `5`, clamped to 1–20 by the repository.
  final int agentMaxRounds;

  /// Folder-agent cap: how many tool calls the agent may make per round.
  /// Default `8`, clamped to 1–20 by the repository.
  final int agentMaxToolCallsPerRound;

  /// Human-readable error message when [status] is [AiSettingsStatus.error].
  final String? errorMessage;

  /// Providers filtered by their privacy/hosting [kind].
  List<AiProvider> providersOfKind(AiProviderKind kind) =>
      providers.where((p) => p.kind == kind).toList(growable: false);

  /// The routing for [capability], or `null` when none has been selected.
  AiRouting? routingFor(AiCapability capability) => routing[capability];

  AiSettingsState copyWith({
    AiSettingsStatus? status,
    List<AiProvider>? providers,
    List<AiProvider>? configured,
    Map<AiCapability, AiRouting>? routing,
    bool? allowCloudForBodies,
    int? agentMaxRounds,
    int? agentMaxToolCallsPerRound,
    Object? errorMessage = _unset,
  }) {
    return AiSettingsState(
      status: status ?? this.status,
      providers: providers ?? this.providers,
      configured: configured ?? this.configured,
      routing: routing ?? this.routing,
      allowCloudForBodies: allowCloudForBodies ?? this.allowCloudForBodies,
      agentMaxRounds: agentMaxRounds ?? this.agentMaxRounds,
      agentMaxToolCallsPerRound:
          agentMaxToolCallsPerRound ?? this.agentMaxToolCallsPerRound,
      errorMessage: errorMessage == _unset
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  @override
  List<Object?> get props => [
        status,
        providers,
        configured,
        routing,
        allowCloudForBodies,
        agentMaxRounds,
        agentMaxToolCallsPerRound,
        errorMessage,
      ];
}

const _unset = Object();
