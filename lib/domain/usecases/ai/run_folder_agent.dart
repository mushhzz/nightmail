import 'dart:convert';

import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../entities/ai/ai_capability.dart';
import '../../entities/ai/ai_chunk.dart';
import '../../entities/ai/ai_message.dart';
import '../../entities/ai/ai_provider.dart';
import '../../entities/ai/ai_request.dart';
import '../../entities/ai/ai_tool_call.dart';
import '../../entities/ai/ai_tool_definition.dart';
import '../../entities/ai/ai_tool_result.dart';
import '../../repositories/ai/ai_catalog_repository.dart';
import '../../repositories/ai/ai_inference_repository.dart';
import '../../repositories/ai/ai_settings_repository.dart';
import '../get_email.dart';
import '../get_emails.dart';
import '../get_mail_folders.dart';
import '../search_emails.dart';
import 'agent/agent_tool.dart';
import 'agent/email_agent_tools.dart';

/// Runs a tool-calling agent scoped to the folder panel, streaming the
/// response token-by-token.
///
/// Replaces the single-shot [QueryEmailFolder] for tool-capable models: instead
/// of pre-stuffing folder emails into the prompt, the model is given read-only
/// tools ([ListEmailsTool], [GetEmailTool], [SearchEmailsTool],
/// [ListFoldersTool]) to read/search mail on demand. Multi-turn threading is
/// the caller's responsibility — it passes the accumulated [history] each turn.
///
/// Routing reuses [AiCapability.compose]. When the routed model does not
/// support tool calling (`AiModel.toolCall == false`), this falls back to the
/// pre-stuffed-context Q&A (still threaded), so the panel always works.
///
/// ## Privacy guard (§4)
///
/// The cloud-bodies guard moves to the tool boundary: the use case computes the
/// effective `includeBodies` policy once (cloud provider + no opt-in →
/// withhold) and passes it to [GetEmailTool], which then returns metadata +
/// preview only. `list_emails` / `search_emails` expose only previews, so the
/// guarantee — full bodies never leave to a cloud provider without explicit
/// opt-in — is preserved. The fallback path gates [fallbackEmailsContext] with
/// the same flag.
///
/// Returns a `Stream<Either<Failure, AiChunk>>`: text deltas pass through
/// unchanged, transient tool-activity chunks are emitted with
/// [toolActivityFinishReason], and a hard provider failure surfaces as a single
/// terminal `Left`.
class RunFolderAgent {
  const RunFolderAgent({
    required this.settingsRepository,
    required this.inferenceRepository,
    required this.catalogRepository,
    required this.getEmails,
    required this.getEmail,
    required this.searchEmails,
    required this.getMailFolders,
  });

  final AiSettingsRepository settingsRepository;
  final AiInferenceRepository inferenceRepository;
  final AiCatalogRepository catalogRepository;
  final GetEmails getEmails;
  final GetEmail getEmail;
  final SearchEmails searchEmails;
  final GetMailFolders getMailFolders;

  /// Default maximum streamed rounds per turn (one round = one model stream
  /// that may end in tool calls). Bounds runaway tool loops. Used when the
  /// configured [AiSettingsRepository.getAgentMaxRounds] value is unavailable.
  static const int defaultMaxRounds = 5;

  /// Default maximum tool calls executed per round. Calls beyond this are
  /// answered with an error result (so every assistant tool call still has a
  /// matching `tool`-role reply, as wire protocols require). Used when the
  /// configured [AiSettingsRepository.getAgentMaxToolCallsPerRound] value is
  /// unavailable.
  static const int defaultMaxToolCallsPerRound = 8;

  /// Sentinel `finishReason` on a transient tool-activity chunk. The chunk's
  /// `delta` carries a human-readable label (e.g. `Searching for "..."`) and
  /// its `toolCalls` the originating call. The presentation layer surfaces this
  /// as a transient activity label rather than appending it to the answer text.
  static const String toolActivityFinishReason = 'tool_activity';

  /// Sentinel `finishReason` on a tool-result chunk, emitted after a tool call
  /// has executed. The chunk's [AiChunk.toolResult] carries the originating
  /// call id, the serialized output, and whether the outcome was an error. The
  /// presentation layer matches it to the running tool card by `callId`.
  static const String toolResultFinishReason = 'tool_result';

