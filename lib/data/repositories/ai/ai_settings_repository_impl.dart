import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/ai/ai_capability.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import '../../../domain/repositories/ai/ai_settings_repository.dart';
import '../../datasources/ai/ai_config_datasource.dart';

/// Durable AI configuration backed by the [AiConfigDatasource] drift tables
/// (routing + BYO provider rows) and [FlutterSecureStorage] for API keys.
///
/// API keys are stored under [_apiKeyPrefix]`<providerId>` and never touch
/// drift. The cloud-privacy guard is a single secure-storage flag that defaults
/// to the safe option (`false`).
class AiSettingsRepositoryImpl implements AiSettingsRepository {
  const AiSettingsRepositoryImpl({
    required AiConfigDatasource configDatasource,
    required FlutterSecureStorage secureStorage,
  })  : _config = configDatasource,
        _storage = secureStorage;

  final AiConfigDatasource _config;
  final FlutterSecureStorage _storage;

  /// Secure-storage key prefix for per-provider API keys.
  static const String _apiKeyPrefix = 'ai_apikey_';

  /// Secure-storage key for the "send mail bodies to cloud providers" guard.
  static const String _allowCloudKey = 'ai_allow_cloud_for_bodies';

  /// Secure-storage keys for the configurable folder-agent caps.
  static const String _agentMaxRoundsKey = 'ai_agent_max_rounds';
  static const String _agentMaxToolCallsKey =
      'ai_agent_max_tool_calls_per_round';

  /// Cap defaults (equal to today's compile-time constants) and clamp range.
  static const int _defaultMaxRounds = 5;
  static const int _defaultMaxToolCalls = 8;
  static const int _minCap = 1;
  static const int _maxCap = 20;

  // --- Per-capability routing ---------------------------------------------

  @override
  Future<Either<Failure, Unit>> setRouting({
    required AiCapability capability,
    required String providerId,
    required String modelId,
  }) =>
      _guard(() async {
        await _config.upsertRoute(
          CapabilityRoute(
            capability: capability.name,
            providerId: providerId,
            modelId: modelId,
          ),
        );
        return unit;
      });

  @override
  Future<Either<Failure, AiRouting?>> getRouting(AiCapability capability) =>
      _guard(() async {
        final route = await _config.getRoute(capability.name);
        if (route == null) return null;
        return (providerId: route.providerId, modelId: route.modelId);
      });

  @override
  Future<Either<Failure, Unit>> clearRouting(AiCapability capability) =>
      _guard(() async {
        await _config.deleteRoute(capability.name);
        return unit;
      });

  // --- BYO (bring-your-own) providers -------------------------------------

  @override
  Future<Either<Failure, List<AiProvider>>> getConfiguredProviders() =>
      _guard(() async {
        final entries = await _config.getConfigs();
        return entries.map(_toProvider).toList();
      });

  @override
  Future<Either<Failure, AiProvider>> addByoProvider(AiProvider provider) =>
      _guard(() async {
        // Persists any configured provider — a BYO custom endpoint
        // (`source == user`) or a catalog pick (`source == catalog`). The
        // provider's own source is preserved so catalog providers stay in the
        // configured list independent of whether they are currently routed.
        final stored = AiProvider(
          id: provider.id,
          name: provider.name,
          npm: provider.npm,
          doc: provider.doc,
          env: provider.env,
          apiBaseUrl: provider.apiBaseUrl,
          kind: provider.kind,
          wireProtocol: provider.wireProtocol,
          source: provider.source,
        );
        await _config.upsertConfig(
          AiConfigEntry(
            id: stored.id,
            providerId: stored.id,
            source: stored.source.name,
            wireProtocol: stored.wireProtocol.name,
            kind: stored.kind.name,
            displayName: stored.name,
            apiBaseUrl: stored.apiBaseUrl,
          ),
        );
        return stored;
      });

  @override
  Future<Either<Failure, Unit>> removeProvider(String providerId) =>
      _guard(() async {
        final entries = await _config.getConfigs();
        for (final entry in entries) {
          if (entry.providerId == providerId) {
            await _config.deleteConfig(entry.id);
          }
        }
        final routes = await _config.getRoutes();
        for (final route in routes) {
          if (route.providerId == providerId) {
            await _config.deleteRoute(route.capability);
          }
        }
        // Best-effort secret cleanup: removing a provider must not leave its
        // API key orphaned in secure storage. A delete failure here should not
        // abort the (already-completed) config/route removal, so it's swallowed
        // while still running inside the outer `_guard`.
        try {
          await _storage.delete(key: _apiKeyKey(providerId));
        } catch (_) {
          // Ignore — the provider rows are gone; a stale key is harmless.
        }
        return unit;
      });

