import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/ai/ai_capability.dart';
import '../../../domain/entities/ai/ai_model.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import '../../../domain/repositories/ai/ai_catalog_repository.dart';
import '../../../injection_container.dart';
import '../../blocs/ai/ai_settings_cubit.dart';
import '../../blocs/ai/ai_settings_state.dart';

/// AI settings section.
///
/// Three halves:
///
/// * **Configured providers** — the (initially empty) durable list of providers
///   the user has set up (BYO endpoints and catalog picks). Each row stores an
///   API key (optional for local/BYO endpoints) and can be removed.
/// * **Compose** — the only live AI feature: choose which configured provider +
///   model drafts and replies to mail.
/// * **Privacy** — the cloud-bodies guard (default OFF/safe): whether the quoted
///   original email body may be sent to a *cloud* provider during compose.
///
/// Unlike the sibling settings sections (`_AppearanceSection`, `_GeneralSection`,
/// `_SecuritySection`), which are private inline widgets in `settings_page.dart`,
/// this section is intentionally a standalone public page: it is large enough to
/// warrant its own file and is already well-decomposed into ~13 private widgets
/// below, so it lives in `pages/settings/` rather than bloating the host page.
///
/// Self-contained: it provides its own [AiSettingsCubit] from `get_it`.
class AiSettingsPage extends StatelessWidget {
  const AiSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<AiSettingsCubit>(
      create: (_) => sl<AiSettingsCubit>()..load(),
      child: const _AiSettingsView(),
    );
  }
}

class _AiSettingsView extends StatefulWidget {
  const _AiSettingsView();

  @override
  State<_AiSettingsView> createState() => _AiSettingsViewState();
}

class _AiSettingsViewState extends State<_AiSettingsView> {
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();

  /// Configured provider currently expanded for key editing (null = collapsed).
  String? _expandedId;
  bool _obscureKey = true;
  String? _keyLoadedFor;

  /// Locally-selected Compose provider before its routing is committed.
  String? _composeProviderId;

  /// Provider whose saved model has been restored into [_modelController], so we
  /// seed the field from persisted routing exactly once per load.
  String? _composeSeededFor;

  /// Catalog models for the in-focus Compose provider (BYO providers carry none,
  /// so the model becomes a free-text field).
  String? _modelsLoadedFor;
  bool _modelsLoading = false;
  List<AiModel> _models = const [];

  /// Live model ids fetched from a BYO provider's own `/models` endpoint
  /// (e.g. Ollama). Used to drive the same dropdown catalog providers get.
  List<String> _liveModelIds = const [];

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Compose feature
  // ---------------------------------------------------------------------------

  String? _composeProvider(AiSettingsState state) {
    return _composeProviderId ??
        state.routingFor(AiCapability.compose)?.providerId;
  }

  void _selectComposeProvider(String providerId, AiSettingsState state) {
    final route = state.routingFor(AiCapability.compose);
    setState(() {
      _composeProviderId = providerId;
      _modelController.text =
          route?.providerId == providerId ? route!.modelId : '';
    });
    for (final p in state.configured) {
      if (p.id == providerId) {
        _ensureModelsLoaded(p);
        break;
      }
    }
  }

  void _commitCompose(String providerId) {
    final model = _modelController.text.trim();
    if (model.isEmpty) {
      _snack('Enter a model id');
      return;
    }
    FocusScope.of(context).unfocus();
    context.read<AiSettingsCubit>().setRouting(
          capability: AiCapability.compose,
          providerId: providerId,
          modelId: model,
        );
    _snack('Compose will use $model');
  }

