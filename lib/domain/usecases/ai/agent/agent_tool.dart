import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';

/// A read-only tool the folder agent ([RunFolderAgent]) can call to gather
/// information about the user's mail on demand.
///
/// Each implementation wraps an injected use case (e.g. `GetEmails`) and
/// returns a compact text/JSON string the model can read. Implementations are
/// advertised to the model as `AiToolDefinition`s (built from [name],
/// [description], and [parametersSchema]) and invoked by name when the model
/// emits a matching tool call.
///
/// Tool failures surface as a `Left(Failure)` from [invoke]; the agent loop
/// serializes them back into the tool-result string so the model can recover
/// instead of aborting the turn. Recoverable input problems (e.g. a missing
/// required argument) are returned as a `Right` whose string describes the
/// problem, since they are not [Failure]s.
abstract interface class AgentTool {
  /// The tool name the model references when calling it.
  String get name;

  /// A natural-language description of what the tool does, for the model.
  String get description;

  /// JSON-Schema object describing the tool's argument shape.
  Map<String, dynamic> get parametersSchema;

  /// Executes the tool with the model-supplied [args].
  ///
  /// [currentFolderId] is the folder the panel is viewing; tools that accept a
  /// `folder_id` default to it when the model does not supply one.
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  });
}
