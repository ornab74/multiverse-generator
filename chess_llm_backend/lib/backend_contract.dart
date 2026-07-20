import 'dart:convert';
import 'dart:io';

const schema = 'nexus.chess-llm/1';
const service = 'nexus-chess-gemma';
const modelName = 'gemma-4-E2B-it.litertlm';
const modelRepository = 'litert-community/gemma-4-E2B-it-litert-lm';
const modelRevision = '7fa1d78473894f7e736a21d920c3aa80f950c0db';
const modelSha256 =
    'ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42';
const modelByteLength = 2583085056;
const modelUrl =
    'https://huggingface.co/$modelRepository/resolve/$modelRevision/$modelName';
const modelPathVariable = 'NEXUS_CHESS_MODEL_PATH';
const portVariable = 'NEXUS_CHESS_LLM_PORT';
const tokenVariable = 'NEXUS_CHESS_LLM_TOKEN';
const maxRequestBytes = 64 * 1024;
const maxPromptCharacters = 28000;
const maxHistoryMessageCharacters = 20000;
const maxHistorySessionCharacters = 80;
const maxSavedGameNameCharacters = 80;
const positionVectorDimensions = 32;

const cpuOnlyReport = <String, Object>{
  'local_only': true,
  'inference_backend': 'cpu',
  'gpu_inference_allowed': false,
};

int configuredServerPort(String? configured, {int fallback = 47621}) {
  final value = configured?.trim() ?? '';
  if (value.isEmpty) return fallback;
  final port = int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    throw const FormatException('Server port must be an integer from 1-65535.');
  }
  return port;
}

/// Accepts RFC 6750 `b64token` characters and rejects whitespace, control
/// characters, Unicode, and padding followed by non-padding data.
bool isValidBearerToken(String token) {
  if (token.length < 32 || token.length > 256) return false;
  var sawPadding = false;
  var sawData = false;
  for (final codeUnit in token.codeUnits) {
    if (codeUnit == 0x3d) {
      if (!sawData) return false;
      sawPadding = true;
      continue;
    }
    if (sawPadding || !_isBearerCodeUnit(codeUnit)) return false;
    sawData = true;
  }
  return sawData;
}

bool _isBearerCodeUnit(int value) {
  final alphaNumeric =
      (value >= 0x30 && value <= 0x39) ||
      (value >= 0x41 && value <= 0x5a) ||
      (value >= 0x61 && value <= 0x7a);
  return alphaNumeric ||
      value == 0x2d || // -
      value == 0x2e || // .
      value == 0x5f || // _
      value == 0x7e || // ~
      value == 0x2b || // +
      value == 0x2f; // /
}

/// Compares every byte up to the longer input and includes length in the
/// accumulated difference. This avoids an early-exit comparison for secrets.
bool constantTimeEquals(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  var difference = leftBytes.length ^ rightBytes.length;
  final length = leftBytes.length > rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < length; index++) {
    final leftByte = index < leftBytes.length ? leftBytes[index] : 0;
    final rightByte = index < rightBytes.length ? rightBytes[index] : 0;
    difference |= leftByte ^ rightByte;
  }
  return difference == 0;
}

bool isAuthorizedBearerHeader(String? authorization, String bearerToken) {
  if (!isValidBearerToken(bearerToken)) return false;
  return constantTimeEquals(authorization ?? '', 'Bearer $bearerToken');
}

bool hasExactModelByteLength(int length) => length == modelByteLength;

String configuredModelPath(String configured, {String pathSeparator = '/'}) {
  final value = configured.trim();
  if (value.isEmpty || value.contains('\u0000')) {
    throw const FormatException('Configured model path is empty or invalid.');
  }
  if (value.toLowerCase().endsWith('.litertlm')) return value;
  const backslash = '\\';
  final separators = pathSeparator == backslash
      ? <String>[backslash, '/']
      : <String>['/', backslash];
  var directory = value;
  while (directory.isNotEmpty &&
      separators.contains(directory[directory.length - 1])) {
    directory = directory.substring(0, directory.length - 1);
  }
  if (directory.isEmpty) directory = pathSeparator;
  final joiner = directory.endsWith(pathSeparator) ? '' : pathSeparator;
  return '$directory$joiner$modelName';
}

bool isAllowedModelUri(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == 'huggingface.co' ||
      host.endsWith('.huggingface.co') ||
      host == 'cdn.hf.co' ||
      host.endsWith('.cdn.hf.co') ||
      host == 'xethub.hf.co' ||
      host.endsWith('.xethub.hf.co');
}

