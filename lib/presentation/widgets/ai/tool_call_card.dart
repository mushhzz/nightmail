import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../blocs/ai/ai_folder_chat_state.dart';

/// An inline, collapsible card rendering a single agent tool call — the Vercel
/// AI Elements `Tool` pattern adapted to Flutter.
///
/// Collapsed (default) is a compact one-liner: tool icon, humanized name, a
/// short argument preview, a status pill, and a chevron. Tapping expands to show
/// pretty-printed JSON for the input arguments and the output (or error text).
/// An [AiToolStatus.error] card is forced open and cannot be collapsed.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.item});

  final AiToolItem item;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  /// Success-state glyph color (no green in [AppColors], so use a local one).
  static const Color _successColor = Color(0xFF34D399);

  bool _expanded = false;

  bool get _forceExpanded => widget.item.status == AiToolStatus.error;
  bool get _isExpanded => _expanded || _forceExpanded;

  void _toggle() {
    if (_forceExpanded) return;
    setState(() => _expanded = !_expanded);
  }

  /// Humanized tool name, tensed by lifecycle status.
  String _humanizedName() {
    final running = widget.item.status == AiToolStatus.running;
    switch (widget.item.name) {
      case 'search_emails':
        return running ? 'Searching…' : 'Searched emails';
      case 'list_emails':
        return running ? 'Listing…' : 'Listed emails';
      case 'get_email':
        return running ? 'Reading…' : 'Read email';
      case 'list_folders':
        return running ? 'Listing…' : 'Listed folders';
      default:
        return widget.item.name;
    }
  }

  IconData _toolIcon() {
    switch (widget.item.name) {
      case 'search_emails':
        return Icons.search;
      case 'list_emails':
        return Icons.list_alt_outlined;
      case 'get_email':
        return Icons.mail_outline;
      case 'list_folders':
        return Icons.folder_outlined;
      default:
        return Icons.build_outlined;
    }
  }

  /// The first salient argument value (e.g. the search query, an email id, or a
  /// subject) for the collapsed one-liner preview, or null when none.
  String? _argPreview() {
    final args = widget.item.args;
    for (final key in const ['query', 'subject', 'id', 'folder_id']) {
      final v = args[key];
      final s = v?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    if (args.isNotEmpty) {
      final s = args.values.first?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  String _prettyArgs() {
    try {
      return _encoder.convert(widget.item.args);
    } catch (_) {
      return widget.item.args.toString();
    }
  }

  /// Pretty-prints [AiToolItem.output]: when it is a JSON string, decode then
  /// re-encode indented; otherwise fall back to the raw string.
  String _prettyOutput() {
    final out = widget.item.output;
    if (out == null || out.isEmpty) return '';
    try {
      return _encoder.convert(jsonDecode(out));
    } on FormatException {
      return out;
    } catch (_) {
      return out;
    }
  }

  Widget _statusPill(AppColors c) {
    switch (widget.item.status) {
      case AiToolStatus.running:
        return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
          ),
        );
      case AiToolStatus.complete:
        return const Icon(
          Icons.check_circle_outline,
          size: 15,
          color: _successColor,
        );
      case AiToolStatus.error:
        return Icon(
          Icons.error_outline,
          size: 15,
          color: c.errorBannerText,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          color: c.surfacePanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.separatorStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(c),
            if (_isExpanded) _buildBody(c),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    final preview = _argPreview();
    final chevron = _isExpanded
        ? Icons.keyboard_arrow_up_rounded
        : Icons.keyboard_arrow_down_rounded;
    return InkWell(
      onTap: _forceExpanded ? null : _toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(_toolIcon(), size: 14, color: c.textMuted),
            const SizedBox(width: 8),
            Text(
              _humanizedName(),
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (preview != null) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            _statusPill(c),
            const SizedBox(width: 4),
            Icon(chevron, size: 16, color: c.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    final output = _prettyOutput();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(c, 'Input'),
          _codeBlock(c, _prettyArgs()),
          const SizedBox(height: 8),
          _sectionLabel(c, 'Output'),
          _codeBlock(c, output.isEmpty ? '—' : output),
        ],
      ),
    );
  }

  Widget _sectionLabel(AppColors c, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: c.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _codeBlock(AppColors c, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
            fontSize: 11,
            height: 1.4,
            color: c.textSecondary,
          ),
        ),
      ),
    );
  }
}