  /// Agent system prompt — a tool-using variant of the folder-assistant prompt.
  static const String _agentSystemPrompt =
      'You are an email assistant embedded in a desktop mail client, operating '
      'as a tool-using agent. You have read-only tools to list, search, and '
      'read the user\'s mail and folders. Use them to gather the specific '
      'information you need before answering — do not guess or fabricate. '
      'Prefer list_emails or search_emails to find relevant messages, then '
      'get_email to read details. The user is currently viewing a specific '
      'folder; tools default to that folder when no folder is specified. Cite '
      'specific senders, subjects, and dates. Be concise and specific.';

  /// Fallback system prompt (no tools) — mirrors [QueryEmailFolder].
  static const String _fallbackSystemPrompt =
      'You are an email assistant embedded in a desktop mail client. '
      'Help the user understand, manage, and triage their emails. '
      'When given a list of emails from a folder, use that context to answer '
      'questions, provide summaries, identify urgent items, and help the user '
      'prioritise their inbox. Be concise and specific.';

  /// Runs one agent turn.
  ///
  /// [history] is the prior conversation (user/assistant/tool turns) excluding
  /// the system prompt; [userInstruction] is the new user turn. [currentFolderId]
  /// is the panel's current folder (tool default). [fallbackEmailsContext] is
  /// the pre-formatted folder excerpt used only on the no-tools fallback path.
  Stream<Either<Failure, AiChunk>> call({
    required List<AiMessage> history,
    required String userInstruction,
    String? currentFolderId,
    String? fallbackEmailsContext,
  }) async* {
    // Resolve which provider + model handles the folder agent.
    final routingResult =
        await settingsRepository.getRouting(AiCapability.compose);

    if (routingResult.isLeft()) {
      yield Left(routingResult.getLeft().toNullable()!);
      return;
    }

    final routing = routingResult.getRight().toNullable();
    if (routing == null) {
      yield const Left(
        NoProviderConfigured(message: 'No AI provider is configured.'),
      );
      return;
    }

    // Privacy guard, computed once (§4): treat an unresolved provider as cloud.
    final provider = (await catalogRepository.getProvider(routing.providerId))
        .fold((_) => null, (value) => value);
    final allowCloud = (await settingsRepository.getAllowCloudForBodies())
        .getOrElse((_) => false);
    final isCloud = provider == null || provider.kind == AiProviderKind.cloud;
    final includeBodies = !isCloud || allowCloud;

    // Configurable safety bounds (§3): fall back to the compile-time defaults
    // if the setting can't be read.
    final maxRounds = (await settingsRepository.getAgentMaxRounds())
        .getOrElse((_) => defaultMaxRounds);
    final maxToolCallsPerRound =
        (await settingsRepository.getAgentMaxToolCallsPerRound())
            .getOrElse((_) => defaultMaxToolCallsPerRound);

    // Decide whether to run the tool-calling agent loop or the no-tools
    // fallback. Tool capability is only published by the models.dev catalog,
    // which backs cloud providers. For a BYO/local endpoint (Ollama, LM Studio,
    // vLLM…) models are discovered live and carry no capability metadata, so
    // their catalog `toolCall` flag defaults to false — that means "unknown",
    // not "unsupported". Trust the catalog flag for cloud providers; for
    // non-cloud providers optimistically attempt tools (the user's own endpoint
    // typically supports them, and one that does not simply ignores the `tools`
    // parameter). An unresolved provider is treated as cloud → conservative.
    final model = (await catalogRepository.getModel(
      providerId: routing.providerId,
      modelId: routing.modelId,
    ))
        .fold((_) => null, (value) => value);
    final toolCapable = isCloud ? (model?.toolCall ?? false) : true;

    // --- Fallback: no-tools, pre-stuffed context (mirrors QueryEmailFolder) --
    if (!toolCapable) {
      final request = AiRequest(
        providerId: routing.providerId,
        modelId: routing.modelId,
        stream: true,
        messages: [
          const AiMessage(role: AiRole.system, content: _fallbackSystemPrompt),
          ...history,
          AiMessage(
            role: AiRole.user,
            content: _buildFallbackPrompt(
              instruction: userInstruction,
              emailsContext: includeBodies ? fallbackEmailsContext : null,
            ),
          ),
        ],
      );
      yield* inferenceRepository.stream(request);
      return;
    }

    // --- Agent loop --------------------------------------------------------
    final tools = <AgentTool>[
      ListEmailsTool(getEmails),
      GetEmailTool(getEmail, includeBodies: includeBodies),
      SearchEmailsTool(searchEmails),
      ListFoldersTool(getMailFolders),
    ];
    final toolsByName = {for (final t in tools) t.name: t};
    final toolDefs = tools
        .map((t) => AiToolDefinition(
              name: t.name,
              description: t.description,
              parametersSchema: t.parametersSchema,
            ))
        .toList();

    final messages = <AiMessage>[
      const AiMessage(role: AiRole.system, content: _agentSystemPrompt),
      ...history,
      AiMessage(role: AiRole.user, content: userInstruction),
    ];

    for (var round = 0; round < maxRounds; round++) {
      final request = AiRequest(
        providerId: routing.providerId,
        modelId: routing.modelId,
        stream: true,
        messages: List.unmodifiable(messages),
        tools: toolDefs,
      );

      List<AiToolCall>? roundToolCalls;

      await for (final event in inferenceRepository.stream(request)) {
        final failure = event.getLeft().toNullable();
        if (failure != null) {
          // Hard provider failure aborts the turn.
          yield Left(failure);
          return;
        }
        final chunk = event.getRight().toNullable()!;
        if (chunk.toolCalls != null && chunk.toolCalls!.isNotEmpty) {
          // Capture the round-terminal tool calls; do not forward the
          // round-terminal chunk (the turn is not over yet).
          roundToolCalls = chunk.toolCalls;
        } else {
          // Pass text deltas (and a genuine no-tools terminal chunk) through.
          yield event;
        }
      }

      // No tool calls → the final answer has already been streamed.
      if (roundToolCalls == null || roundToolCalls.isEmpty) return;

      // Record the assistant turn that requested the tools.
      messages.add(
        AiMessage(
          role: AiRole.assistant,
          content: '',
          toolCalls: roundToolCalls,
        ),
      );

      // Execute each call, emit a transient activity chunk, and append the
      // result as a `tool`-role turn. Every call gets a matching reply.
      for (var i = 0; i < roundToolCalls.length; i++) {
        final call = roundToolCalls[i];

        yield Right(
          AiChunk(
            delta: _activityLabel(call),
            finishReason: toolActivityFinishReason,
            toolCalls: [call],
          ),
        );

        final String resultString;
        final bool isError;
        if (i >= maxToolCallsPerRound) {
          resultString = jsonEncode({
            'error': 'Tool call skipped: per-round tool-call limit reached.',
          });
          isError = true;
        } else {
          final tool = toolsByName[call.name];
          if (tool == null) {
            resultString = jsonEncode({'error': "Unknown tool '${call.name}'."});
            isError = true;
          } else {
            // Serialize a tool Left into the result so the model can recover.
            final outcome =
                await tool.invoke(call.arguments, currentFolderId: currentFolderId);
            isError = outcome.isLeft();
            resultString = outcome.fold(
              (failure) => jsonEncode({'error': failure.message}),
              (value) => value,
            );
          }
        }

        messages.add(
          AiMessage(
            role: AiRole.tool,
            content: resultString,
            toolCallId: call.id,
            name: call.name,
          ),
        );

        // Finished event: carries the structured result so the UI can update
        // the running tool card to complete/error with its output.
        yield Right(
          AiChunk(
            delta: '',
            finishReason: toolResultFinishReason,
            toolResult: AiToolResult(
              callId: call.id,
              output: resultString,
              isError: isError,
            ),
          ),
        );
      }
      // Loop to let the model read the results and either answer or call more.
    }

    // Max rounds exceeded without a final answer.
    yield const Right(
      AiChunk(
        delta: '\n\n_(Reached the maximum number of tool steps for this '
            'turn. Ask a follow-up to continue.)_',
        done: true,
        finishReason: 'max_rounds',
      ),
    );
  }

  /// Combines the user's [instruction] with any [emailsContext] into a single
  /// user-turn prompt (no-tools fallback). Mirrors [QueryEmailFolder].
  String _buildFallbackPrompt({
    required String instruction,
    String? emailsContext,
  }) {
    final ctx = emailsContext?.trim();
    if (ctx == null || ctx.isEmpty) return instruction.trim();
    return 'Emails in folder:\n$ctx\n\nInstruction:\n${instruction.trim()}';
  }

  /// A short, human-readable label for a tool call, surfaced transiently in the
  /// UI while the tool runs.
  String _activityLabel(AiToolCall call) {
    switch (call.name) {
      case 'list_emails':
        return 'Listing emails…';
      case 'search_emails':
        final query = call.arguments['query'];
        return query is String && query.isNotEmpty
            ? 'Searching for "$query"…'
            : 'Searching emails…';
      case 'get_email':
        return 'Reading an email…';
      case 'list_folders':
        return 'Listing folders…';
      default:
        return 'Using ${call.name}…';
    }
  }
}
