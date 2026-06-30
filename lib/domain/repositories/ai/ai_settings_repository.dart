import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../entities/ai/ai_capability.dart';
import '../../entities/ai/ai_provider.dart';

/// Durable AI configuration: configured providers (including BYO), the
/// per-capability routing table, the cloud-privacy guard, and API keys.
///
/// Provider rows and routing live in the app's drift database; API keys live
/// only in `flutter_secure_storage`, keyed by `providerId` — never in drift or
/// plaintext.
abstract interface class AiSettingsRepository {
  // --- Per-capability routing ---------------------------------------------

  /// Routes [capability] to a specific `(providerId, modelId)` pair so each
  /// feature can use a different backend.
  Future<Either<Failure, Unit>> setRouting({
    required AiCapability capability,
    required String providerId,
    required String modelId,
  });

  /// The `(providerId, modelId)` routed for [capability], or `null` when none
  /// has been selected.
  Future<Either<Failure, AiRouting?>> getRouting(AiCapability capability);

  /// Removes any routing for [capability].
  Future<Either<Failure, Unit>> clearRouting(AiCapability capability);

  // --- BYO (bring-your-own) providers -------------------------------------

  /// Providers the user has explicitly configured, including BYO endpoints.
  Future<Either<Failure, List<AiProvider>>> getConfiguredProviders();

  /// Persists a user-supplied (BYO) provider — typically a custom
  /// OpenAI-compatible endpoint — returning the stored, `user`-source entry.
  Future<Either<Failure, AiProvider>> addByoProvider(AiProvider provider);

  /// Removes a configured provider (and clears any routing pointing at it).
  Future<Either<Failure, Unit>> removeProvider(String providerId);

  // --- API keys (secure storage) ------------------------------------------

  /// Stores the API key for [providerId] in secure storage.
  Future<Either<Failure, Unit>> setApiKey({
    required String providerId,
    required String apiKey,
  });

  /// The stored API key for [providerId], or `null` when none is present.
  Future<Either<Failure, String?>> getApiKey(String providerId);

  /// Deletes the stored API key for [providerId].
  Future<Either<Failure, Unit>> deleteApiKey(String providerId);

  // --- Privacy guard ------------------------------------------------------

  /// Whether sending mail bodies to cloud providers is allowed. Defaults to the
  /// safe option (`false`).
  Future<Either<Failure, bool>> getAllowCloudForBodies();

  /// Sets the "send mail bodies to cloud providers" guard.
  Future<Either<Failure, Unit>> setAllowCloudForBodies(bool allow);

  // --- Folder agent -------------------------------------------------------

  /// The maximum number of reasoning/tool rounds the folder agent may run in a
  /// single turn. Defaults to `5` and is clamped to the range `1–20`.
  Future<Either<Failure, int>> getAgentMaxRounds();

  /// Sets the folder agent's maximum rounds per turn. The value is clamped to
  /// the range `1–20` before being stored.
  Future<Either<Failure, Unit>> setAgentMaxRounds(int value);

  /// The maximum number of tool calls the folder agent may make within a single
  /// round. Defaults to `8` and is clamped to the range `1–20`.
  Future<Either<Failure, int>> getAgentMaxToolCallsPerRound();

  /// Sets the folder agent's maximum tool calls per round. The value is clamped
  /// to the range `1–20` before being stored.
  Future<Either<Failure, Unit>> setAgentMaxToolCallsPerRound(int value);
}

/// A resolved per-capability route: the provider and model a feature should use.
typedef AiRouting = ({String providerId, String modelId});
