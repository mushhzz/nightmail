import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/ai/ai_folder_chat_state.dart';
import '../blocs/ai/ai_folder_cubit.dart';
import 'ai/tool_call_card.dart';

class AiDayPanel extends StatefulWidget {
  const AiDayPanel({
    super.key,
    required this.onClose,
    this.folderIdProvider,
    this.contextProvider,
  });

  final VoidCallback onClose;

  /// Called just before each turn to resolve the current folder's id, which the
  /// agent's tools default to. Returns null when no folder is selected.
  final String? Function()? folderIdProvider;

  /// Called just before each turn to collect the fallback context string (a
  /// formatted excerpt of the current folder's emails). Used only when the
  /// routed model lacks tool calling. Returns null when no context is available.
  final String? Function()? contextProvider;

  @override
  State<AiDayPanel> createState() => _AiDayPanelState();
}

class _AiDayPanelState extends State<AiDayPanel> {
  final _chatController = ChatMessagesController();
  final _inputController = TextEditingController();

  static const _user = ChatUser(id: 'user', name: 'You');
  static const _ai = ChatUser(id: 'ai', name: 'AI Assistant');

  /// Mirrors the [AiChatItem]s already pushed into the controller, keyed by id,
  /// so each new state reconciles items instead of rebuilding the transcript.
  final Map<String, ChatMessage> _byId = {};

  /// The last-rendered [AiToolItem] per id, so a status/output change re-renders
  /// the tool card (the kit's [ChatMessage] equality ignores `customBuilder`).
  final Map<String, AiToolItem> _toolById = {};

  /// Whether a turn is in flight; drives the LoadingConfig + Stop button.
  bool _isLoading = false;