({int start, int end, int total})? parseContentRange(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final total = int.tryParse(match.group(3)!);
  if (start == null ||
      end == null ||
      total == null ||
      start < 0 ||
      end < start ||
      total <= end) {
    return null;
  }
  return (start: start, end: end, total: total);
}

String validatedPrompt(Map<String, dynamic> body) {
  final candidate = body['prompt'] ?? body['message'];
  final prompt = candidate is String ? candidate.trim() : '';
  if (candidate is! String ||
      prompt.isEmpty ||
      prompt.length > maxPromptCharacters) {
    throw const RequestFailure(
      'prompt_invalid',
      'The prompt must contain 1-28,000 characters.',
      HttpStatus.badRequest,
    );
  }
  return prompt;
}

int normalizedMaxOutputTokens(Object? value) {
  return value is int ? value.clamp(16, 768) : 512;
}

double normalizedTemperature(Object? value) {
  if (value is! num || !value.isFinite) return 0.35;
  return value.toDouble().clamp(0.05, 0.90);
}

int normalizedTopK(Object? value) {
  return value is int ? value.clamp(4, 64) : 24;
}

double normalizedTopP(Object? value) {
  if (value is! num || !value.isFinite) return 0.86;
  return value.toDouble().clamp(0.55, 0.99);
}

int normalizedRandomSeed(Object? value) {
  return value is int ? value.clamp(1, 0x7fffffff) : 17;
}

List<double> validatedPositionVector(Object? value) {
  if (value is! List || value.length != positionVectorDimensions) {
    throw const RequestFailure(
      'position_vector_invalid',
      'The position vector must contain exactly 32 bounded numbers.',
      HttpStatus.badRequest,
    );
  }
  final result = <double>[];
  for (final component in value) {
    if (component is! num || !component.isFinite) {
      throw const RequestFailure(
        'position_vector_invalid',
        'The position vector contains a non-finite component.',
        HttpStatus.badRequest,
      );
    }
    final number = component.toDouble();
    if (number < -1.0 || number > 1.0) {
      throw const RequestFailure(
        'position_vector_invalid',
        'The position vector contains an out-of-range component.',
        HttpStatus.badRequest,
      );
    }
    result.add(number);
  }
  return result;
}

