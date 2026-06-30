import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/ai/ai_capability.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import '../../../domain/repositories/ai/ai_catalog_repository.dart';
import '../../../domain/repositories/ai/ai_settings_repository.dart';
import 'ai_settings_state.dart';

/// Drives the AI settings screen.
///
/// Loads the provider catalog (catalog ∪ user BYO) from [AiCatalogRepository]
/// together with the persisted per-capability routing, lets the user pick a
/// provider + model per [AiCapability], enter and save API keys, and register
/// BYO providers — all via [AiSettingsRepository].
class AiSettingsCubit extends Cubit<AiSettingsState> {
  AiSettingsCubit({
    required AiCatalogRepository catalogRepository,
    required AiSettingsRepository settingsRepository,
  })  : _catalogRepository = catalogRepository,
        _settingsRepository = settingsRepository,
        super(const AiSettingsState());

  final AiCatalogRepository _catalogRepository;
  final AiSettingsRepository _settingsRepository;

  /// Supported range for folder-agent caps. Mirrors the clamp applied by
  /// [AiSettingsRepository], so emitted state matches the persisted value.
  static const int _minCap = 1;
  static const int _maxCap = 20;

  /// Loads providers and the current routing table.
  ///
  /// When [forceRefresh] is `true` the catalog is refreshed from models.dev in
  /// the foreground before loading.
  Future<void> load({bool forceRefresh = false}) async {
    emit(state.copyWith(status: AiSettingsStatus.loading, errorMessage: null));

    final providersResult =
        await _catalogRepository.getProviders(forceRefresh: forceRefresh);

    await providersResult.fold(
      (failure) async {
        _emitError(failure.message);
      },
      (providers) async {
        final routing = await _loadRouting();
        var configured = await _loadConfigured();
        configured = await _reconcileRouted(providers, routing, configured);
        // Privacy guard: read the "allow cloud bodies" flag; absent/error →
        // false (the safe default), so cloud routes omit the quoted body.
        final allowCloud = (await _settingsRepository.getAllowCloudForBodies())
            .getOrElse((_) => false);
        // Folder-agent caps: absent/error → today's compile-time defaults
        // (5 rounds, 8 tool calls per round). The repo also clamps to 1–20.
        final agentMaxRounds =
            (await _settingsRepository.getAgentMaxRounds()).getOrElse((_) => 5);
        final agentMaxToolCallsPerRound =
            (await _settingsRepository.getAgentMaxToolCallsPerRound())
                .getOrElse((_) => 8);
        if (isClosed) return;
        emit(state.copyWith(
          status: AiSettingsStatus.loaded,
          providers: providers,
          configured: configured,
          routing: routing,
          allowCloudForBodies: allowCloud,
          agentMaxRounds: agentMaxRounds,
          agentMaxToolCallsPerRound: agentMaxToolCallsPerRound,
          errorMessage: null,
        ));
      },
    );
  }

  Future<List<AiProvider>> _loadConfigured() async {
    final result = await _settingsRepository.getConfiguredProviders();
    return result.getOrElse((_) => const []);
  }

  /// Heals legacy state: a provider that is routed to a capability but was never
  /// persisted as configured (earlier builds only persisted BYO providers) is
  /// added to the durable configured store so it appears in the list. Returns
  /// the (possibly extended) configured list.
  Future<List<AiProvider>> _reconcileRouted(
    List<AiProvider> providers,
    Map<AiCapability, AiRouting> routing,
    List<AiProvider> configured,
  ) async {
    final have = configured.map((p) => p.id).toSet();
    final result = List<AiProvider>.from(configured);
    for (final route in routing.values) {
      if (!have.add(route.providerId)) continue;
      AiProvider? descriptor;
      for (final p in providers) {
        if (p.id == route.providerId) {
          descriptor = p;
          break;
        }
      }
      if (descriptor == null) continue;
      final saved = await _settingsRepository.addByoProvider(descriptor);
      saved.fold((_) {}, result.add);
    }
    return result;
  }

