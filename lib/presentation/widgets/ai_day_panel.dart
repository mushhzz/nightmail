import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/ai/ai_compose_state.dart';
import '../blocs/ai/ai_folder_cubit.dart';

class AiDayPanel extends StatefulWidget {
  const AiDayPanel({
    super.key,
    required this.onClose,
    this.contextProvider,
  });

  final VoidCallback onClose;

  /// Called just before generation to collect the context string to pass to the
  /// AI (e.g. a formatted excerpt of the current folder's emails). Returns null
  /// when no context is available.
  final String? Function()? contextProvider;

  @override
  State<AiDayPanel> createState() => _AiDayPanelState();
}

class _AiDayPanelState extends State<AiDayPanel> {
  final _chatController = ChatMessagesController();
  final _inputController = TextEditingController();

  static const _user = ChatUser(id: 'user', name: 'You');
  static const _ai = ChatUser(id: 'ai', name: 'AI Assistant');

  /// Whether a generation is in flight; drives the LoadingConfig + Stop button.
  bool _isLoading = false;

  /// `customProperties['id']` of the in-flight AI bubble (null when idle).
  String? _streamingId;

  /// The current AI placeholder message, updated in place as text streams in.
  ChatMessage? _aiMessage;

  @override
  void dispose() {
    _chatController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  /// Builds a user bubble, an empty streaming AI bubble, and kicks off the cubit.
  void _onSend(ChatMessage userMessage) {
    final instruction = userMessage.text.trim();
    if (instruction.isEmpty || _isLoading) return;

    // The widget does NOT auto-add the user's message — we add it ourselves so
    // the prompt is captured in the transcript (the cubit never stores it).
    _chatController.addMessage(userMessage);

    final emailContext = widget.contextProvider?.call();

    _streamingId = 'ai_${DateTime.now().millisecondsSinceEpoch}';
    _aiMessage = ChatMessage(
      text: '',
      user: _ai,
      createdAt: DateTime.now(),
      isMarkdown: true,
      customProperties: {'id': _streamingId},
    );
    _chatController.addStreamingMessage(_aiMessage!);

    setState(() => _isLoading = true);
    context.read<AiFolderCubit>().generate(instruction, context: emailContext);
  }

  /// Cancels an in-flight generation, finalizing the partial AI bubble.
  void _onCancelGenerating() {
    context.read<AiFolderCubit>().cancel(); // emits Idle (listener no-ops)
    _finalizeStream();
  }

  /// Clears the transcript and resets all generation state.
  void _clear() {
    context.read<AiFolderCubit>().cancel();
    _chatController.clearMessages();
    _streamingId = null;
    _aiMessage = null;
    if (_isLoading) setState(() => _isLoading = false);
  }

  /// Stops the streaming animation for the in-flight bubble and clears state.
  void _finalizeStream() {
    final id = _streamingId;
    if (id != null) _chatController.stopStreamingMessage(id);
    _streamingId = null;
    _aiMessage = null;
    if (_isLoading) setState(() => _isLoading = false);
  }

  /// Translates each sealed [AiComposeState] into controller calls. The kit
  /// owns rendering, so there is no `builder` — only this listener mutates the
  /// transcript.
  void _onState(BuildContext context, AiComposeState state) {
    switch (state) {
      case AiComposeIdle():
        // Produced only by cancel(); Stop/Clear handle their own UI
        // imperatively. No-op here to avoid wiping the transcript on cancel.
        break;

      case AiComposeStreaming(:final text):
        final msg = _aiMessage;
        if (msg != null) {
          // `text` is already the FULL accumulated string (the cubit owns the
          // StringBuffer), so pass it straight through. copyWith preserves
          // customProperties['id'], which updateMessage matches on.
          _aiMessage = msg.copyWith(text: text);
          _chatController.updateMessage(_aiMessage!);
        }

      case AiComposeDone(:final text):
        final msg = _aiMessage;
        if (msg != null) {
          _aiMessage = msg.copyWith(text: text);
          _chatController.updateMessage(_aiMessage!);
        }
        _finalizeStream();

      case AiComposeError(:final failure):
        final msg = _aiMessage;
        if (msg != null) {
          _aiMessage = msg.copyWith(text: '⚠️ ${failure.message}');
          _chatController.updateMessage(_aiMessage!);
        } else {
          _chatController.addMessage(ChatMessage(
            text: '⚠️ ${failure.message}',
            user: _ai,
            createdAt: DateTime.now(),
          ));
        }
        _finalizeStream();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfacePanel,
      child: Column(
        children: [
          _Header(onClose: widget.onClose, onClear: _clear),
          Divider(height: 1, color: c.separatorStrong),
          Expanded(
            child: BlocListener<AiFolderCubit, AiComposeState>(
              listener: _onState,
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
          title: 'Enter an instruction to draft with AI.',
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
            hintText: 'Describe what to write…',
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
  const _Header({required this.onClose, required this.onClear});

  final VoidCallback onClose;
  final VoidCallback onClear;

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
              icon: Icon(Icons.delete_sweep_outlined, size: 16, color: c.textMuted),
              tooltip: 'Clear conversation',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onClear,
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