  /// Loads the model list for [provider]: the static catalog for catalog
  /// providers, or a live `/models` fetch for BYO/self-hosted endpoints (Ollama,
  /// LM Studio, …) so they get a real dropdown too.
  void _ensureModelsLoaded(AiProvider provider) {
    if (provider.id == _modelsLoadedFor) return;
    _modelsLoadedFor = provider.id;
    _models = const [];
    _liveModelIds = const [];
    _modelsLoading = true;

    final repo = sl<AiCatalogRepository>();
    final cubit = context.read<AiSettingsCubit>();

    // Derive models live for BYO endpoints and for Azure (whose real models are
    // the user's deployments, not the static catalog list); use the catalog for
    // ordinary catalog providers.
    final baseUrl = provider.apiBaseUrl;
    final hasUrl = baseUrl != null && baseUrl.isNotEmpty;
    // Detect Azure by protocol OR endpoint host, so a stale wireProtocol on the
    // persisted row still routes to the deployments listing.
    final isAzure = provider.wireProtocol == AiWireProtocol.azure ||
        (hasUrl && baseUrl.contains('azure.com'));
    final preferLive =
        hasUrl && (provider.source == AiProviderSource.user || isAzure);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      List<AiModel> catalogModels = const [];
      List<String> liveIds = const [];

      if (preferLive) {
        final key = await cubit.getApiKey(provider.id);
        final result = await repo.listLiveModels(
          baseUrl: baseUrl!,
          apiKey: key,
          azure: isAzure,
        );
        liveIds = result.getOrElse((_) => const []);
      } else if (provider.source == AiProviderSource.catalog) {
        final result = await repo.getModelsForProvider(provider.id);
        catalogModels = result.getOrElse((_) => const []);
      } else if (hasUrl) {
        final key = await cubit.getApiKey(provider.id);
        final result = await repo.listLiveModels(
          baseUrl: provider.apiBaseUrl!,
          apiKey: key,
        );
        liveIds = result.getOrElse((_) => const []);
      }

      if (!mounted || _modelsLoadedFor != provider.id) return;
      setState(() {
        _modelsLoading = false;
        _models = catalogModels;
        _liveModelIds = liveIds;
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Provider management
  // ---------------------------------------------------------------------------

  void _toggleExpanded(AiProvider provider) {
    final opening = _expandedId != provider.id;
    setState(() {
      _expandedId = opening ? provider.id : null;
      _obscureKey = true;
      if (opening) {
        _apiKeyController.text = '';
        _keyLoadedFor = null;
      }
    });
    if (opening) _ensureKeyLoaded(provider.id);
  }

  void _ensureKeyLoaded(String providerId) {
    if (providerId == _keyLoadedFor) return;
    _keyLoadedFor = providerId;
    final cubit = context.read<AiSettingsCubit>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final key = await cubit.getApiKey(providerId);
      if (!mounted || _keyLoadedFor != providerId) return;
      _apiKeyController.text = key ?? '';
    });
  }

  void _saveKey(AiProvider provider) {
    FocusScope.of(context).unfocus();
    context.read<AiSettingsCubit>().setApiKey(
          providerId: provider.id,
          apiKey: _apiKeyController.text.trim(),
        );
    _snack('API key saved');
  }

  Future<void> _removeProvider(AiProvider provider) async {
    await context.read<AiSettingsCubit>().removeProvider(provider.id);
    if (!mounted) return;
    setState(() => _expandedId = null);
    _snack('Removed ${provider.name}');
  }

  Future<void> _openAddProvider(AiSettingsState state) async {
    final cubit = context.read<AiSettingsCubit>();
    final catalog = state.providers
        .where((p) => p.source == AiProviderSource.catalog)
        .toList(growable: false);
    await showDialog<void>(
      context: context,
      builder: (_) => BlocProvider<AiSettingsCubit>.value(
        value: cubit,
        child: _AddProviderDialog(catalogProviders: catalog),
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<AiSettingsCubit, AiSettingsState>(
      builder: (context, state) {
        switch (state.status) {
          case AiSettingsStatus.loading:
            return const Center(child: CircularProgressIndicator());
          case AiSettingsStatus.error:
            return Center(
              child: Text(
                state.errorMessage ?? 'Failed to load AI providers',
                style: TextStyle(color: c.textMuted, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            );
          case AiSettingsStatus.loaded:
            return _buildLoaded(context, state);
        }
      },
    );
  }

  Widget _buildLoaded(BuildContext context, AiSettingsState state) {
    final c = context.colors;
    final configured = state.configured;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _Label('Providers')),
              if (configured.isNotEmpty)
                _AddButton(onTap: () => _openAddProvider(state)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'AI backends you have configured.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 12),
          if (configured.isEmpty)
            _EmptyConfigured(onAdd: () => _openAddProvider(state))
          else
            Column(
              children: [
                for (final provider in configured)
                  _ConfiguredTile(
                    provider: provider,
                    isExpanded: _expandedId == provider.id,
                    isComposeActive:
                        state.routingFor(AiCapability.compose)?.providerId ==
                            provider.id,
                    onToggle: () => _toggleExpanded(provider),
                    editor: _expandedId == provider.id
                        ? _ProviderKeyEditor(
                            provider: provider,
                            apiKeyController: _apiKeyController,
                            obscureKey: _obscureKey,
                            onToggleObscure: () =>
                                setState(() => _obscureKey = !_obscureKey),
                            onSaveKey: () => _saveKey(provider),
                            onRemove: () => _removeProvider(provider),
                          )
                        : null,
                  ),
              ],
            ),
          const SizedBox(height: 24),
          Divider(height: 1, color: c.separator),
          const SizedBox(height: 24),
          _Label('Features'),
          const SizedBox(height: 4),
          Text(
            'Assign a configured provider and model to each AI feature.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _buildFeatures(context, state, configured),
          const SizedBox(height: 24),
          Divider(height: 1, color: c.separator),
          const SizedBox(height: 24),
          _buildAgentCaps(context, state),
          const SizedBox(height: 24),
          Divider(height: 1, color: c.separator),
          const SizedBox(height: 24),
          _buildPrivacy(context, state),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Folder agent — configurable safety caps
  // ---------------------------------------------------------------------------

  /// Two user-configurable bounds for the folder-reading agent loop: how many
  /// tool steps it may take per turn (`agentMaxRounds`) and how many emails it
  /// may read in one step (`agentMaxToolCallsPerRound`). Both default to the old
  /// compile-time constants (5 / 8) and clamp to 1–20, so the loop can never run
  /// unbounded. (`RunFolderAgent` reads the same settings to enforce them.)
  Widget _buildAgentCaps(BuildContext context, AiSettingsState state) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('Folder agent'),
        const SizedBox(height: 4),
        Text(
          'Limits on how hard the agent works through a folder when answering.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        _AgentCapsSection(
          maxRounds: state.agentMaxRounds,
          maxToolCallsPerRound: state.agentMaxToolCallsPerRound,
          onMaxRoundsChanged: (v) =>
              context.read<AiSettingsCubit>().setAgentMaxRounds(v),
          onMaxToolCallsChanged: (v) =>
              context.read<AiSettingsCubit>().setAgentMaxToolCallsPerRound(v),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Privacy — cloud-bodies guard (default OFF / safe)
  // ---------------------------------------------------------------------------

  /// Toggle for `allowCloudForBodies`. When OFF (the conservative default) a
  /// compose routed to a **cloud** provider sends an instruction only — never
  /// the quoted original mail body. Local/self-hosted providers always receive
  /// the body, so the guard only narrows what leaves the machine to third
  /// parties. (`ComposeReply` reads the same flag to enforce this end-to-end.)
  Widget _buildPrivacy(BuildContext context, AiSettingsState state) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('Privacy'),
        const SizedBox(height: 4),
        Text(
          'Controls whether mail bodies may leave your machine for cloud '
          'providers.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        _CloudBodiesToggle(
          value: state.allowCloudForBodies,
          onChanged: (v) =>
              context.read<AiSettingsCubit>().setAllowCloudForBodies(v),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Features table (compact — scales to one row per feature)
  // ---------------------------------------------------------------------------

  Widget _buildFeatures(
    BuildContext context,
    AiSettingsState state,
    List<AiProvider> configured,
  ) {
    final c = context.colors;
    if (configured.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: c.separatorStrong),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Add a provider above to enable features.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // One compact row per feature. Future features slot in as new rows.
          _composeFeatureRow(context, state, configured),
        ],
      ),
    );
  }

  Widget _composeFeatureRow(
    BuildContext context,
    AiSettingsState state,
    List<AiProvider> configured,
  ) {
    final c = context.colors;
    final providerId = _composeProvider(state);
    AiProvider? selected;
    if (providerId != null) {
      // Registry view = authoritative wireProtocol + catalog models; config row
      // = durable user endpoint. Prefer the registry view but graft the config
      // row's base URL when the registry copy is missing one (e.g. a session
      // where the catalog snapshot predates the just-added endpoint).
      AiProvider? registryView;
      AiProvider? configRow;
      for (final p in state.providers) {
        if (p.id == providerId) {
          registryView = p;
          break;
        }
      }
      for (final p in configured) {
        if (p.id == providerId) {
          configRow = p;
          break;
        }
      }
      selected = registryView ?? configRow;
      final cfgUrl = configRow?.apiBaseUrl;
      if (selected != null &&
          cfgUrl != null &&
          cfgUrl.isNotEmpty &&
          (selected.apiBaseUrl == null || selected.apiBaseUrl!.isEmpty)) {
        selected = selected.copyWith(apiBaseUrl: cfgUrl);
      }
    }
    if (selected != null) _ensureModelsLoaded(selected);

    // Restore the persisted model into the field once on load. Routing lives in
    // drift, but the text controller starts empty, so without this the saved
    // model would render blank even though it still drives compose.
    final route = state.routingFor(AiCapability.compose);
    if (_composeProviderId == null &&
        route != null &&
        route.providerId == providerId &&
        _composeSeededFor != providerId) {
      _composeSeededFor = providerId;
      _modelController.text = route.modelId;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(
              'Compose',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: _compactDropdown<String>(
              context,
              value: selected?.id,
              hint: 'Provider',
              items: [
                for (final p in configured)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(p.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) {
                if (id != null) _selectComposeProvider(id, state);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(flex: 5, child: _compactModelCell(context, selected)),
        ],
      ),
    );
  }

  Widget _compactModelCell(BuildContext context, AiProvider? provider) {
    final c = context.colors;
    if (provider == null) {
      return _compactBox(context,
          child: Text('—', style: TextStyle(color: c.textMuted, fontSize: 12)));
    }
    if (_modelsLoading) {
      return _compactBox(context,
          child: Text('Loading…',
              style: TextStyle(color: c.textMuted, fontSize: 12)));
    }

    // Catalog providers → models.dev list; BYO providers → live `/models` list.
    final modelIds = _models.isNotEmpty
        ? [for (final m in _models) (id: m.id, label: m.name)]
        : [for (final id in _liveModelIds) (id: id, label: id)];

    if (modelIds.isEmpty) {
      // Endpoint unreachable / advertises nothing: fall back to manual entry.
      return SizedBox(
        height: 32,
        child: TextField(
          controller: _modelController,
          onSubmitted: (_) => _commitCompose(provider.id),
          style: TextStyle(color: c.textSecondary, fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'model id ⏎',
            hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.separatorStrong),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.accent),
            ),
          ),
        ),
      );
    }

    final value = modelIds.any((m) => m.id == _modelController.text)
        ? _modelController.text
        : null;
    return _compactDropdown<String>(
      context,
      value: value,
      hint: 'Model',
      items: [
        for (final m in modelIds)
          DropdownMenuItem(
            value: m.id,
            child: Text(m.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (id) {
        if (id != null) {
          setState(() => _modelController.text = id);
          _commitCompose(provider.id);
        }
      },
    );
  }

  Widget _compactBox(BuildContext context, {required Widget child}) {
    final c = context.colors;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: child,
    );
  }

  Widget _compactDropdown<T>(
    BuildContext context, {
    required T? value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final c = context.colors;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          hint: Text(hint, style: TextStyle(color: c.textMuted, fontSize: 12)),
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textSecondary, fontSize: 12),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Configured provider tile (key + remove)
// ---------------------------------------------------------------------------

class _ConfiguredTile extends StatelessWidget {
  const _ConfiguredTile({
    required this.provider,
    required this.isExpanded,
    required this.isComposeActive,
    required this.onToggle,
    required this.editor,
  });

  final AiProvider provider;
  final bool isExpanded;
  final bool isComposeActive;
  final VoidCallback onToggle;
  final Widget? editor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: isExpanded ? AppColors.accent : c.separatorStrong,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      provider.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (isComposeActive) ...[
                    const _ComposeBadge(),
                    const SizedBox(width: 8),
                  ],
                  _KindBadge(kind: provider.kind),
                  const SizedBox(width: 8),
                  Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: c.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (editor != null) ...[
            Divider(height: 1, color: c.separator),
            Padding(padding: const EdgeInsets.all(12), child: editor),
          ],
        ],
      ),
    );
  }
}

class _ComposeBadge extends StatelessWidget {
  const _ComposeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(28),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'Compose',
        style: TextStyle(
          color: AppColors.accent,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ProviderKeyEditor extends StatelessWidget {
  const _ProviderKeyEditor({
    required this.provider,
    required this.apiKeyController,
    required this.obscureKey,
    required this.onToggleObscure,
    required this.onSaveKey,
    required this.onRemove,
  });

  final AiProvider provider;
  final TextEditingController apiKeyController;
  final bool obscureKey;
  final VoidCallback onToggleObscure;
  final VoidCallback onSaveKey;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Catalog providers genuinely require a key; BYO/user endpoints may not
    // (local Ollama needs none), so the key is offered as optional there.
    final keyOptional = provider.source == AiProviderSource.user;
    final showKey = provider.requiresApiKey || provider.source == AiProviderSource.user;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (provider.apiBaseUrl != null) ...[
          Text(
            provider.apiBaseUrl!,
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 12),
        ],
        if (showKey)
          _ApiKeyField(
            controller: apiKeyController,
            obscure: obscureKey,
            optional: keyOptional,
            onToggleObscure: onToggleObscure,
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            TextButton(
              onPressed: onRemove,
              style: TextButton.styleFrom(foregroundColor: c.textMuted),
              child: const Text('Remove'),
            ),
            const Spacer(),
            if (showKey)
              ElevatedButton(
                onPressed: onSaveKey,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Save key'),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state + add affordances
// ---------------------------------------------------------------------------

class _EmptyConfigured extends StatelessWidget {
  const _EmptyConfigured({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Icon(Icons.auto_awesome_rounded, size: 22, color: c.textMuted),
          const SizedBox(height: 10),
          Text(
            'No providers configured yet',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Add a provider to draft and reply to mail with AI.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add provider'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('Add provider'),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add provider dialog (custom endpoint | from catalog)
// ---------------------------------------------------------------------------

enum _AddMode { custom, catalog }

class _AddProviderDialog extends StatefulWidget {
  const _AddProviderDialog({required this.catalogProviders});

  final List<AiProvider> catalogProviders;

  @override
  State<_AddProviderDialog> createState() => _AddProviderDialogState();
}

class _AddProviderDialogState extends State<_AddProviderDialog> {
  _AddMode _mode = _AddMode.custom;

  // Custom endpoint form.
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  AiWireProtocol _protocol = AiWireProtocol.openai;

  // Catalog form.
  final _searchController = TextEditingController();
  final _catalogKeyController = TextEditingController();
  final _catalogUrlController = TextEditingController();
  String _query = '';
  AiProvider? _picked;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _searchController.dispose();
    _catalogKeyController.dispose();
    _catalogUrlController.dispose();
    super.dispose();
  }

  void _addCustom() {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) return;

    final isLocal = _protocol == AiWireProtocol.ollama;
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final provider = AiProvider(
      id: 'byo_${slug}_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      npm: '',
      doc: '',
      // BYO keys are optional everywhere (set later on the tile), so we never
      // mark them required here.
      env: const [],
      apiBaseUrl: url,
      kind: isLocal ? AiProviderKind.local : AiProviderKind.selfHosted,
      wireProtocol: _protocol,
      source: AiProviderSource.user,
    );
    context.read<AiSettingsCubit>().addConfiguredProvider(provider);
    Navigator.of(context).pop();
  }

  Future<void> _addCatalog() async {
    final provider = _picked;
    if (provider == null) return;

    // Only some catalog providers need a user-supplied endpoint (Azure /
    // AI Foundry, gateways, unknown OpenAI-compatible hosts). First-party
    // providers (OpenAI/Anthropic/Google) carry a built-in default, so don't
    // prompt for those.
    final needsUrl = provider.defaultBaseUrl == null;
    final url = _catalogUrlController.text.trim();
    if (needsUrl && url.isEmpty) return;

    final toAdd = needsUrl
        ? AiProvider(
            id: provider.id,
            name: provider.name,
            npm: provider.npm,
            doc: provider.doc,
            env: provider.env,
            apiBaseUrl: url,
            kind: provider.kind,
            wireProtocol: provider.wireProtocol,
            source: provider.source,
          )
        : provider;

    final cubit = context.read<AiSettingsCubit>();
    await cubit.addConfiguredProvider(toAdd);
    final key = _catalogKeyController.text.trim();
    if (key.isNotEmpty) {
      await cubit.setApiKey(providerId: toAdd.id, apiKey: key);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add provider',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              _ModeToggle(
                mode: _mode,
                onChanged: (m) => setState(() => _mode = m),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: _mode == _AddMode.custom
                      ? _buildCustom(context)
                      : _buildCatalog(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCustom(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect a self-hosted or OpenAI-compatible endpoint (Ollama, '
          'LM Studio, vLLM, a proxy…). Pick Ollama for a local server with no '
          'API key.',
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        _FormRow(
          label: 'Name',
          child: _PlainField(controller: _nameController, hint: 'Ollama'),
        ),
        const SizedBox(height: 12),
        _FormRow(
          label: 'Base URL',
          child: _PlainField(
            controller: _urlController,
            hint: 'http://localhost:11434/v1',
            keyboardType: TextInputType.url,
          ),
        ),
        const SizedBox(height: 12),
        _FormRow(
          label: 'Protocol',
          child: _ProtocolDropdown(
            protocol: _protocol,
            onChanged: (p) => setState(() => _protocol = p),
          ),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton(
            onPressed: _addCustom,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }

  Widget _buildCatalog(BuildContext context) {
    final c = context.colors;
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.catalogProviders
        : widget.catalogProviders
            .where((p) =>
                p.name.toLowerCase().contains(query) ||
                p.id.toLowerCase().contains(query))
            .toList(growable: false);

    if (_picked != null) {
      final provider = _picked!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                splashRadius: 16,
                iconSize: 18,
                icon: Icon(Icons.arrow_back_rounded, color: c.textMuted),
                onPressed: () => setState(() => _picked = null),
              ),
              Expanded(
                child: Text(
                  provider.name,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _KindBadge(kind: provider.kind),
            ],
          ),
          const SizedBox(height: 12),
          if (provider.defaultBaseUrl == null) ...[
            _FormRow(
              label: 'Base URL',
              child: _PlainField(
                controller: _catalogUrlController,
                hint: 'https://<resource>.openai.azure.com/openai/v1',
                keyboardType: TextInputType.url,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'This provider has no fixed endpoint — paste your '
              'per-resource / project URL.',
              style: TextStyle(color: c.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 12),
          ],
          if (provider.requiresApiKey)
            _ApiKeyField(
              controller: _catalogKeyController,
              obscure: true,
              optional: false,
              onToggleObscure: () {},
            )
          else
            Text(
              'This provider needs no API key.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: _addCatalog,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Add'),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SearchField(
          controller: _searchController,
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 12),
        Container(
          constraints: const BoxConstraints(maxHeight: 280),
          decoration: BoxDecoration(
            border: Border.all(color: c.separatorStrong),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: filtered.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: Text(
                      'No providers match your search',
                      style: TextStyle(color: c.textMuted, fontSize: 13),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, thickness: 1, color: c.separator),
                  itemBuilder: (context, index) {
                    final provider = filtered[index];
                    return InkWell(
                      onTap: () => setState(() => _picked = provider),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                provider.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            if (provider.requiresApiKey) ...[
                              Text(
                                'needs key',
                                style: TextStyle(
                                  color: c.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            _KindBadge(kind: provider.kind),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});

  final _AddMode mode;
  final ValueChanged<_AddMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget tab(String label, _AddMode value) {
      final selected = mode == value;
      return Expanded(
        child: InkWell(
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ? AppColors.accent.withAlpha(28) : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.accent : c.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: Row(
        children: [
          tab('Custom endpoint', _AddMode.custom),
          const SizedBox(width: 3),
          tab('From catalog', _AddMode.catalog),
        ],
      ),
    );
  }
}

class _ProtocolDropdown extends StatelessWidget {
  const _ProtocolDropdown({required this.protocol, required this.onChanged});

  final AiWireProtocol protocol;
  final ValueChanged<AiWireProtocol> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.separatorStrong),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<AiWireProtocol>(
          value: protocol,
          isDense: true,
          isExpanded: true,
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textSecondary, fontSize: 13),
          items: AiWireProtocol.values.map((p) {
            return DropdownMenuItem<AiWireProtocol>(
              value: p,
              child: Text(_protocolLabel(p)),
            );
          }).toList(),
          onChanged: (p) {
            if (p != null) onChanged(p);
          },
        ),
      ),
    );
  }

  String _protocolLabel(AiWireProtocol protocol) {
    return switch (protocol) {
      AiWireProtocol.openai => 'OpenAI-compatible',
      AiWireProtocol.anthropic => 'Anthropic',
      AiWireProtocol.google => 'Google',
      AiWireProtocol.ollama => 'Ollama (local, no key)',
      AiWireProtocol.azure => 'Azure OpenAI (api-key)',
    };
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final AiProviderKind kind;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (kind) {
      AiProviderKind.cloud => ('Cloud', const Color(0xFF3B82F6)),
      AiProviderKind.local => ('Local', const Color(0xFF10B981)),
      AiProviderKind.selfHosted => ('Self-hosted', const Color(0xFFF59E0B)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ApiKeyField extends StatelessWidget {
  const _ApiKeyField({
    required this.controller,
    required this.obscure,
    required this.optional,
    required this.onToggleObscure,
  });

  final TextEditingController controller;
  final bool obscure;
  final bool optional;
  final VoidCallback onToggleObscure;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _FormRow(
      label: optional ? 'API key (optional)' : 'API key',
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: controller,
          obscureText: obscure,
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: optional
                ? 'Only if your endpoint needs one'
                : 'Paste your provider API key',
            hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.separatorStrong),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.accent),
            ),
            suffixIcon: IconButton(
              splashRadius: 16,
              iconSize: 18,
              icon: Icon(
                obscure
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: c.textMuted,
              ),
              onPressed: onToggleObscure,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bordered row hosting the cloud-bodies privacy switch plus an explicit
/// OFF/ON explanation, so the safe default and its effect are legible without
/// flipping it. Matches the `Switch` styling used in `settings_page.dart`.
class _CloudBodiesToggle extends StatelessWidget {
  const _CloudBodiesToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Send mail bodies to cloud providers',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value
                      ? 'On — the original email is quoted in the prompt sent '
                          'to cloud providers.'
                      : 'Off (recommended) — cloud providers receive an '
                          'instruction only; the original email body stays on '
                          'your machine. Local and self-hosted providers always '
                          'get the body.',
                  style: TextStyle(color: c.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.accent,
          ),
        ],
      ),
    );
  }
}

/// Bordered container holding the two folder-agent caps, styled like
/// [_CloudBodiesToggle]. Each cap is a [_AgentCapRow]: a label + helper, an
/// editable number field, and a slider, all bound to the same clamped value.
class _AgentCapsSection extends StatelessWidget {
  const _AgentCapsSection({
    required this.maxRounds,
    required this.maxToolCallsPerRound,
    required this.onMaxRoundsChanged,
    required this.onMaxToolCallsChanged,
  });

  final int maxRounds;
  final int maxToolCallsPerRound;
  final ValueChanged<int> onMaxRoundsChanged;
  final ValueChanged<int> onMaxToolCallsChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AgentCapRow(
            label: 'Max steps per turn',
            helper: 'How many tool steps the agent takes per turn.',
            value: maxRounds,
            onChanged: onMaxRoundsChanged,
          ),
          const SizedBox(height: 16),
          _AgentCapRow(
            label: 'Max tool calls per step',
            helper: 'How many tools it can call in a single step.',
            value: maxToolCallsPerRound,
            onChanged: onMaxToolCallsChanged,
          ),
        ],
      ),
    );
  }
}

/// One folder-agent cap: a [_Label] + helper, an editable digits-only number
/// field, and a [Slider]. Both controls drive the same value via [onChanged]
/// (clamped to [_min]–[_max]); the field and slider stay in sync with [value]
/// from cubit state. Empty/out-of-range typed input snaps to the clamped value.
class _AgentCapRow extends StatefulWidget {
  const _AgentCapRow({
    required this.label,
    required this.helper,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String helper;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_AgentCapRow> createState() => _AgentCapRowState();
}

class _AgentCapRowState extends State<_AgentCapRow> {
  static const int _min = 1;
  static const int _max = 20;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.value.toString();
    // Commit on blur so a typed value persists even without pressing enter.
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_AgentCapRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reflect external value changes (e.g. the slider) into the field. We
    // reconcile even while focused so a newer slider value isn't later
    // overwritten by a stale draft on blur — only rewrite when the new value
    // differs from what the field currently parses to, so we don't clobber an
    // in-progress edit that already matches.
    if (widget.value != oldWidget.value &&
        int.tryParse(_controller.text.trim()) != widget.value) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  int _clamp(int v) => v < _min ? _min : (v > _max ? _max : v);

  /// Parse + clamp the typed text, snap the field back to the clamped string,
  /// and only notify when the value actually changed.
  void _commit() {
    final parsed = int.tryParse(_controller.text.trim());
    final clamped = _clamp(parsed ?? widget.value);
    final text = clamped.toString();
    if (_controller.text != text) _controller.text = text;
    if (clamped != widget.value) widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Label(widget.label),
                  const SizedBox(height: 2),
                  Text(
                    widget.helper,
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              height: 32,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                onSubmitted: (_) => _commit(),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.separatorStrong),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: _clamp(widget.value).toDouble(),
          min: _min.toDouble(),
          max: _max.toDouble(),
          divisions: _max - _min,
          activeColor: AppColors.accent,
          label: _clamp(widget.value).toString(),
          onChanged: (v) {
            final next = _clamp(v.round());
            if (next != widget.value) widget.onChanged(next);
          },
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      text,
      style: TextStyle(
        color: c.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: TextStyle(color: c.textSecondary, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search providers',
          hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: c.textMuted),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: c.separatorStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.accent),
          ),
        ),
      ),
    );
  }
}

class _FormRow extends StatelessWidget {
  const _FormRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: TextStyle(color: c.textMuted, fontSize: 13),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _PlainField extends StatelessWidget {
  const _PlainField({
    required this.controller,
    required this.hint,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: TextStyle(
          color: c.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: c.separatorStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.accent),
          ),
        ),
      ),
    );
  }
}
