import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/ai/ai_chunk.dart';
import '../../../domain/entities/ai/ai_message.dart';
import '../../../domain/usecases/ai/run_folder_agent.dart';
import 'ai_folder_chat_state.dart';

/// Drives the multi-turn, tool-calling folder agent chat.
///
/// Replaces the single-shot folder Q&A: each [send] streams one agent turn via
/// [RunFolderAgent], which may call read-only tools to read/search the user's
/// mail before answering. The cubit owns the running conversation [_history]
/// (user + assistant text turns) and feeds it back to the agent each turn, so
/// follow-up questions have memory.
///
/// The displayable transcript [_display] is heterogeneous and persistent — it
/// interleaves text bubbles with inline [AiToolItem] cards — so it is no longer
/// 1:1 with [_history]. Each display item is tagged with the user-turn index it
/// belongs to ([_turnOf]); when [_trimHistory] drops the oldest text turns, any
/// display items belonging to those turns are dropped too. Tool items are
/// display-only and never re-sent: [_history] holds only user/assistant text
/// turns, and the agent re-derives any tool context each turn from that thread.
/// The system prompt is owned by [RunFolderAgent] (it picks the agent vs.
/// fallback variant), so it is deliberately absent from [_history].
class AiFolderCubit extends Cubit<AiFolderChatState> {
  AiFolderCubit({required RunFolderAgent runFolderAgent})
      : _runFolderAgent = runFolderAgent,
        super(const AiFolderChatState());

  final RunFolderAgent _runFolderAgent;

  /// Threaded conversation passed back to the agent each turn (user + assistant
  /// text turns only). Capped to the most recent [_maxHistory] turns.
  final List<AiMessage> _history = [];

  /// The user-turn index each [_history] entry belongs to, aligned with
  /// [_history]. Used to map retained text turns back to display items on trim.
  final List<int> _historyTurns = [];

  /// Displayable transcript: text bubbles interleaved with tool cards.
  final List<AiChatItem> _display = [];

  /// The user-turn index each display item belongs to, keyed by display id.
  final Map<String, int> _turnOf = {};

  StreamSubscription<Either<Failure, AiChunk>>? _subscription;

  /// Accumulates the CURRENT text segment's streamed text. A turn may contain
  /// several segments when the model narrates between tool calls (text → tool →
  /// text); each segment is its own [AiTextMessage] bubble, so this is cleared
  /// whenever a tool card closes the running segment.
  final StringBuffer _buffer = StringBuffer();

  /// Accumulates ALL assistant text across the whole turn (every segment),
  /// joined for the single assistant entry persisted to [_history]. Display
  /// bubbles are per-segment; the model's memory is the whole turn.
  final StringBuffer _turnText = StringBuffer();

  /// Display id of the in-flight assistant bubble, or null when no assistant
  /// text has streamed yet this turn (the bubble is created lazily).
  String? _streamingId;

  /// Monotonic id source for display items.
  int _seq = 0;

  /// Monotonic user-turn counter (one per [send]).
  int _turn = 0;

  /// The turn index of the in-flight turn — tags tool cards and the assistant
  /// bubble created while it streams.
  int _currentTurn = 0;

  /// Max conversation turns retained (combined user + assistant text messages).
  static const int _maxHistory = 12;

  /// Streams one agent turn for [userInstruction].
  ///
  /// [currentFolderId] is the panel's current folder (the tool default);
  /// [fallbackEmailsContext] is the pre-formatted folder excerpt used only when
  /// the routed model lacks tool calling.
  void send(
    String userInstruction, {
    String? currentFolderId,
    String? fallbackEmailsContext,
  }) {
    final instruction = userInstruction.trim();
    if (instruction.isEmpty || _subscription != null) return;

    _buffer.clear();
    _turnText.clear();
    _streamingId = null;

    // The history sent to the agent EXCLUDES the new user turn — the agent
    // appends it itself.
    final history = List<AiMessage>.unmodifiable(_history);

    final thisTurn = _turn++;
    _currentTurn = thisTurn;

    // Record the user turn (history + display). The assistant bubble is NOT
    // created up front — it is added lazily on the first text delta, so tool
    // cards render above the eventual answer.
    _history.add(AiMessage(role: AiRole.user, content: instruction));
    _historyTurns.add(thisTurn);

    final userId = 'u${_seq++}';
    _display.add(AiTextMessage(id: userId, isUser: true, text: instruction));
    _turnOf[userId] = thisTurn;

    _emit(isStreaming: true, clearFailure: true);

    _subscription = _runFolderAgent
        .call(
          history: history,
          userInstruction: instruction,
          currentFolderId: currentFolderId,
          fallbackEmailsContext: fallbackEmailsContext,
        )
        .listen(
          (result) => result.fold(_onFailure, _onChunk),
          onError: (Object error) =>
              _onFailure(ProviderUnreachable(message: error.toString())),
          onDone: _onStreamDone,
        );
  }