Map<String, dynamic> validatedHistoryRequest(Map<String, dynamic> body) {
  final operation = body['operation'] is String
      ? (body['operation'] as String).trim()
      : '';
  const fields = <String, Set<String>>{
    'append_conversation': {'operation', 'session_id', 'speaker', 'message'},
    'append_move': {
      'operation',
      'session_id',
      'ply',
      'actor',
      'uci',
      'algebraic',
      'state_hash',
      'position_vector',
      'quantum_state',
      'skill_color',
      'style_id',
    },
    'recent': {'operation', 'session_id', 'limit'},
    'recall_moves': {'operation', 'session_id', 'position_vector', 'limit'},
    'finalize_game': {'operation', 'session_id', 'result', 'winner'},
  };
  final allowed = fields[operation];
  if (allowed == null) {
    throw const RequestFailure(
      'history_operation_invalid',
      'The local history operation is not supported.',
      HttpStatus.badRequest,
    );
  }
  for (final key in body.keys) {
    if (!allowed.contains(key)) {
      throw RequestFailure(
        'history_field_invalid',
        'The local history request contains an unsupported field: $key.',
        HttpStatus.badRequest,
      );
    }
  }
  final session = body['session_id'];
  if (session is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$').hasMatch(session.trim()) ||
      session.trim().length > maxHistorySessionCharacters) {
    throw const RequestFailure(
      'history_session_invalid',
      'The local game session id is invalid.',
      HttpStatus.badRequest,
    );
  }
  final result = <String, dynamic>{
    'operation': operation,
    'session_id': session.trim(),
  };
  switch (operation) {
    case 'append_conversation':
      final speaker = body['speaker'];
      final message = body['message'];
      if (speaker is! String ||
          !const {
            'YOU',
            'CAISSA',
            'SYSTEM',
          }.contains(speaker.trim().toUpperCase()) ||
          message is! String ||
          message.trim().isEmpty ||
          message.length > maxHistoryMessageCharacters ||
          message.contains('\u0000')) {
        throw const RequestFailure(
          'history_content_invalid',
          'The local conversation record is invalid.',
          HttpStatus.badRequest,
        );
      }
      result['speaker'] = speaker.trim().toUpperCase();
      result['message'] = message;
      break;
    case 'append_move':
      final ply = body['ply'];
      final actor = body['actor'];
      final uci = body['uci'];
      final algebraic = body['algebraic'];
      final stateHash = body['state_hash'];
      if (ply is! int ||
          ply < 1 ||
          ply > 1024 ||
          actor is! String ||
          !const {'YOU', 'CAISSA'}.contains(actor.trim().toUpperCase()) ||
          uci is! String ||
          !RegExp(
            r'^[a-h][1-8][a-h][1-8][qrbn]?$',
            caseSensitive: false,
          ).hasMatch(uci.trim()) ||
          algebraic is! String ||
          algebraic.trim().isEmpty ||
          algebraic.length > 120 ||
          algebraic.contains('\u0000') ||
          stateHash is! String ||
          !RegExp(
            r'^[0-9a-f]{64}$',
            caseSensitive: false,
          ).hasMatch(stateHash.trim())) {
        throw const RequestFailure(
          'history_move_invalid',
          'The local chess move record is invalid.',
          HttpStatus.badRequest,
        );
      }
      result['ply'] = ply;
      result['actor'] = actor.trim().toUpperCase();
      result['uci'] = uci.trim().toLowerCase();
      result['algebraic'] = algebraic;
      result['state_hash'] = stateHash.trim().toLowerCase();
      if (body.containsKey('position_vector')) {
        final quantumState = body['quantum_state'];
        final skillColor = body['skill_color'];
        final styleId = body['style_id'];
        if (quantumState is! String ||
            !RegExp(
              r'^(?:0(?:\.\d{1,8})?|1(?:\.0{1,8})?)$',
            ).hasMatch(quantumState.trim()) ||
            skillColor is! String ||
            !const {
              'red',
              'orange',
              'yellow',
              'green',
              'blue',
              'indigo',
              'violet',
            }.contains(skillColor.trim().toLowerCase()) ||
            styleId is! String ||
            !RegExp(
              r'^[a-z][a-z0-9_-]{0,47}$',
            ).hasMatch(styleId.trim().toLowerCase())) {
          throw const RequestFailure(
            'history_memory_invalid',
            'The move-memory metadata is invalid.',
            HttpStatus.badRequest,
          );
        }
        result['position_vector'] = validatedPositionVector(
          body['position_vector'],
        );
        result['quantum_state'] = quantumState.trim();
        result['skill_color'] = skillColor.trim().toLowerCase();
        result['style_id'] = styleId.trim().toLowerCase();
      }
      break;
    case 'recent':
      final limit = body['limit'];
      if (limit is! int || limit < 1 || limit > 128) {
        throw const RequestFailure(
          'history_limit_invalid',
          'The local history limit must be between 1 and 128.',
          HttpStatus.badRequest,
        );
      }
      result['limit'] = limit;
      break;
    case 'recall_moves':
      final limit = body['limit'];
      if (limit is! int || limit < 1 || limit > 32) {
        throw const RequestFailure(
          'memory_limit_invalid',
          'Move-memory recall must request between 1 and 32 records.',
          HttpStatus.badRequest,
        );
      }
      result['position_vector'] = validatedPositionVector(
        body['position_vector'],
      );
      result['limit'] = limit;
      break;
    case 'finalize_game':
      final gameResult = body['result'];
      final winner = body['winner'];
      if (gameResult is! String ||
          !const {
            'checkmate',
            'stalemate',
            'draw',
            'game complete',
          }.contains(gameResult.trim().toLowerCase()) ||
          winner is! String ||
          !const {'', 'white', 'black'}.contains(winner.trim().toLowerCase())) {
        throw const RequestFailure(
          'game_outcome_invalid',
          'The game-memory outcome is invalid.',
          HttpStatus.badRequest,
        );
      }
      result['result'] = gameResult.trim().toLowerCase();
      result['winner'] = winner.trim().toLowerCase();
      break;
  }
  return result;
}

