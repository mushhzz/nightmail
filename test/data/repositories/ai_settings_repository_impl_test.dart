import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/ai/ai_config_datasource.dart';
import 'package:nightmail/data/repositories/ai/ai_settings_repository_impl.dart';
import 'package:nightmail/domain/entities/ai/ai_capability.dart';
import 'package:nightmail/domain/repositories/ai/ai_settings_repository.dart';

import 'ai_settings_repository_impl_test.mocks.dart';

@GenerateMocks([AiConfigDatasource, FlutterSecureStorage])
void main() {
  late AiSettingsRepositoryImpl repository;
  late MockAiConfigDatasource mockConfig;
  late MockFlutterSecureStorage mockStorage;

  // Mirrors the private constants in AiSettingsRepositoryImpl so the tests
  // assert against the exact secure-storage keys the impl reads/writes.
  const apiKeyPrefix = 'ai_apikey_';
  const allowCloudKey = 'ai_allow_cloud_for_bodies';
  const agentMaxRoundsKey = 'ai_agent_max_rounds';
  const agentMaxToolCallsKey = 'ai_agent_max_tool_calls_per_round';

  setUp(() {
    mockConfig = MockAiConfigDatasource();
    mockStorage = MockFlutterSecureStorage();
    repository = AiSettingsRepositoryImpl(
      configDatasource: mockConfig,
      secureStorage: mockStorage,
    );
  });

  group('getAllowCloudForBodies', () {
    test('returns Right(false) when the key is absent (safe default)', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => null);

      final result = await repository.getAllowCloudForBodies();

      expect(result, const Right<Failure, bool>(false));
      verify(mockStorage.read(key: allowCloudKey));
    });

    test('returns Right(true) when the stored value is the string "true"',
        () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => 'true');

      final result = await repository.getAllowCloudForBodies();

      expect(result, const Right<Failure, bool>(true));
    });

    test('returns Right(false) for any non-"true" stored value', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => 'false');

      final result = await repository.getAllowCloudForBodies();

      expect(result, const Right<Failure, bool>(false));
    });
  });

  group('setAllowCloudForBodies', () {
    test('persists the stringified true flag under the guard key', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result = await repository.setAllowCloudForBodies(true);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: allowCloudKey, value: 'true'));
    });

    test('persists the stringified false flag under the guard key', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result = await repository.setAllowCloudForBodies(false);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: allowCloudKey, value: 'false'));
    });

    test('round-trips through storage: a written true reads back as true',
        () async {
      // Capture what setAllowCloudForBodies writes, then feed it back into read
      // to prove the stringify/parse pair are inverses.
      String? written;
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((invocation) async {
        written = invocation.namedArguments[const Symbol('value')] as String?;
      });
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => written);

      await repository.setAllowCloudForBodies(true);
      final readBack = await repository.getAllowCloudForBodies();

      expect(written, 'true');
      expect(readBack, const Right<Failure, bool>(true));
    });
  });

  group('getAgentMaxRounds', () {
    test('returns Right(5) when the key is absent (default)', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => null);

      final result = await repository.getAgentMaxRounds();

      expect(result, const Right<Failure, int>(5));
      verify(mockStorage.read(key: agentMaxRoundsKey));
    });

    test('returns Right(5) when the stored value is non-numeric', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => 'not-a-number');

      final result = await repository.getAgentMaxRounds();

      expect(result, const Right<Failure, int>(5));
    });

    test('returns the stored value when within range', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => '7');

      final result = await repository.getAgentMaxRounds();

      expect(result, const Right<Failure, int>(7));
    });

    test('clamps a stored value below the minimum up to 1', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => '0');

      final result = await repository.getAgentMaxRounds();

      expect(result, const Right<Failure, int>(1));
    });

    test('clamps a stored value above the maximum down to 20', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => '999');

      final result = await repository.getAgentMaxRounds();

      expect(result, const Right<Failure, int>(20));
    });
  });

  group('setAgentMaxRounds', () {
    test('persists the stringified value under the cap key', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result = await repository.setAgentMaxRounds(7);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: agentMaxRoundsKey, value: '7'));
    });

    test('clamps a below-range value up to 1 before writing', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result = await repository.setAgentMaxRounds(0);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: agentMaxRoundsKey, value: '1'));
    });

    test('clamps an above-range value down to 20 before writing', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result = await repository.setAgentMaxRounds(999);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: agentMaxRoundsKey, value: '20'));
    });

    test('round-trips through storage: a written value reads back clamped',
        () async {
      // Capture what setAgentMaxRounds writes, then feed it back into read to
      // prove the stringify/parse-and-clamp pair are inverses.
      String? written;
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((invocation) async {
        written = invocation.namedArguments[const Symbol('value')] as String?;
      });
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => written);

      await repository.setAgentMaxRounds(12);
      final readBack = await repository.getAgentMaxRounds();

      expect(written, '12');
      expect(readBack, const Right<Failure, int>(12));
    });
  });

  group('getAgentMaxToolCallsPerRound', () {
    test('returns Right(8) when the key is absent (default)', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => null);

      final result = await repository.getAgentMaxToolCallsPerRound();

      expect(result, const Right<Failure, int>(8));
      verify(mockStorage.read(key: agentMaxToolCallsKey));
    });

    test('returns Right(8) when the stored value is non-numeric', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => 'garbage');

      final result = await repository.getAgentMaxToolCallsPerRound();

      expect(result, const Right<Failure, int>(8));
    });

    test('returns the stored value when within range', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => '3');

      final result = await repository.getAgentMaxToolCallsPerRound();

      expect(result, const Right<Failure, int>(3));
    });

    test('clamps a stored value below the minimum up to 1', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => '0');

      final result = await repository.getAgentMaxToolCallsPerRound();

      expect(result, const Right<Failure, int>(1));
    });

    test('clamps a stored value above the maximum down to 20', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => '999');

      final result = await repository.getAgentMaxToolCallsPerRound();

      expect(result, const Right<Failure, int>(20));
    });
  });

  group('setAgentMaxToolCallsPerRound', () {
    test('persists the stringified value under the cap key', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result = await repository.setAgentMaxToolCallsPerRound(3);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: agentMaxToolCallsKey, value: '3'));
    });

    test('clamps a below-range value up to 1 before writing', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result = await repository.setAgentMaxToolCallsPerRound(0);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: agentMaxToolCallsKey, value: '1'));
    });

    test('clamps an above-range value down to 20 before writing', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result = await repository.setAgentMaxToolCallsPerRound(999);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: agentMaxToolCallsKey, value: '20'));
    });

    test('round-trips through storage: a written value reads back clamped',
        () async {
      String? written;
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((invocation) async {
        written = invocation.namedArguments[const Symbol('value')] as String?;
      });
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => written);

      await repository.setAgentMaxToolCallsPerRound(4);
      final readBack = await repository.getAgentMaxToolCallsPerRound();

      expect(written, '4');
      expect(readBack, const Right<Failure, int>(4));
    });
  });

  group('API keys', () {
    test('getApiKey reads from the prefixed secure-storage key', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => 'sk-secret');

      final result = await repository.getApiKey('openai');

      expect(result, const Right<Failure, String?>('sk-secret'));
      verify(mockStorage.read(key: '${apiKeyPrefix}openai'));
    });

    test('getApiKey returns Right(null) when no key is stored', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => null);

      final result = await repository.getApiKey('openai');

      expect(result, const Right<Failure, String?>(null));
    });

    test('setApiKey writes the key under the prefixed key', () async {
      when(mockStorage.write(
        key: anyNamed('key'),
        value: anyNamed('value'),
      )).thenAnswer((_) async {});

      final result =
          await repository.setApiKey(providerId: 'anthropic', apiKey: 'sk-xyz');

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.write(key: '${apiKeyPrefix}anthropic', value: 'sk-xyz'));
    });

    test('deleteApiKey deletes the prefixed key', () async {
      when(mockStorage.delete(key: anyNamed('key'))).thenAnswer((_) async {});

      final result = await repository.deleteApiKey('anthropic');

      expect(result, Right<Failure, Unit>(unit));
      verify(mockStorage.delete(key: '${apiKeyPrefix}anthropic'));
    });
  });

  group('removeProvider', () {
    test('deletes matching config rows, routes, and the API key (L8)',
        () async {
      const targetId = 'openai';
      final configs = [
        const AiConfigEntry(
          id: 'cfg-1',
          providerId: targetId,
          source: 'user',
          wireProtocol: 'openai',
          kind: 'cloud',
        ),
        const AiConfigEntry(
          id: 'cfg-2',
          providerId: 'anthropic',
          source: 'user',
          wireProtocol: 'anthropic',
          kind: 'cloud',
        ),
      ];
      final routes = [
        const CapabilityRoute(
          capability: 'compose',
          providerId: targetId,
          modelId: 'gpt-4o',
        ),
        const CapabilityRoute(
          capability: 'summarize',
          providerId: 'anthropic',
          modelId: 'claude-3',
        ),
      ];
      when(mockConfig.getConfigs()).thenAnswer((_) async => configs);
      when(mockConfig.getRoutes()).thenAnswer((_) async => routes);
      when(mockConfig.deleteConfig(any)).thenAnswer((_) async {});
      when(mockConfig.deleteRoute(any)).thenAnswer((_) async {});
      when(mockStorage.delete(key: anyNamed('key'))).thenAnswer((_) async {});

      final result = await repository.removeProvider(targetId);

      expect(result, Right<Failure, Unit>(unit));
      // Only the matching config row and route are removed.
      verify(mockConfig.deleteConfig('cfg-1'));
      verifyNever(mockConfig.deleteConfig('cfg-2'));
      verify(mockConfig.deleteRoute('compose'));
      verifyNever(mockConfig.deleteRoute('summarize'));
      // The orphaned API key is also cleaned up (L8 finding).
      verify(mockStorage.delete(key: '${apiKeyPrefix}$targetId'));
    });

    test('still succeeds when the secret cleanup throws', () async {
      const targetId = 'openai';
      when(mockConfig.getConfigs()).thenAnswer((_) async => const []);
      when(mockConfig.getRoutes()).thenAnswer((_) async => const []);
      when(mockStorage.delete(key: anyNamed('key')))
          .thenThrow(Exception('keychain locked'));

      final result = await repository.removeProvider(targetId);

      // The swallowed key-delete failure must not abort the removal.
      expect(result, Right<Failure, Unit>(unit));
    });
  });

  group('routing CRUD', () {
    test('setRouting upserts a CapabilityRoute for the capability', () async {
      when(mockConfig.upsertRoute(any)).thenAnswer((_) async {});

      final result = await repository.setRouting(
        capability: AiCapability.compose,
        providerId: 'openai',
        modelId: 'gpt-4o',
      );

      expect(result, Right<Failure, Unit>(unit));
      final captured =
          verify(mockConfig.upsertRoute(captureAny)).captured.single
              as CapabilityRoute;
      expect(captured.capability, 'compose');
      expect(captured.providerId, 'openai');
      expect(captured.modelId, 'gpt-4o');
    });

    test('getRouting returns the stored (providerId, modelId) tuple', () async {
      when(mockConfig.getRoute('compose')).thenAnswer(
        (_) async => const CapabilityRoute(
          capability: 'compose',
          providerId: 'openai',
          modelId: 'gpt-4o',
        ),
      );

      final result = await repository.getRouting(AiCapability.compose);

      expect(result.isRight(), isTrue);
      final routing = result.getOrElse((_) => null);
      expect(routing?.providerId, 'openai');
      expect(routing?.modelId, 'gpt-4o');
    });

    test('getRouting returns Right(null) when no route exists', () async {
      when(mockConfig.getRoute(any)).thenAnswer((_) async => null);

      final result = await repository.getRouting(AiCapability.search);

      expect(result, const Right<Failure, AiRouting?>(null));
    });

    test('clearRouting deletes the route for the capability', () async {
      when(mockConfig.deleteRoute(any)).thenAnswer((_) async {});

      final result = await repository.clearRouting(AiCapability.triage);

      expect(result, Right<Failure, Unit>(unit));
      verify(mockConfig.deleteRoute('triage'));
    });
  });

  group('Failure mapping', () {
    test('maps a storage throw to a CacheFailure (Left)', () async {
      when(mockStorage.read(key: anyNamed('key')))
          .thenThrow(Exception('keychain unavailable'));

      final result = await repository.getApiKey('openai');

      expect(result.isLeft(), isTrue);
      final failure = result.getLeft().toNullable();
      expect(failure, isA<CacheFailure>());
      expect(failure?.message, contains('AI settings storage error'));
    });

    test('maps a datasource throw to a CacheFailure (Left)', () async {
      when(mockConfig.getRoute(any))
          .thenThrow(Exception('drift query failed'));

      final result = await repository.getRouting(AiCapability.compose);

      expect(result.isLeft(), isTrue);
      expect(result.getLeft().toNullable(), isA<CacheFailure>());
    });
  });
}
