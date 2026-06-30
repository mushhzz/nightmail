import 'dart:convert';

import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import '../../../../core/usecases/usecase.dart';
import '../../../entities/email.dart';
import '../../../entities/email_address.dart';
import '../../../entities/email_folder.dart';
import '../../get_email.dart';
import '../../get_emails.dart';
import '../../get_mail_folders.dart';
import '../../search_emails.dart';
import 'agent_tool.dart';

/// `list_emails` — lists the emails in a folder (defaults to the current
/// folder), returning an indexed list of metadata + preview.
///
/// Backs [GetEmails]. Previews only (no full bodies), so it is unaffected by
/// the cloud-bodies privacy guard.
class ListEmailsTool implements AgentTool {
  const ListEmailsTool(this._getEmails);

  final GetEmails _getEmails;

  @override
  String get name => 'list_emails';

  @override
  String get description =>
      'List emails in a folder (defaults to the folder the user is currently '
      'viewing). Returns an indexed list of id, from, subject, date, read '
      'state and a short preview. Use get_email to read a full message.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'folder_id': {
            'type': 'string',
            'description':
                'Folder to list from. Defaults to the current folder.',
          },
          'limit': {
            'type': 'integer',
            'description': 'Maximum emails to return (default 25, max 100).',
          },
          'unread_only': {
            'type': 'boolean',
            'description': 'When true, only return unread emails.',
          },
        },
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final folderId = _asString(args['folder_id']) ?? currentFolderId;
    final limit = ((_asInt(args['limit']) ?? 25).clamp(1, 100)).toInt();
    final unreadOnly = _asBool(args['unread_only']) ?? false;

    final result = await _getEmails(
      GetEmailsParams(
        folderId: folderId,
        top: limit,
        filter: unreadOnly ? 'isRead eq false' : null,
      ),
    );
    return result.map(_encodeEmailList);
  }
}

/// `get_email` — reads a single email by id.
///
/// Backs [GetEmail]. The privacy guard (§4) lives here: when [includeBodies]
/// is false (cloud provider, user has not opted in), the full body is withheld
/// and only metadata + preview are returned, with a note explaining why.
class GetEmailTool implements AgentTool {
  const GetEmailTool(this._getEmail, {required this.includeBodies});

  final GetEmail _getEmail;

  /// Whether full message bodies may be returned. False = cloud provider
  /// without the cloud-bodies opt-in → return preview only.
  final bool includeBodies;

  @override
  String get name => 'get_email';

  @override
  String get description =>
      'Read a single email by its id, including recipients and the full body '
      'when permitted. Get ids from list_emails or search_emails first.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'The id of the email to read.',
          },
        },
        'required': ['id'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final id = _asString(args['id']);
    if (id == null) {
      return Right(jsonEncode({'error': "Missing required argument 'id'."}));
    }

    final result = await _getEmail(GetEmailParams(id: id));
    return result.map((email) => _encodeEmail(email, includeBodies));
  }
}

/// `search_emails` — full-text searches a folder (or the current folder).
///
/// Backs [SearchEmails]. Returns the same metadata + preview list shape as
/// [ListEmailsTool], so it is unaffected by the cloud-bodies guard.
class SearchEmailsTool implements AgentTool {
  const SearchEmailsTool(this._searchEmails);

  final SearchEmails _searchEmails;

  @override
  String get name => 'search_emails';

  @override
  String get description =>
      'Search for emails matching a query (defaults to the current folder). '
      'Returns an indexed list of id, from, subject, date, read state and a '
      'short preview. Use get_email to read a full message.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The search query.',
          },
          'folder_id': {
            'type': 'string',
            'description':
                'Folder to search. Defaults to the current folder.',
          },
          'limit': {
            'type': 'integer',
            'description': 'Maximum results to return (default 50, max 100).',
          },
        },
        'required': ['query'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final query = _asString(args['query']);
    if (query == null) {
      return Right(jsonEncode({'error': "Missing required argument 'query'."}));
    }
    final folderId = _asString(args['folder_id']) ?? currentFolderId;
    final limit = ((_asInt(args['limit']) ?? 50).clamp(1, 100)).toInt();

    final result = await _searchEmails(
      SearchEmailsParams(query: query, folderId: folderId, top: limit),
    );
    return result.map(_encodeEmailList);
  }
}

/// `list_folders` — lists the user's mail folders with unread/total counts.
///
/// Backs [GetMailFolders]. Takes no arguments.
class ListFoldersTool implements AgentTool {
  const ListFoldersTool(this._getMailFolders);

  final GetMailFolders _getMailFolders;

  @override
  String get name => 'list_folders';

  @override
  String get description =>
      'List the user\'s mail folders with their unread and total message '
      'counts. Use a folder id with list_emails or search_emails.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': <String, dynamic>{},
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final result = await _getMailFolders(const NoParams());
    return result.map(_encodeFolderList);
  }
}

// --- Shared formatting helpers -------------------------------------------

/// Encodes a list of emails as a compact indexed JSON string (metadata +
/// preview, no full bodies).
String _encodeEmailList(List<Email> emails) {
  final items = <Map<String, dynamic>>[];
  for (var i = 0; i < emails.length; i++) {
    final e = emails[i];
    items.add({
      'index': i,
      'id': e.id,
      'from': _formatAddress(e.from),
      'subject': e.subject,
      'date': e.receivedDateTime.toIso8601String(),
      'isRead': e.isRead,
      'hasAttachments': e.hasAttachments,
      'preview': e.bodyPreview,
    });
  }
  return jsonEncode({'count': items.length, 'emails': items});
}

/// Encodes a single email as a JSON string. The full [Email.body] is included
/// only when [includeBodies] is true; otherwise the preview is returned with a
/// note explaining the privacy guard.
String _encodeEmail(Email e, bool includeBodies) {
  final map = <String, dynamic>{
    'id': e.id,
    'from': _formatAddress(e.from),
    'to': e.toRecipients.map(_formatAddress).toList(),
    'cc': e.ccRecipients.map(_formatAddress).toList(),
    'subject': e.subject,
    'date': e.receivedDateTime.toIso8601String(),
    'isRead': e.isRead,
    'importance': e.importance.name,
    'hasAttachments': e.hasAttachments,
  };
  if (includeBodies) {
    map['bodyType'] = e.bodyType.name;
    map['body'] = e.body;
  } else {
    map['preview'] = e.bodyPreview;
    map['note'] = 'Full message body is disabled for cloud providers without '
        'explicit opt-in. Showing preview only.';
  }
  return jsonEncode(map);
}

/// Encodes mail folders as a compact JSON string.
String _encodeFolderList(List<EmailFolder> folders) {
  final items = folders
      .map((f) => {
            'id': f.id,
            'name': f.displayName,
            'unread': f.unreadItemCount,
            'total': f.totalItemCount,
          })
      .toList();
  return jsonEncode({'count': items.length, 'folders': items});
}

String _formatAddress(EmailAddress a) {
  final name = a.name;
  if (name != null && name.isNotEmpty) return '$name <${a.address}>';
  return a.address;
}

String? _asString(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

bool? _asBool(Object? v) {
  if (v is bool) return v;
  if (v is int) return v == 1 ? true : (v == 0 ? false : null);
  if (v is String) {
    switch (v.toLowerCase()) {
      case 'true':
      case '1':
        return true;
      case 'false':
      case '0':
        return false;
    }
  }
  return null;
}