  // --- API keys (secure storage) ------------------------------------------

  @override
  Future<Either<Failure, Unit>> setApiKey({
    required String providerId,
    required String apiKey,
  }) =>
      _guard(() async {
        await _storage.write(key: _apiKeyKey(providerId), value: apiKey);
        return unit;
      });

  @override
  Future<Either<Failure, String?>> getApiKey(String providerId) =>
      _guard(() => _storage.read(key: _apiKeyKey(providerId)));

  @override
  Future<Either<Failure, Unit>> deleteApiKey(String providerId) =>
      _guard(() async {
        await _storage.delete(key: _apiKeyKey(providerId));
        return unit;
      });

  // --- Privacy guard ------------------------------------------------------

  @override
  Future<Either<Failure, bool>> getAllowCloudForBodies() => _guard(() async {
        final raw = await _storage.read(key: _allowCloudKey);
        return raw == 'true';
      });

  @override
  Future<Either<Failure, Unit>> setAllowCloudForBodies(bool allow) =>
      _guard(() async {
        await _storage.write(key: _allowCloudKey, value: allow.toString());
        return unit;
      });

  // --- Folder-agent caps --------------------------------------------------

  @override
  Future<Either<Failure, int>> getAgentMaxRounds() => _guard(() async {
        final raw = await _storage.read(key: _agentMaxRoundsKey);
        return _clamp(int.tryParse(raw ?? '') ?? _defaultMaxRounds);
      });

  @override
  Future<Either<Failure, Unit>> setAgentMaxRounds(int value) =>
      _guard(() async {
        await _storage.write(
          key: _agentMaxRoundsKey,
          value: _clamp(value).toString(),
        );
        return unit;
      });

  @override
  Future<Either<Failure, int>> getAgentMaxToolCallsPerRound() =>
      _guard(() async {
        final raw = await _storage.read(key: _agentMaxToolCallsKey);
        return _clamp(int.tryParse(raw ?? '') ?? _defaultMaxToolCalls);
      });

  @override
  Future<Either<Failure, Unit>> setAgentMaxToolCallsPerRound(int value) =>
      _guard(() async {
        await _storage.write(
          key: _agentMaxToolCallsKey,
          value: _clamp(value).toString(),
        );
        return unit;
      });

  // --- Helpers ------------------------------------------------------------

  String _apiKeyKey(String providerId) => '$_apiKeyPrefix$providerId';

  /// Clamps a cap value into the supported [_minCap]–[_maxCap] range so a
  /// stale or garbage stored value can never break the agent loop.
  int _clamp(int v) => v < _minCap ? _minCap : (v > _maxCap ? _maxCap : v);

  /// Runs [body], normalizing any thrown error into a [CacheFailure].
  Future<Either<Failure, T>> _guard<T>(Future<T> Function() body) async {
    try {
      return Right(await body());
    } catch (e) {
      return Left(CacheFailure(message: 'AI settings storage error: $e'));
    }
  }

  /// Rebuilds an [AiProvider] descriptor from a stored config row.
  ///
  /// BYO rows do not persist `npm` / `doc` / `env`, so these are reconstructed
  /// conservatively: a key is assumed required for every kind except
  /// [AiProviderKind.local] (local runtimes such as Ollama need none).
  AiProvider _toProvider(AiConfigEntry entry) {
    final kind = _kindFrom(entry.kind);
    return AiProvider(
      id: entry.providerId,
      name: entry.displayName ?? entry.providerId,
      npm: '',
      doc: '',
      env: kind == AiProviderKind.local
          ? const <String>[]
          : const <String>['API_KEY'],
      apiBaseUrl: entry.apiBaseUrl,
      kind: kind,
      wireProtocol: _wireProtocolFrom(entry.wireProtocol),
      source: _sourceFrom(entry.source),
    );
  }

  AiProviderKind _kindFrom(String raw) => AiProviderKind.values.firstWhere(
        (k) => k.name == raw,
        orElse: () => AiProviderKind.cloud,
      );

  AiWireProtocol _wireProtocolFrom(String raw) =>
      AiWireProtocol.values.firstWhere(
        (p) => p.name == raw,
        orElse: () => AiWireProtocol.openai,
      );

  AiProviderSource _sourceFrom(String raw) => AiProviderSource.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => AiProviderSource.user,
      );
}