  /// Clears the conversation and returns to the empty "New Chat" state.
  void reset() {
    _subscription?.cancel();
    _subscription = null;
    _buffer.clear();
    _history.clear();
    _historyTurns.clear();
    _display.clear();
    _turnOf.clear();
    _streamingId = null;
    _turn = 0;
    _currentTurn = 0;
    if (!isClosed) emit(const AiFolderChatState());
  }

  /// Cancels an in-flight turn, keeping whatever text and tool cards streamed
  /// so far.
  void cancel() {
    if (_subscription == null) return;
    _finalizeTurn();
  }

  @override
  Future<void> close() {
    _subscription?.cancel();
    return super.close();
  }

  // --- Stream handlers -------------------------------------------------------

  void _onChunk(AiChunk chunk) {
    if (isClosed) return;

    // A tool call started — append a running tool card to the transcript.
    if (chunk.finishReason == RunFolderAgent.toolActivityFinishReason) {
      final calls = chunk.toolCalls;
      if (calls != null && calls.isNotEmpty) {
        // RunFolderAgent emits one started chunk per call, but iterate all of
        // [toolCalls] so a batched chunk still renders a card per call.
        for (final call in calls) {
          final item = AiToolItem(
            id: 't${_seq++}',
            callId: call.id,
            name: call.name,
            args: call.arguments,
            status: AiToolStatus.running,
          );
          _display.add(item);
          _turnOf[item.id] = _currentTurn;
        }

        // Close the current text segment so any answer text that streams AFTER
        // this tool starts a fresh bubble BELOW the card, preserving the
        // user → text → tool → text order. The bubble already in [_display]
        // keeps the preamble text it has accrued.
        if (_streamingId != null) {
          _streamingId = null;
          _buffer.clear();
          if (_turnText.isNotEmpty) _turnText.write('\n\n');
        }
        _emit();
      }
      return;
    }

    // A tool call finished — update its running card to complete/error.
    if (chunk.finishReason == RunFolderAgent.toolResultFinishReason) {
      final result = chunk.toolResult;
      if (result != null) {
        // Scope the match to the current turn so a callId reused from an older
        // turn can't update the wrong card.
        final i = _display.indexWhere(
          (m) =>
              m is AiToolItem &&
              m.callId == result.callId &&
              _turnOf[m.id] == _currentTurn,
        );
        if (i != -1) {
          final existing = _display[i] as AiToolItem;
          _display[i] = existing.copyWith(
            status:
                result.isError ? AiToolStatus.error : AiToolStatus.complete,
            output: result.output,
          );
          _emit();
        }
      }
      return;
    }

    // Real answer text. Create the in-flight assistant bubble lazily on the
    // first non-empty content so it sits below any tool cards.
    _buffer.write(chunk.delta);
    _turnText.write(chunk.delta);
    if (_streamingId == null && _buffer.isNotEmpty) {
      _streamingId = 'a${_seq++}';
      _display.add(AiTextMessage(id: _streamingId!, isUser: false, text: ''));
      _turnOf[_streamingId!] = _currentTurn;
    }
    _setStreamingText(_buffer.toString());

    if (chunk.done) {
      _finalizeTurn();
    } else {
      _emit();
    }
  }