  @override
  void dispose() {
    _chatController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  /// Hands the instruction to the cubit. The transcript (including the user
  /// bubble) is rendered from the emitted state in [_sync] — we do not touch
  /// the controller here.
  void _onSend(ChatMessage userMessage) {
    final instruction = userMessage.text.trim();
    if (instruction.isEmpty || _isLoading) return;

    context.read<AiFolderCubit>().send(
          instruction,
          currentFolderId: widget.folderIdProvider?.call(),
          fallbackEmailsContext: widget.contextProvider?.call(),
        );
  }

  /// Cancels an in-flight turn; the cubit settles the partial bubble and emits
  /// a non-streaming state, which [_sync] reflects.
  void _onCancelGenerating() {
    context.read<AiFolderCubit>().cancel();
  }

  /// Clears the conversation and starts a fresh chat.
  void _newChat() {
    context.read<AiFolderCubit>().reset();
  }

  /// Reconciles the chat controller with the emitted [AiFolderChatState]: the
  /// kit owns rendering, so this listener is the only place that mutates the
  /// transcript.
  void _sync(BuildContext context, AiFolderChatState state) {
    // New Chat / empty transcript.
    if (state.messages.isEmpty) {
      if (_byId.isNotEmpty) {
        _chatController.clearMessages();
        _byId.clear();
        _toolById.clear();
      }
      _setLoading(state.isStreaming);
      return;
    }

    // Add new items and update changed ones (a streaming assistant bubble whose
    // text grew, or a tool card transitioning running → complete/error).
    for (final item in state.messages) {
      switch (item) {
        case AiToolItem():
          _syncToolItem(item);
        case AiTextMessage():
          _syncTextMessage(item);
      }
    }

    // Stop the streaming animation on assistant bubbles once the turn settles.
    if (!state.isStreaming) {
      for (final m in state.messages) {
        if (m is AiTextMessage && !m.isUser) {
          _chatController.stopStreamingMessage(m.id);
        }
      }
    }

    // Surface a hard failure: append it to the trailing assistant bubble if one
    // exists for this turn, else add a dedicated error bubble.
    if (state.failure != null) {
      final errText = '⚠️ ${state.failure!.message}';
      AiTextMessage? lastAssistant;
      for (final m in state.messages) {
        if (m is AiTextMessage && !m.isUser) lastAssistant = m;
      }
      if (lastAssistant != null && _byId[lastAssistant.id] != null) {
        final existing = _byId[lastAssistant.id]!;
        final merged = existing.text.isEmpty
            ? errText
            : '${existing.text}\n\n$errText';
        final updated = existing.copyWith(text: merged);
        _byId[lastAssistant.id] = updated;
        _chatController.updateMessage(updated);
      } else {
        // Turn-stable id: keyed off the last message in this turn so repeated
        // re-emissions of the same failure dedupe via the containsKey guard,
        // even when controller-only inserts have changed _byId.length.
        final errId = 'err_${state.messages.last.id}';
        if (!_byId.containsKey(errId)) {
          final cm = ChatMessage(
            text: errText,
            user: _ai,
            createdAt: DateTime.now(),
            customProperties: {'id': errId},
          );
          _byId[errId] = cm;
          _chatController.addMessage(cm);
        }
      }
    }

    _setLoading(state.isStreaming);
  }

  /// Reconciles a single text bubble into the controller.
  void _syncTextMessage(AiTextMessage m) {
    final existing = _byId[m.id];
    if (existing == null) {
      // Don't render an empty in-flight assistant bubble: the cubit may drop
      // it (failure/cancel before any output). Add it on its first delta.
      if (!m.isUser && m.text.isEmpty) return;
      final cm = ChatMessage(
        text: m.text,
        user: m.isUser ? _user : _ai,
        createdAt: DateTime.now(),
        isMarkdown: !m.isUser,
        customProperties: {'id': m.id},
      );
      _byId[m.id] = cm;
      if (m.isUser) {
        _chatController.addMessage(cm);
      } else {
        _chatController.addStreamingMessage(cm);
      }
    } else if (existing.text != m.text) {
      final updated = existing.copyWith(text: m.text);
      _byId[m.id] = updated;
      _chatController.updateMessage(updated);
    }
  }

  /// Reconciles a single inline tool card into the controller. The card is a
  /// full-width custom-builder message (no bubble chrome); a status/output
  /// change rebuilds its [ToolCallCard] in place.
  void _syncToolItem(AiToolItem item) {
    final prev = _toolById[item.id];
    if (prev == item) return;
    _toolById[item.id] = item;

    final cm = (_byId[item.id] ??
            ChatMessage(
              text: '',
              user: _ai,
              createdAt: DateTime.now(),
              customProperties: {'id': item.id},
            ))
        .copyWith(customBuilder: (context, _) => ToolCallCard(item: item));
    _byId[item.id] = cm;

    if (prev == null) {
      _chatController.addMessage(cm);
    } else {
      _chatController.updateMessage(cm);
    }
  }

  void _setLoading(bool loading) {
    if (_isLoading != loading) setState(() => _isLoading = loading);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfacePanel,
      child: Column(
        children: [
          _Header(onClose: widget.onClose, onNewChat: _newChat),
          Divider(height: 1, color: c.separatorStrong),
          Expanded(
            child: BlocListener<AiFolderCubit, AiFolderChatState>(
              listener: _sync,
              child: _buildChat(c),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChat(AppColors c) {
    final base = Theme.of(context);
    final onAccent =
        AppColors.accent.computeLuminance() > 0.5 ? Colors.black : Colors.white;

    // The kit reads colorScheme.surface / surfaceContainer* for its own
    // backgrounds; align them with the panel palette so the chat surface
    // matches the surrounding dark UI.
    final theme = base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.accent,
        surface: c.surfacePanel,
        onSurface: c.textPrimary,
        surfaceContainerLowest: c.surfacePanel,
        surfaceContainerLow: c.surfacePanel,
        surfaceContainer: c.surfacePanel,
        surfaceContainerHigh: c.surfaceBase,
        surfaceContainerHighest: c.surfaceBase,
      ),
    );

    return Theme(
      data: theme,
      child: AiChatWidget(
        currentUser: _user,
        aiUser: _ai,
        controller: _chatController,
        onSendMessage: _onSend,

        // Streaming animation — both flags required for word-by-word.
        enableMarkdownStreaming: true,
        streamingWordByWord: true,
        streamingDuration: const Duration(milliseconds: 25),

        // Stop button: appears in the input while generating.
        loadingConfig: LoadingConfig(isLoading: _isLoading),
        onCancelGenerating: _onCancelGenerating,

        welcomeMessageConfig: WelcomeMessageConfig(
          centerVertically: true,
          title: 'Ask about this folder — I can read and search your mail.',
          titleStyle: TextStyle(
            color: c.textMuted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          containerDecoration: const BoxDecoration(),
        ),

        messageOptions: MessageOptions(
          showTime: false,
          showCopyButton: true,
          aiTextColor: c.textPrimary,
          userTextColor: onAccent,
          textStyle: TextStyle(color: c.textPrimary, fontSize: 13, height: 1.5),
          bubbleStyle: BubbleStyle(
            aiBubbleColor: c.surfaceBase,
            userBubbleColor: AppColors.accent,
            aiNameColor: c.textMuted,
            userNameColor: onAccent,
            copyIconColor: c.textMuted,
            enableShadow: false,
            userBubbleTopLeftRadius: 10,
            userBubbleTopRightRadius: 10,
            aiBubbleTopLeftRadius: 10,
            aiBubbleTopRightRadius: 10,
            bottomLeftRadius: 10,
            bottomRightRadius: 10,
          ),
        ),

        inputOptions: InputOptions(
          textController: _inputController,
          textStyle: TextStyle(color: c.textPrimary, fontSize: 13),
          sendButtonColor: AppColors.accent,
          decoration: InputDecoration(
            hintText: 'Ask about your mail…',
            hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            isDense: true,
          ),
          containerDecoration: BoxDecoration(
            color: c.surfacePanel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.border),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose, required this.onNewChat});

  final VoidCallback onClose;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 16, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'AI Assistant',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.add_comment_outlined, size: 16, color: c.textMuted),
              tooltip: 'New Chat',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onNewChat,
            ),
            IconButton(
              icon: Icon(Icons.close, size: 16, color: c.textMuted),
              tooltip: 'Close',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