  /// Routes [capability] to a specific `(providerId, modelId)` pair.
  Future<void> setRouting({
    required AiCapability capability,
    required String providerId,
    required String modelId,
  }) async {
    final result = await _settingsRepository.setRouting(
      capability: capability,
      providerId: providerId,
      modelId: modelId,
    );
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (_) {
        final updated = Map<AiCapability, AiRouting>.from(state.routing)
          ..[capability] = (providerId: providerId, modelId: modelId);
        emit(state.copyWith(routing: updated));
      },
    );
  }

  /// Removes any routing for [capability].
  Future<void> clearRouting(AiCapability capability) async {
    final result = await _settingsRepository.clearRouting(capability);
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (_) {
        final updated = Map<AiCapability, AiRouting>.from(state.routing)
          ..remove(capability);
        emit(state.copyWith(routing: updated));
      },
    );
  }

  /// Stores the API key for [providerId] in secure storage.
  Future<void> setApiKey({
    required String providerId,
    required String apiKey,
  }) async {
    final result = await _settingsRepository.setApiKey(
      providerId: providerId,
      apiKey: apiKey,
    );
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (_) {},
    );
  }

  /// Reads the stored API key for [providerId], or `null` when none is present.
  Future<String?> getApiKey(String providerId) async {
    final result = await _settingsRepository.getApiKey(providerId);
    return result.fold(
      (failure) {
        if (!isClosed) _emitError(failure.message);
        return null;
      },
      (apiKey) => apiKey,
    );
  }

  /// Deletes the stored API key for [providerId].
  Future<void> deleteApiKey(String providerId) async {
    final result = await _settingsRepository.deleteApiKey(providerId);
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (_) {},
    );
  }

  /// Persists a configured provider (a BYO custom endpoint *or* a catalog pick,
  /// distinguished by its `source`) and adds it to the durable configured list.
  Future<void> addConfiguredProvider(AiProvider provider) async {
    final result = await _settingsRepository.addByoProvider(provider);
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (saved) {
        final updated = List<AiProvider>.from(state.configured)
          ..removeWhere((p) => p.id == saved.id)
          ..add(saved);
        emit(state.copyWith(configured: updated));
      },
    );
  }

  /// Removes a configured provider and any routing pointing at it.
  Future<void> removeProvider(String providerId) async {
    final result = await _settingsRepository.removeProvider(providerId);
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (_) {
        final configured = state.configured
            .where((p) => p.id != providerId)
            .toList(growable: false);
        final routing = Map<AiCapability, AiRouting>.from(state.routing)
          ..removeWhere((_, route) => route.providerId == providerId);
        emit(state.copyWith(configured: configured, routing: routing));
      },
    );
  }

  /// Privacy guard toggle: when `true`, quoted email bodies may be sent to
  /// cloud providers; when `false` (default, safe) the use cases omit them.
  /// Persists via [AiSettingsRepository] and reflects the new value in state.
  Future<void> setAllowCloudForBodies(bool value) async {
    final result = await _settingsRepository.setAllowCloudForBodies(value);
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (_) => emit(state.copyWith(allowCloudForBodies: value)),
    );
  }

  /// Folder-agent cap: sets the maximum number of tool-calling rounds the agent
  /// runs per turn. Persists via [AiSettingsRepository] (which clamps to 1–20)
  /// and reflects the new value in state.
  Future<void> setAgentMaxRounds(int value) async {
    final clamped = value.clamp(_minCap, _maxCap);
    final result = await _settingsRepository.setAgentMaxRounds(clamped);
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (_) => emit(state.copyWith(agentMaxRounds: clamped)),
    );
  }

  /// Folder-agent cap: sets the maximum number of tool calls the agent may make
  /// per round. Persists via [AiSettingsRepository] (which clamps to 1–20) and
  /// reflects the new value in state.
  Future<void> setAgentMaxToolCallsPerRound(int value) async {
    final clamped = value.clamp(_minCap, _maxCap);
    final result =
        await _settingsRepository.setAgentMaxToolCallsPerRound(clamped);
    if (isClosed) return;
    result.fold(
      (failure) => _emitError(failure.message),
      (_) => emit(state.copyWith(agentMaxToolCallsPerRound: clamped)),
    );
  }

  Future<Map<AiCapability, AiRouting>> _loadRouting() async {
    final routing = <AiCapability, AiRouting>{};
    for (final capability in AiCapability.values) {
      final result = await _settingsRepository.getRouting(capability);
      result.fold(
        (_) {},
        (route) {
          if (route != null) routing[capability] = route;
        },
      );
    }
    return routing;
  }

  void _emitError(String message) {
    if (isClosed) return;
    emit(state.copyWith(
      status: AiSettingsStatus.error,
      errorMessage: message,
    ));
  }
}