  void _onFailure(Failure failure) {
    _subscription?.cancel();
    _subscription = null;

    // Drop the in-flight assistant bubble only if it never produced text; the
    // panel renders the failure separately. Tool cards persist.
    final id = _streamingId;
    if (id != null) {
      final i = _display.indexWhere((m) => m.id == id);
      if (i != -1) {
        final m = _display[i];
        if (m is AiTextMessage && m.text.isEmpty) {
          _display.removeAt(i);
          _turnOf.remove(id);
        }
      }
    }
    _streamingId = null;
    _buffer.clear();
    // A failure ends the turn without tool results; mark any still-running tool
    // card terminal so it stops spinning, and trim history (mirroring
    // _finalizeTurn) so repeated failures can't grow _history past the cap.
    _settleRunningToolCards();
    _trimHistory();

    if (!isClosed) _emit(isStreaming: false, failure: failure);
  }

  void _onStreamDone() {
    // The stream closed without a terminal `done` chunk (e.g. the fallback
    // path). Finalize whatever streamed so far.
    if (_subscription != null) _finalizeTurn();
    _subscription = null;
  }

  /// Settles the in-flight turn: persists the assistant text into [_history],
  /// trims to the cap, and emits the idle (non-streaming) state.
  void _finalizeTurn() {
    _subscription?.cancel();
    _subscription = null;

    // The in-flight segment bubble already shows its own text (set as each
    // delta arrived); do not overwrite it. History gets the whole turn's text.
    final turnText = _turnText.toString().trim();

    if (turnText.isNotEmpty) {
      _history.add(AiMessage(role: AiRole.assistant, content: turnText));
      _historyTurns.add(_currentTurn);
    }
    if (_buffer.isEmpty) {
      // Drop a trailing empty in-flight bubble (e.g. cancelled before this
      // segment produced any text).
      final id = _streamingId;
      if (id != null) {
        _display.removeWhere((m) => m.id == id);
        _turnOf.remove(id);
      }
    }

    _streamingId = null;
    _buffer.clear();
    _turnText.clear();
    // Any tool card still spinning when the turn settles never got a result;
    // mark it terminal so the UI stops showing a spinner.
    _settleRunningToolCards();
    _trimHistory();

    if (!isClosed) _emit(isStreaming: false);
  }

  // --- Internals -------------------------------------------------------------

  /// Marks any still-[AiToolStatus.running] tool card of the current turn as
  /// [AiToolStatus.error]. Called when a turn ends (cancel/failure/finalize)
  /// without a tool result arriving, so the UI stops spinning forever.
  void _settleRunningToolCards() {
    for (var i = 0; i < _display.length; i++) {
      final m = _display[i];
      if (m is AiToolItem &&
          m.status == AiToolStatus.running &&
          _turnOf[m.id] == _currentTurn) {
        _display[i] = m.copyWith(status: AiToolStatus.error);
      }
    }
  }

  /// Replaces the in-flight assistant bubble's text in [_display].
  void _setStreamingText(String text) {
    final id = _streamingId;
    if (id == null) return;
    final i = _display.indexWhere((m) => m.id == id);
    if (i != -1) {
      final m = _display[i];
      if (m is AiTextMessage) _display[i] = m.copyWith(text: text);
    }
  }

  /// Trims [_history] to the most recent [_maxHistory] text turns, then drops
  /// display items belonging to turns that are no longer retained.
  void _trimHistory() {
    final overflow = _history.length - _maxHistory;
    if (overflow <= 0) return;
    _history.removeRange(0, overflow);
    _historyTurns.removeRange(0, overflow);

    // Oldest text turn still in history. Display items (text or tool) tagged
    // with an earlier turn no longer have a backing text turn — drop them so
    // the visible transcript stays bounded alongside the token history.
    final oldestTurn =
        _historyTurns.isEmpty ? _currentTurn : _historyTurns.first;
    _display.removeWhere((m) {
      final t = _turnOf[m.id];
      if (t != null && t < oldestTurn) {
        _turnOf.remove(m.id);
        return true;
      }
      return false;
    });
  }

  void _emit({
    bool? isStreaming,
    Failure? failure,
    bool clearFailure = false,
  }) {
    emit(
      state.copyWith(
        messages: List<AiChatItem>.unmodifiable(_display),
        isStreaming: isStreaming,
        failure: failure,
        clearFailure: clearFailure,
      ),
    );
  }
}