Map<String, dynamic> validatedGameRequest(Map<String, dynamic> body) {
  final operation = body['operation'] is String
      ? (body['operation'] as String).trim()
      : '';
  const fields = <String, Set<String>>{
    'save_game': {
      'operation',
      'game_id',
      'name',
      'session_id',
      'state',
      'history',
    },
    'load_game': {'operation', 'game_id'},
    'list_games': {'operation', 'limit'},
    'delete_game': {'operation', 'game_id'},
  };
  final allowed = fields[operation];
  if (allowed == null) {
    throw const RequestFailure(
      'game_operation_invalid',
      'The saved game operation is not supported.',
      HttpStatus.badRequest,
    );
  }
  for (final key in body.keys) {
    if (!allowed.contains(key)) {
      throw RequestFailure(
        'game_field_invalid',
        'The saved game request contains an unsupported field: $key.',
        HttpStatus.badRequest,
      );
    }
  }
  final result = <String, dynamic>{'operation': operation};
  if (operation == 'list_games') {
    final limit = body['limit'] ?? 32;
    if (limit is! int || limit < 1 || limit > 64) {
      throw const RequestFailure(
        'game_limit_invalid',
        'The saved game limit must be between 1 and 64.',
        HttpStatus.badRequest,
      );
    }
    result['limit'] = limit;
    return result;
  }

  final gameId = body['game_id'];
  if (gameId is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$').hasMatch(gameId.trim())) {
    throw const RequestFailure(
      'game_id_invalid',
      'The saved game id is invalid.',
      HttpStatus.badRequest,
    );
  }
  result['game_id'] = gameId.trim();
  if (operation == 'save_game') {
    final name = body['name'];
    final session = body['session_id'];
    final state = body['state'];
    final history = body['history'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > maxSavedGameNameCharacters ||
        name.contains('\u0000') ||
        session is! String ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$',
        ).hasMatch(session.trim()) ||
        state is! Map ||
        history is! List ||
        history.length > 512) {
      throw const RequestFailure(
        'game_payload_invalid',
        'The saved game payload is invalid.',
        HttpStatus.badRequest,
      );
    }
    result['name'] = name;
    result['session_id'] = session.trim();
    result['state'] = Map<String, dynamic>.from(state);
    result['history'] = List<dynamic>.from(history);
  }
  return result;
}

Map<String, dynamic> validatedPreferencesRequest(Map<String, dynamic> body) {
  final operation = body['operation'] is String
      ? (body['operation'] as String).trim().toLowerCase()
      : '';
  final allowed = operation == 'get'
      ? const <String>{'operation'}
      : operation == 'set'
      ? const <String>{
          'operation',
          'memory_enabled',
          'skill_color',
          'style_id',
          'player_side',
        }
      : null;
  if (allowed == null) {
    throw const RequestFailure(
      'preferences_operation_invalid',
      'The agent-preferences operation is not supported.',
      HttpStatus.badRequest,
    );
  }
  for (final key in body.keys) {
    if (!allowed.contains(key)) {
      throw RequestFailure(
        'preferences_field_invalid',
        'The agent-preferences request contains an unsupported field: $key.',
        HttpStatus.badRequest,
      );
    }
  }
  if (operation == 'get') return const {'operation': 'get'};
  final memoryEnabled = body['memory_enabled'];
  final skillColor = body['skill_color'];
  final styleId = body['style_id'];
  final playerSide = body['player_side'];
  if (memoryEnabled is! bool ||
      skillColor is! String ||
      !const {
        'red',
        'orange',
        'yellow',
        'green',
        'blue',
        'indigo',
        'violet',
      }.contains(skillColor.trim().toLowerCase()) ||
      styleId is! String ||
      !RegExp(
        r'^[a-z][a-z0-9_-]{0,47}$',
      ).hasMatch(styleId.trim().toLowerCase()) ||
      playerSide is! String ||
      !const {'white', 'black'}.contains(playerSide.trim().toLowerCase())) {
    throw const RequestFailure(
      'preferences_invalid',
      'The agent preferences are invalid.',
      HttpStatus.badRequest,
    );
  }
  return <String, dynamic>{
    'operation': 'set',
    'memory_enabled': memoryEnabled,
    'skill_color': skillColor.trim().toLowerCase(),
    'style_id': styleId.trim().toLowerCase(),
    'player_side': playerSide.trim().toLowerCase(),
  };
}

Map<String, dynamic> decodeJsonObject(List<int> bytes) {
  if (bytes.isEmpty) return <String, dynamic>{};
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  } catch (_) {
    throw const RequestFailure(
      'json_invalid',
      'The request body must be a UTF-8 JSON object.',
      HttpStatus.badRequest,
    );
  }
  if (decoded is! Map) {
    throw const RequestFailure(
      'json_object_required',
      'The request body must be a JSON object.',
      HttpStatus.badRequest,
    );
  }
  return Map<String, dynamic>.from(decoded);
}

final class RequestFailure implements Exception {
  const RequestFailure(this.code, this.message, this.status);

  final String code;
  final String message;
  final int status;
}
