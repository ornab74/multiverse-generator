import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const _storeVersion = 1;
const _databaseVersion = 3;
const _storeFileName = 'nexus_chess_local.sqlite3';
const _storeKeyFileName = 'nexus_chess_local.key';
const _storeKeyName = 'nexus-chess-local-store-key-v1';
const _maxMessageCharacters = 20000;
const _maxSessionCharacters = 80;
const _maxHistoryRows = 4096;
const _maxHistoryRead = 128;
const _maxRecallScan = 4096;
const _positionVectorDimensions = 32;
const _maxSavedGames = 64;
const _maxGameHistory = 512;

/// Small interface makes the store testable without touching the platform
/// keychain. Production uses the operating system's protected app storage.
abstract interface class NexusStoreKeyProvider {
  Future<String?> read(String name);

  Future<void> write(String name, String value);
}

final class NexusPlatformStoreKeyProvider implements NexusStoreKeyProvider {
  const NexusPlatformStoreKeyProvider();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String name) => _storage.read(key: name);

  @override
  Future<void> write(String name, String value) {
    return _storage.write(key: name, value: value);
  }
}

final class NexusMemoryStoreKeyProvider implements NexusStoreKeyProvider {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String name) async => _values[name];

  @override
  Future<void> write(String name, String value) async {
    _values[name] = value;
  }
}

final class NexusLocalStoreException implements Exception {
  const NexusLocalStoreException(this.code, this.message, [this.cause]);

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'NexusLocalStoreException($code): $message';
}

final class NexusModelVerification {
  const NexusModelVerification({
    required this.model,
    required this.sha256,
    required this.byteLength,
    required this.path,
    required this.fileSize,
    required this.modifiedAt,
    required this.verifiedAt,
  });

  final String model;
  final String sha256;
  final int byteLength;
  final String path;
  final int fileSize;
  final int modifiedAt;
  final int verifiedAt;
}

/// Local history store.
///
/// SQLite contains only opaque identifiers, timestamps, and authenticated
/// encrypted payloads. Conversations, move details, model identity, paths,
/// and all user text are encrypted before they enter SQLite. Every write is
/// validated against a fixed schema and uses bound parameters.
final class NexusLocalStore {
  NexusLocalStore._({
    required this._directoryProvider,
    required this._keyProvider,
  });

  static final NexusLocalStore instance = NexusLocalStore._(
    directoryProvider: getApplicationSupportDirectory,
    keyProvider: const NexusPlatformStoreKeyProvider(),
  );

  factory NexusLocalStore.forTesting(
    Directory directory, {
    NexusStoreKeyProvider? keyProvider,
  }) {
    return NexusLocalStore._(
      directoryProvider: () async => directory,
      keyProvider: keyProvider ?? NexusMemoryStoreKeyProvider(),
    );
  }

  final Future<Directory> Function() _directoryProvider;
  final NexusStoreKeyProvider _keyProvider;
  final AesGcm _aes = AesGcm.with256bits();
  Future<void> _tail = Future<void>.value();
  sqlite.Database? _database;
  Uint8List? _key;
  int _eventSequence = 0;

  bool get isReady => _database != null && _key != null;

  Future<void> initialize() {
    return _serial(() async {
      if (isReady) return;
      final directory = await _directoryProvider();
      await directory.create(recursive: true);
      final file = File('${directory.path}/$_storeFileName');
      final keyFile = File('${directory.path}/$_storeKeyFileName');
      String? encoded;
      try {
        encoded = await _keyProvider.read(_storeKeyName);
      } catch (_) {
        // Some Linux sessions have a locked desktop keyring even though the
        // app itself is healthy. Continue to the protected per-install key
        // file instead of making model startup depend on that session state.
      }
      if (!_isValidEncodedKey(encoded)) {
        try {
          if (await keyFile.exists()) {
            encoded = (await keyFile.readAsString()).trim();
          }
        } catch (_) {
          encoded = null;
        }
      }
      Uint8List key;
      if (!_isValidEncodedKey(encoded)) {
        if (await file.exists()) {
          throw const NexusLocalStoreException(
            'store_key_missing',
            'The protected local history key is missing; refusing to open the existing database.',
          );
        }
        key = _randomBytes(32);
        final newEncoded = base64UrlEncode(key);
        try {
          await _keyProvider.write(_storeKeyName, newEncoded);
        } catch (_) {
          // The local key file is the continuity fallback when the platform
          // keyring is locked or unavailable.
        }
        await _writeKeyFile(keyFile, newEncoded);
      } else {
        try {
          key = Uint8List.fromList(base64Url.decode(encoded!));
        } catch (error) {
          throw NexusLocalStoreException(
            'store_key_invalid',
            'The protected local history key is malformed.',
            error,
          );
        }
        // Mirror a key obtained from the platform store so a later locked
        // keyring can still reopen the same authenticated database.
        await _writeKeyFile(keyFile, encoded);
        if (key.length != 32) {
          throw const NexusLocalStoreException(
            'store_key_invalid',
            'The protected local history key has an invalid length.',
          );
        }
      }

      sqlite.Database? opened;
      try {
        opened = sqlite.sqlite3.open(file.path);
        _configureConnection(opened);
        _createSchema(opened);
        final integrity = opened.select('PRAGMA integrity_check');
        if (integrity.isEmpty || integrity.first.columnAt(0) != 'ok') {
          throw const NexusLocalStoreException(
            'store_integrity',
            'The local history database failed its integrity check.',
          );
        }
        _key = key;
        _database = opened;
        opened = null;
      } catch (_) {
        opened?.close();
        _zero(key);
        rethrow;
      }
    });
  }

  Future<NexusModelVerification?> readModelVerification() {
    return _serial(() async {
      final row = _findRow(_categoryModel, _recordDigest('model-verification'));
      if (row == null) return null;
      final payload = await _openRow(row, _categoryModel, _emptySessionDigest);
      return _modelFromPayload(payload);
    });
  }

  Future<void> writeModelVerification(NexusModelVerification value) {
    _validateModelVerification(value);
    return _serial(() async {
      final recordId = _recordDigest('model-verification');
      await _writeRow(
        category: _categoryModel,
        recordId: recordId,
        sessionDigest: _emptySessionDigest,
        payload: {
          'v': _storeVersion,
          'kind': 'model_verification',
          'model': value.model,
          'sha256': value.sha256,
          'byte_length': value.byteLength,
          'path': _cleanPath(value.path),
          'file_size': value.fileSize,
          'modified_at': value.modifiedAt,
          'verified_at': value.verifiedAt,
        },
      );
    });
  }

  Future<void> appendConversation({
    required String sessionId,
    required String speaker,
    required String message,
  }) {
    final session = _cleanSession(sessionId);
    final safeSpeaker = _cleanSpeaker(speaker);
    final safeMessage = _cleanText(message, _maxMessageCharacters, 'message');
    return _serial(() async {
      await _appendEvent(
        category: _categoryConversation,
        sessionId: session,
        payload: {
          'v': _storeVersion,
          'kind': 'conversation',
          'session_id': session,
          'speaker': safeSpeaker,
          'message': safeMessage,
          'created_at': _now(),
        },
      );
      _trimHistory();
    });
  }

  Future<void> appendMove({
    required String sessionId,
    required int ply,
    required String actor,
    required String uci,
    required String algebraic,
    required String stateHash,
    List<double>? positionVector,
    String? quantumState,
    String? skillColor,
    String? styleId,
  }) {
    final session = _cleanSession(sessionId);
    final safeActor = _cleanSpeaker(actor);
    final safeUci = _cleanUci(uci);
    final safeAlgebraic = _cleanText(algebraic, 120, 'algebraic');
    final safeHash = _cleanHash(stateHash);
    final safeVector = positionVector == null
        ? null
        : _cleanPositionVector(positionVector);
    final safeQuantumState = safeVector == null
        ? null
        : _cleanQuantumState(quantumState);
    final safeSkillColor = safeVector == null
        ? null
        : _cleanSkillColor(skillColor);
    final safeStyleId = safeVector == null ? null : _cleanStyleId(styleId);
    if (ply < 1 || ply > 1024) {
      throw const NexusLocalStoreException(
        'move_invalid',
        'The move number is outside the supported range.',
      );
    }
    return _serial(() async {
      final payload = <String, Object?>{
        'v': _storeVersion,
        'kind': 'move',
        'session_id': session,
        'ply': ply,
        'actor': safeActor,
        'uci': safeUci,
        'algebraic': safeAlgebraic,
        'state_hash': safeHash,
        'created_at': _now(),
      };
      if (safeVector != null) {
        payload.addAll({
          'position_vector': safeVector,
          'quantum_state': safeQuantumState,
          'skill_color': safeSkillColor,
          'style_id': safeStyleId,
          'outcome': 'pending',
          'reward': 0.0,
        });
      }
      await _appendEvent(
        category: _categoryMove,
        sessionId: session,
        payload: payload,
      );
      _trimHistory();
    });
  }

  Future<List<Map<String, Object?>>> recentHistory({
    required String sessionId,
    int limit = 64,
  }) {
    final session = _cleanSession(sessionId);
    final boundedLimit = limit.clamp(1, _maxHistoryRead);
    return _serial(() async {
      final db = _requireDatabase();
      final sessionDigest = _sessionDigest(session);
      final rows = db.select(
        'SELECT category, record_id, session_id, nonce, cipher_text, mac '
        'FROM encrypted_records WHERE session_id = ? '
        'ORDER BY created_at DESC LIMIT ?',
        [sessionDigest, boundedLimit],
      );
      final result = <Map<String, Object?>>[];
      for (final row in rows.reversed) {
        final category = _intValue(row['category']);
        if (category != _categoryConversation && category != _categoryMove) {
          continue;
        }
        final decoded = await _openRow(row, category, sessionDigest);
        result.add(Map<String, Object?>.from(decoded));
      }
      return result;
    });
  }

  Future<List<Map<String, Object?>>> recallMoves({
    required String sessionId,
    required List<double> positionVector,
    int limit = 16,
  }) {
    final session = _cleanSession(sessionId);
    final queryVector = _cleanPositionVector(positionVector);
    final boundedLimit = limit.clamp(1, 32);
    return _serial(() async {
      final rows = _requireDatabase().select(
        'SELECT category, record_id, session_id, nonce, cipher_text, mac, created_at '
        'FROM encrypted_records WHERE category = ? '
        'ORDER BY created_at DESC LIMIT ?',
        [_categoryMove, _maxRecallScan],
      );
      final candidates = <Map<String, Object?>>[];
      for (final row in rows) {
        try {
          final rowSession = Uint8List.fromList(row['session_id'] as Uint8List);
          final payload = await _openRow(row, _categoryMove, rowSession);
          if (payload['session_id']?.toString() == session ||
              payload['position_vector'] is! List) {
            continue;
          }
          final vector = _cleanPositionVector(
            List<dynamic>.from(payload['position_vector'] as List),
          );
          final similarity = _cosineSimilarity(queryVector, vector);
          final reward = _boundedDouble(
            payload['reward'],
            -1.0,
            1.0,
            'move reward',
          );
          candidates.add({
            'uci': _cleanUci(payload['uci']?.toString() ?? ''),
            'actor': _cleanSpeaker(payload['actor']?.toString() ?? ''),
            'similarity': similarity,
            'outcome': _cleanOutcome(
              payload['outcome']?.toString() ?? 'pending',
            ),
            'reward': reward,
            'skill_color': _cleanSkillColor(
              payload['skill_color']?.toString() ?? 'yellow',
            ),
            'style_id': _cleanStyleId(
              payload['style_id']?.toString() ?? 'adaptive',
            ),
            'created_at': _intValue(payload['created_at']),
          });
        } on NexusLocalStoreException {
          rethrow;
        } catch (_) {
          // A legacy move without vector metadata is not a recall candidate.
        }
      }
      candidates.sort((left, right) {
        final leftScore =
            (left['similarity'] as double) + (left['reward'] as double) * 0.08;
        final rightScore =
            (right['similarity'] as double) +
            (right['reward'] as double) * 0.08;
        return rightScore.compareTo(leftScore);
      });
      return candidates.take(boundedLimit).toList(growable: false);
    });
  }

  Future<void> finalizeGameMemory({
    required String sessionId,
    required String result,
    required String winner,
  }) {
    final session = _cleanSession(sessionId);
    final safeResult = _cleanGameResult(result);
    final safeWinner = _cleanWinner(winner);
    final outcome = safeResult == 'stalemate' || safeResult == 'draw'
        ? 'draw'
        : safeWinner == 'black'
        ? 'black_win'
        : safeWinner == 'white'
        ? 'white_win'
        : 'draw';
    final reward = outcome == 'black_win'
        ? 1.0
        : outcome == 'white_win'
        ? -1.0
        : 0.0;
    return _serial(() async {
      final sessionDigest = _sessionDigest(session);
      final rows = _requireDatabase().select(
        'SELECT category, record_id, session_id, nonce, cipher_text, mac, created_at '
        'FROM encrypted_records WHERE category = ? AND session_id = ?',
        [_categoryMove, sessionDigest],
      );
      for (final row in rows) {
        final payload = await _openRow(row, _categoryMove, sessionDigest);
        if (payload['position_vector'] is! List) continue;
        payload['outcome'] = outcome;
        payload['reward'] = reward;
        payload['final_result'] = safeResult;
        await _writeRow(
          category: _categoryMove,
          recordId: Uint8List.fromList(row['record_id'] as Uint8List),
          sessionDigest: sessionDigest,
          payload: payload,
          createdAt: _intValue(row['created_at']),
        );
      }
    });
  }

  Future<Map<String, Object?>> readAgentPreferences() {
    return _serial(() async {
      final row = _findRow(
        _categoryPreferences,
        _recordDigest('agent-preferences'),
      );
      if (row == null) {
        return const <String, Object?>{
          'memory_enabled': true,
          'skill_color': 'yellow',
          'style_id': 'adaptive',
          'player_side': 'white',
        };
      }
      final payload = await _openRow(
        row,
        _categoryPreferences,
        _emptySessionDigest,
      );
      return <String, Object?>{
        'memory_enabled': payload['memory_enabled'] is bool
            ? payload['memory_enabled'] as bool
            : true,
        'skill_color': _cleanSkillColor(
          payload['skill_color']?.toString() ?? 'yellow',
        ),
        'style_id': _cleanStyleId(
          payload['style_id']?.toString() ?? 'adaptive',
        ),
        'player_side': _cleanPlayerSide(
          payload['player_side']?.toString() ?? 'white',
        ),
      };
    });
  }

  Future<void> writeAgentPreferences({
    required bool memoryEnabled,
    required String skillColor,
    required String styleId,
    required String playerSide,
  }) {
    final safeSkillColor = _cleanSkillColor(skillColor);
    final safeStyleId = _cleanStyleId(styleId);
    final safePlayerSide = _cleanPlayerSide(playerSide);
    return _serial(() async {
      await _writeRow(
        category: _categoryPreferences,
        recordId: _recordDigest('agent-preferences'),
        sessionDigest: _emptySessionDigest,
        payload: {
          'v': _storeVersion,
          'kind': 'agent_preferences',
          'memory_enabled': memoryEnabled,
          'skill_color': safeSkillColor,
          'style_id': safeStyleId,
          'player_side': safePlayerSide,
          'updated_at': _now(),
        },
      );
    });
  }

  Future<void> saveGame({
    required String gameId,
    required String name,
    required String sessionId,
    required Map<String, dynamic> state,
    required List<dynamic> history,
  }) {
    final safeGameId = _cleanGameId(gameId);
    final safeName = _cleanText(name, 80, 'game name');
    final safeSession = _cleanSession(sessionId);
    final safeState = _sanitizeGameState(state);
    final safeHistory = _sanitizeGameHistory(history);
    return _serial(() async {
      final now = _now();
      await _writeRow(
        category: _categoryGame,
        recordId: _recordDigest('game|$safeGameId'),
        sessionDigest: _sessionDigest(safeSession),
        payload: {
          'v': _storeVersion,
          'kind': 'game_snapshot',
          'game_id': safeGameId,
          'name': safeName,
          'session_id': safeSession,
          'state': safeState,
          'history': safeHistory,
          'saved_at': now,
        },
        createdAt: now,
      );
      _trimSavedGames();
    });
  }

  Future<Map<String, Object?>?> loadGame(String gameId) {
    final safeGameId = _cleanGameId(gameId);
    return _serial(() async {
      final recordId = _recordDigest('game|$safeGameId');
      final row = _findRow(_categoryGame, recordId);
      if (row == null) return null;
      final sessionDigest = Uint8List.fromList(row['session_id'] as Uint8List);
      final payload = await _openRow(row, _categoryGame, sessionDigest);
      return _sanitizeLoadedGame(payload, safeGameId);
    });
  }

  Future<List<Map<String, Object?>>> listGames({int limit = 32}) {
    final boundedLimit = limit.clamp(1, _maxSavedGames);
    return _serial(() async {
      final rows = _requireDatabase().select(
        'SELECT category, record_id, session_id, nonce, cipher_text, mac '
        'FROM encrypted_records WHERE category = ? '
        'ORDER BY created_at DESC LIMIT ?',
        [_categoryGame, boundedLimit],
      );
      final result = <Map<String, Object?>>[];
      for (final row in rows) {
        final sessionDigest = Uint8List.fromList(
          row['session_id'] as Uint8List,
        );
        final payload = await _openRow(row, _categoryGame, sessionDigest);
        final loaded = _sanitizeLoadedGame(
          payload,
          _cleanGameId(payload['game_id']?.toString() ?? ''),
        );
        result.add({
          'game_id': loaded['game_id'],
          'name': loaded['name'],
          'session_id': loaded['session_id'],
          'saved_at': loaded['saved_at'],
          'status': Map<String, Object?>.from(loaded['state'] as Map)['status'],
          'move_count': (loaded['history'] as List).length,
        });
      }
      return result;
    });
  }

  Future<void> deleteGame(String gameId) {
    final safeGameId = _cleanGameId(gameId);
    return _serial(() async {
      _requireDatabase().execute(
        'DELETE FROM encrypted_records WHERE category = ? AND record_id = ?',
        [_categoryGame, _recordDigest('game|$safeGameId')],
      );
    });
  }

  Future<Map<String, Object?>> health() {
    return _serial(() async {
      if (!isReady) {
        return const <String, Object?>{
          'ready': false,
          'history_entries': 0,
          'saved_games': 0,
        };
      }
      final count = _requireDatabase().select(
        'SELECT COUNT(*) AS count FROM encrypted_records '
        'WHERE category IN (?, ?)',
        [_categoryConversation, _categoryMove],
      );
      return <String, Object?>{
        'ready': true,
        'history_entries': _intValue(count.single['count']),
        'saved_games': _intValue(
          _requireDatabase().select(
            'SELECT COUNT(*) AS count FROM encrypted_records WHERE category = ?',
            [_categoryGame],
          ).single['count'],
        ),
      };
    });
  }

  Future<void> close() {
    return _serial(() async {
      final db = _database;
      _database = null;
      if (db != null) {
        try {
          db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        } catch (_) {}
        db.close();
      }
      _zero(_key);
      _key = null;
    });
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final queued = _tail.then((_) => operation());
    _tail = queued.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return queued;
  }

  Future<void> _appendEvent({
    required int category,
    required String sessionId,
    required Map<String, Object?> payload,
  }) async {
    final now = _now();
    _eventSequence = (_eventSequence + 1) & 0x7fffffff;
    final eventId = '$now-$_eventSequence';
    await _writeRow(
      category: category,
      recordId: _recordDigest('$category|$sessionId|$eventId'),
      sessionDigest: _sessionDigest(sessionId),
      payload: payload,
      createdAt: now,
    );
  }

  Future<void> _writeRow({
    required int category,
    required Uint8List recordId,
    required Uint8List sessionDigest,
    required Map<String, Object?> payload,
    int? createdAt,
  }) async {
    final db = _requireDatabase();
    final key = _key;
    if (key == null) {
      throw const NexusLocalStoreException(
        'store_locked',
        'The local history store is locked.',
      );
    }
    final clear = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final aad = _aad(category, recordId, sessionDigest);
    try {
      final box = await _aes.encrypt(
        clear,
        secretKey: SecretKey(key),
        aad: aad,
      );
      final timestamp = createdAt ?? _now();
      db.execute(
        'INSERT INTO encrypted_records '
        '(record_id, category, session_id, nonce, cipher_text, mac, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(record_id) DO UPDATE SET '
        'category=excluded.category, session_id=excluded.session_id, '
        'nonce=excluded.nonce, cipher_text=excluded.cipher_text, mac=excluded.mac, '
        'updated_at=excluded.updated_at',
        [
          recordId,
          category,
          sessionDigest,
          Uint8List.fromList(box.nonce),
          Uint8List.fromList(box.cipherText),
          Uint8List.fromList(box.mac.bytes),
          timestamp,
          timestamp,
        ],
      );
    } finally {
      _zero(clear);
    }
  }

  Future<Map<String, Object?>> _openRow(
    sqlite.Row row,
    int expectedCategory,
    Uint8List expectedSessionDigest,
  ) async {
    final key = _key;
    if (key == null) {
      throw const NexusLocalStoreException(
        'store_locked',
        'The local history store is locked.',
      );
    }
    final recordId = Uint8List.fromList(row['record_id'] as Uint8List);
    final sessionDigest = Uint8List.fromList(row['session_id'] as Uint8List);
    if (recordId.length != 32 ||
        sessionDigest.length != 32 ||
        !_constantTimeEquals(sessionDigest, expectedSessionDigest)) {
      throw const NexusLocalStoreException(
        'record_identity',
        'The local history record identity failed validation.',
      );
    }
    final nonce = row['nonce'] as Uint8List;
    final mac = row['mac'] as Uint8List;
    if (nonce.length != 12 || mac.length != 16) {
      throw const NexusLocalStoreException(
        'record_format',
        'The local history record envelope is malformed.',
      );
    }
    Uint8List? clear;
    try {
      clear = Uint8List.fromList(
        await _aes.decrypt(
          SecretBox(
            List<int>.from(row['cipher_text'] as Uint8List),
            nonce: List<int>.from(nonce),
            mac: Mac(List<int>.from(mac)),
          ),
          secretKey: SecretKey(key),
          aad: _aad(expectedCategory, recordId, sessionDigest),
        ),
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map || _intValue(decoded['v']) != _storeVersion) {
        throw const NexusLocalStoreException(
          'record_schema',
          'The local history record schema is unsupported.',
        );
      }
      final map = Map<String, Object?>.from(decoded);
      final kind = map['kind']?.toString() ?? '';
      if (expectedCategory == _categoryConversation && kind != 'conversation' ||
          expectedCategory == _categoryMove && kind != 'move' ||
          expectedCategory == _categoryModel && kind != 'model_verification' ||
          expectedCategory == _categoryGame && kind != 'game_snapshot' ||
          expectedCategory == _categoryPreferences &&
              kind != 'agent_preferences') {
        throw const NexusLocalStoreException(
          'record_identity',
          'The local history record category failed validation.',
        );
      }
      return map;
    } on SecretBoxAuthenticationError catch (error) {
      throw NexusLocalStoreException(
        'record_authentication',
        'The local history record could not be authenticated.',
        error,
      );
    } finally {
      _zero(clear);
    }
  }

  sqlite.Row? _findRow(int category, Uint8List recordId) {
    final rows = _requireDatabase().select(
      'SELECT category, record_id, session_id, nonce, cipher_text, mac '
      'FROM encrypted_records WHERE category = ? AND record_id = ?',
      [category, recordId],
    );
    return rows.isEmpty ? null : rows.single;
  }

  void _trimHistory() {
    final db = _requireDatabase();
    db.execute(
      'DELETE FROM encrypted_records WHERE category IN (?, ?) AND record_id NOT IN ('
      'SELECT record_id FROM encrypted_records WHERE category IN (?, ?) '
      'ORDER BY created_at DESC LIMIT ?)',
      [
        _categoryConversation,
        _categoryMove,
        _categoryConversation,
        _categoryMove,
        _maxHistoryRows,
      ],
    );
  }

  void _trimSavedGames() {
    _requireDatabase().execute(
      'DELETE FROM encrypted_records WHERE category = ? AND record_id NOT IN ('
      'SELECT record_id FROM encrypted_records WHERE category = ? '
      'ORDER BY created_at DESC LIMIT ?)',
      [_categoryGame, _categoryGame, _maxSavedGames],
    );
  }

  Map<String, Object?> _sanitizeLoadedGame(
    Map<String, Object?> payload,
    String expectedGameId,
  ) {
    final gameId = _cleanGameId(payload['game_id']?.toString() ?? '');
    if (gameId != expectedGameId) {
      throw const NexusLocalStoreException(
        'game_identity',
        'The saved game identity failed validation.',
      );
    }
    final sessionId = _cleanSession(payload['session_id']?.toString() ?? '');
    final name = _cleanText(payload['name']?.toString() ?? '', 80, 'game name');
    final savedAt = _intValue(payload['saved_at']);
    if (savedAt < 1) {
      throw const NexusLocalStoreException(
        'game_record_invalid',
        'The saved game timestamp is invalid.',
      );
    }
    final state = _sanitizeGameState(
      Map<String, dynamic>.from(payload['state'] as Map),
    );
    final history = _sanitizeGameHistory(payload['history'] as List);
    return {
      'game_id': gameId,
      'name': name,
      'session_id': sessionId,
      'state': state,
      'history': history,
      'saved_at': savedAt,
    };
  }

  Map<String, Object?> _sanitizeGameState(Map<String, dynamic> state) {
    final rawBoard = state['board'];
    final rawPlayers = state['players'];
    final rawCastling = state['castling'];
    if (rawBoard is! List ||
        rawBoard.length != 64 ||
        rawPlayers is! Map ||
        rawCastling is! Map) {
      throw const NexusLocalStoreException(
        'game_state_invalid',
        'The saved Chess Core state shape is invalid.',
      );
    }
    final board = <String>[];
    for (final square in rawBoard) {
      final piece = square?.toString() ?? '';
      if (piece.isNotEmpty && !RegExp(r'^[wb][KQRBNP]$').hasMatch(piece)) {
        throw const NexusLocalStoreException(
          'game_state_invalid',
          'The saved Chess Core board contains an invalid piece.',
        );
      }
      board.add(piece);
    }
    final turn = state['turn']?.toString() ?? '';
    final status = state['status']?.toString() ?? '';
    final winner = state['winner']?.toString() ?? '';
    final result = state['result']?.toString() ?? '';
    if (!const {'white', 'black'}.contains(turn) ||
        !const {'active', 'won', 'draw'}.contains(status) ||
        (winner.isNotEmpty && !const {'white', 'black'}.contains(winner)) ||
        !const {'', 'checkmate', 'stalemate'}.contains(result)) {
      throw const NexusLocalStoreException(
        'game_state_invalid',
        'The saved Chess Core turn or result is invalid.',
      );
    }
    final players = <String, String>{
      'white': _cleanText(rawPlayers['white']?.toString() ?? '', 64, 'player'),
      'black': _cleanText(rawPlayers['black']?.toString() ?? '', 64, 'player'),
    };
    final castling = <String, bool>{};
    for (final key in [
      'white_kingside',
      'white_queenside',
      'black_kingside',
      'black_queenside',
    ]) {
      if (rawCastling[key] is! bool) {
        throw const NexusLocalStoreException(
          'game_state_invalid',
          'The saved Chess Core castling state is invalid.',
        );
      }
      castling[key] = rawCastling[key] as bool;
    }
    return {
      'module_id': 'chess_core',
      'revision': _boundedInt(state['revision'], 0, 4096, 'revision'),
      'players': players,
      'turn': turn,
      'board': board,
      'castling': castling,
      'en_passant': _boundedInt(state['en_passant'], -1, 63, 'en passant'),
      'halfmove_clock': _boundedInt(
        state['halfmove_clock'],
        0,
        10000,
        'halfmove clock',
      ),
      'fullmove_number': _boundedInt(
        state['fullmove_number'],
        1,
        10000,
        'fullmove number',
      ),
      'status': status,
      'winner': winner,
      'winner_player': state['winner_player']?.toString().isEmpty == false
          ? _cleanText(state['winner_player']?.toString() ?? '', 64, 'winner')
          : '',
      'result': result,
      'check': state['check'] is bool ? state['check'] as bool : false,
    };
  }

  List<Map<String, Object?>> _sanitizeGameHistory(List<dynamic> history) {
    if (history.length > _maxGameHistory) {
      throw const NexusLocalStoreException(
        'game_history_invalid',
        'The saved game history is too long.',
      );
    }
    final result = <Map<String, Object?>>[];
    for (final raw in history) {
      if (raw is! Map) {
        throw const NexusLocalStoreException(
          'game_history_invalid',
          'The saved game history contains a malformed record.',
        );
      }
      final record = Map<String, dynamic>.from(raw);
      final actor = record['actor']?.toString().toUpperCase() ?? '';
      final side = record['side']?.toString().toLowerCase() ?? '';
      final uci = _cleanUci(record['uci']?.toString() ?? '');
      if (!const {'YOU', 'CAISSA'}.contains(actor) ||
          !const {'white', 'black'}.contains(side)) {
        throw const NexusLocalStoreException(
          'game_history_invalid',
          'The saved game history actor is invalid.',
        );
      }
      result.add({
        'ply': _boundedInt(record['ply'], 1, 1024, 'ply'),
        'side': side,
        'uci': uci,
        'algebraic': _cleanText(
          record['algebraic']?.toString() ?? '',
          120,
          'algebraic',
        ),
        'actor': actor,
        'state_hash': _cleanHash(record['state_hash']?.toString() ?? ''),
      });
    }
    return result;
  }

  String _cleanGameId(String value) {
    final clean = value.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$').hasMatch(clean)) {
      throw const NexusLocalStoreException(
        'game_id_invalid',
        'The saved game id is invalid.',
      );
    }
    return clean;
  }

  int _boundedInt(Object? value, int minimum, int maximum, String field) {
    final parsed = _intValue(value);
    if (parsed < minimum || parsed > maximum) {
      throw NexusLocalStoreException(
        'game_state_invalid',
        'The saved $field is outside the supported range.',
      );
    }
    return parsed;
  }

  NexusModelVerification _modelFromPayload(Map<String, Object?> payload) {
    final value = NexusModelVerification(
      model: _cleanModel(payload['model']),
      sha256: _cleanHash(payload['sha256']?.toString() ?? ''),
      byteLength: _intValue(payload['byte_length']),
      path: _cleanPath(payload['path']?.toString() ?? ''),
      fileSize: _intValue(payload['file_size']),
      modifiedAt: _intValue(payload['modified_at']),
      verifiedAt: _intValue(payload['verified_at']),
    );
    _validateModelVerification(value);
    return value;
  }

  void _validateModelVerification(NexusModelVerification value) {
    if (!_validModelName(value.model) ||
        !_validHash(value.sha256) ||
        value.byteLength < 1 ||
        value.fileSize != value.byteLength ||
        value.modifiedAt < 0 ||
        value.verifiedAt < 1 ||
        value.path.isEmpty ||
        value.path.length > 4096 ||
        value.path.contains('\u0000')) {
      throw const NexusLocalStoreException(
        'model_record_invalid',
        'The local model verification record is invalid.',
      );
    }
  }

  String _cleanSession(String value) {
    final clean = value.trim();
    if (clean.isEmpty ||
        clean.length > _maxSessionCharacters ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$').hasMatch(clean)) {
      throw const NexusLocalStoreException(
        'session_invalid',
        'The local game session id is invalid.',
      );
    }
    return clean;
  }

  String _cleanSpeaker(String value) {
    final clean = value.trim().toUpperCase();
    if (clean != 'YOU' && clean != 'CAISSA' && clean != 'SYSTEM') {
      throw const NexusLocalStoreException(
        'speaker_invalid',
        'The local history speaker is not allowlisted.',
      );
    }
    return clean;
  }

  String _cleanUci(String value) {
    final clean = value.trim().toLowerCase();
    if (!RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$').hasMatch(clean)) {
      throw const NexusLocalStoreException(
        'move_invalid',
        'The local move is not a valid chess action id.',
      );
    }
    return clean;
  }

  String _cleanHash(String value) {
    final clean = value.trim().toLowerCase();
    if (!_validHash(clean)) {
      throw const NexusLocalStoreException(
        'state_invalid',
        'The local state receipt is invalid.',
      );
    }
    return clean;
  }

  List<double> _cleanPositionVector(List<dynamic> value) {
    if (value.length != _positionVectorDimensions) {
      throw const NexusLocalStoreException(
        'position_vector_invalid',
        'The move-memory vector has an invalid length.',
      );
    }
    final result = <double>[];
    for (final component in value) {
      if (component is! num || !component.isFinite) {
        throw const NexusLocalStoreException(
          'position_vector_invalid',
          'The move-memory vector contains a non-finite component.',
        );
      }
      final number = component.toDouble();
      if (number < -1.0 || number > 1.0) {
        throw const NexusLocalStoreException(
          'position_vector_invalid',
          'The move-memory vector contains an out-of-range component.',
        );
      }
      result.add(double.parse(number.toStringAsFixed(8)));
    }
    return result;
  }

  String _cleanQuantumState(String? value) {
    final clean = value?.trim() ?? '';
    final parsed = double.tryParse(clean);
    if (parsed == null ||
        !parsed.isFinite ||
        parsed < 0.0 ||
        parsed > 1.0 ||
        !RegExp(r'^(?:0(?:\.\d{1,8})?|1(?:\.0{1,8})?)$').hasMatch(clean)) {
      throw const NexusLocalStoreException(
        'quantum_state_invalid',
        'The simulated entropy state is invalid.',
      );
    }
    return clean;
  }

  String _cleanSkillColor(String? value) {
    final clean = value?.trim().toLowerCase() ?? '';
    if (!const {
      'red',
      'orange',
      'yellow',
      'green',
      'blue',
      'indigo',
      'violet',
    }.contains(clean)) {
      throw const NexusLocalStoreException(
        'skill_color_invalid',
        'The skill spectrum value is invalid.',
      );
    }
    return clean;
  }

  String _cleanStyleId(String? value) {
    final clean = value?.trim().toLowerCase() ?? '';
    if (!RegExp(r'^[a-z][a-z0-9_-]{0,47}$').hasMatch(clean)) {
      throw const NexusLocalStoreException(
        'style_id_invalid',
        'The playing-style id is invalid.',
      );
    }
    return clean;
  }

  String _cleanPlayerSide(String? value) {
    final clean = value?.trim().toLowerCase() ?? '';
    if (!const {'white', 'black'}.contains(clean)) {
      throw const NexusLocalStoreException(
        'player_side_invalid',
        'The player side is invalid.',
      );
    }
    return clean;
  }

  String _cleanOutcome(String value) {
    final clean = value.trim().toLowerCase();
    if (!const {'pending', 'white_win', 'black_win', 'draw'}.contains(clean)) {
      throw const NexusLocalStoreException(
        'outcome_invalid',
        'The move-memory outcome is invalid.',
      );
    }
    return clean;
  }

  String _cleanGameResult(String value) {
    final clean = value.trim().toLowerCase();
    if (!const {
      'checkmate',
      'stalemate',
      'draw',
      'game complete',
    }.contains(clean)) {
      throw const NexusLocalStoreException(
        'game_result_invalid',
        'The game-memory result is invalid.',
      );
    }
    return clean;
  }

  String _cleanWinner(String value) {
    final clean = value.trim().toLowerCase();
    if (!const {'', 'white', 'black'}.contains(clean)) {
      throw const NexusLocalStoreException(
        'winner_invalid',
        'The game-memory winner is invalid.',
      );
    }
    return clean;
  }

  double _boundedDouble(
    Object? value,
    double minimum,
    double maximum,
    String field,
  ) {
    if (value is! num || !value.isFinite) {
      throw NexusLocalStoreException(
        'number_invalid',
        'The local $field is not finite.',
      );
    }
    final number = value.toDouble();
    if (number < minimum || number > maximum) {
      throw NexusLocalStoreException(
        'number_invalid',
        'The local $field is outside the supported range.',
      );
    }
    return number;
  }

  double _cosineSimilarity(List<double> left, List<double> right) {
    var dot = 0.0;
    var leftNorm = 0.0;
    var rightNorm = 0.0;
    for (var index = 0; index < _positionVectorDimensions; index++) {
      dot += left[index] * right[index];
      leftNorm += left[index] * left[index];
      rightNorm += right[index] * right[index];
    }
    if (leftNorm <= 0.0 || rightNorm <= 0.0) return 0.0;
    return (dot / math.sqrt(leftNorm * rightNorm)).clamp(-1.0, 1.0);
  }

  String _cleanText(String value, int maximum, String field) {
    if (value.isEmpty || value.length > maximum || value.contains('\u0000')) {
      throw NexusLocalStoreException(
        'text_invalid',
        'The local $field is empty, too long, or contains an invalid character.',
      );
    }
    final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final sanitized = normalized
        .replaceAll(
          RegExp(
            r'[\u0001-\u0008\u000B\u000C\u000E-\u001F\u007F\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]',
          ),
          '',
        )
        .trim();
    if (sanitized.isEmpty || sanitized.length > maximum) {
      throw NexusLocalStoreException(
        'text_invalid',
        'The local $field became empty or too long after sanitization.',
      );
    }
    return sanitized;
  }

  String _cleanPath(String value) {
    final clean = value.trim();
    if (clean.isEmpty || clean.length > 4096 || clean.contains('\u0000')) {
      throw const NexusLocalStoreException(
        'path_invalid',
        'The local model path is invalid.',
      );
    }
    return clean;
  }

  String _cleanModel(Object? value) =>
      _cleanText(value?.toString() ?? '', 160, 'model');

  bool _validModelName(String value) =>
      RegExp(r'^[A-Za-z0-9._-]{1,160}$').hasMatch(value);

  bool _validHash(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  Uint8List _recordDigest(String value) {
    final key = _key;
    if (key == null) {
      throw const NexusLocalStoreException(
        'store_locked',
        'The local history store is locked.',
      );
    }
    return Uint8List.fromList(
      crypto.Hmac(
        crypto.sha256,
        key,
      ).convert(utf8.encode('record|$value')).bytes,
    );
  }

  Uint8List _sessionDigest(String value) {
    final key = _key;
    if (key == null) {
      throw const NexusLocalStoreException(
        'store_locked',
        'The local history store is locked.',
      );
    }
    return Uint8List.fromList(
      crypto.Hmac(
        crypto.sha256,
        key,
      ).convert(utf8.encode('session|$value')).bytes,
    );
  }

  List<int> _aad(int category, Uint8List recordId, Uint8List sessionDigest) {
    return utf8.encode(
      'nexus-chess-local-v1|$category|${base64UrlEncode(recordId)}|${base64UrlEncode(sessionDigest)}',
    );
  }

  void _createSchema(sqlite.Database db) {
    if (db.userVersion == 1) {
      _migrateDatabaseV1ToV2(db);
    }
    if (db.userVersion == 2) {
      _migrateDatabaseV2ToV3(db);
    } else if (db.userVersion != 0 && db.userVersion != _databaseVersion) {
      throw NexusLocalStoreException(
        'store_version',
        'Unsupported local history database version ${db.userVersion}.',
      );
    }
    db.execute('''
CREATE TABLE IF NOT EXISTS encrypted_records (
  record_id BLOB PRIMARY KEY NOT NULL CHECK(length(record_id) = 32),
  category INTEGER NOT NULL CHECK(category IN (1, 2, 3, 4, 5)),
  session_id BLOB NOT NULL CHECK(length(session_id) = 32),
  nonce BLOB NOT NULL CHECK(length(nonce) = 12),
  cipher_text BLOB NOT NULL,
  mac BLOB NOT NULL CHECK(length(mac) = 16),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS encrypted_records_session_time
  ON encrypted_records(session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS encrypted_records_category_time
  ON encrypted_records(category, created_at DESC);
''');
    db.userVersion = _databaseVersion;
  }

  void _migrateDatabaseV1ToV2(sqlite.Database db) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('''
CREATE TABLE encrypted_records_v2 (
  record_id BLOB PRIMARY KEY NOT NULL CHECK(length(record_id) = 32),
  category INTEGER NOT NULL CHECK(category IN (1, 2, 3, 4)),
  session_id BLOB NOT NULL CHECK(length(session_id) = 32),
  nonce BLOB NOT NULL CHECK(length(nonce) = 12),
  cipher_text BLOB NOT NULL,
  mac BLOB NOT NULL CHECK(length(mac) = 16),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) WITHOUT ROWID;
INSERT INTO encrypted_records_v2
  (record_id, category, session_id, nonce, cipher_text, mac, created_at, updated_at)
SELECT record_id, category, session_id, nonce, cipher_text, mac, created_at, updated_at
FROM encrypted_records;
DROP TABLE encrypted_records;
ALTER TABLE encrypted_records_v2 RENAME TO encrypted_records;
CREATE INDEX encrypted_records_session_time
  ON encrypted_records(session_id, created_at DESC);
CREATE INDEX encrypted_records_category_time
  ON encrypted_records(category, created_at DESC);
''');
      db.userVersion = 2;
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _migrateDatabaseV2ToV3(sqlite.Database db) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('''
CREATE TABLE encrypted_records_v3 (
  record_id BLOB PRIMARY KEY NOT NULL CHECK(length(record_id) = 32),
  category INTEGER NOT NULL CHECK(category IN (1, 2, 3, 4, 5)),
  session_id BLOB NOT NULL CHECK(length(session_id) = 32),
  nonce BLOB NOT NULL CHECK(length(nonce) = 12),
  cipher_text BLOB NOT NULL,
  mac BLOB NOT NULL CHECK(length(mac) = 16),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) WITHOUT ROWID;
INSERT INTO encrypted_records_v3
  (record_id, category, session_id, nonce, cipher_text, mac, created_at, updated_at)
SELECT record_id, category, session_id, nonce, cipher_text, mac, created_at, updated_at
FROM encrypted_records;
DROP TABLE encrypted_records;
ALTER TABLE encrypted_records_v3 RENAME TO encrypted_records;
CREATE INDEX encrypted_records_session_time
  ON encrypted_records(session_id, created_at DESC);
CREATE INDEX encrypted_records_category_time
  ON encrypted_records(category, created_at DESC);
''');
      db.userVersion = _databaseVersion;
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _configureConnection(sqlite.Database db) {
    db.execute('PRAGMA trusted_schema=OFF');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA secure_delete=ON');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('PRAGMA busy_timeout=5000');
  }

  sqlite.Database _requireDatabase() {
    final db = _database;
    if (db == null) {
      throw const NexusLocalStoreException(
        'store_not_ready',
        'The local history store is not ready.',
      );
    }
    return db;
  }

  Uint8List _randomBytes(int length) {
    final random = math.Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  int _now() => DateTime.now().toUtc().millisecondsSinceEpoch;

  int _intValue(Object? value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '') ?? -1;

  bool _constantTimeEquals(List<int> left, List<int> right) {
    var difference = left.length ^ right.length;
    final length = math.max(left.length, right.length);
    for (var index = 0; index < length; index++) {
      difference |=
          (index < left.length ? left[index] : 0) ^
          (index < right.length ? right[index] : 0);
    }
    return difference == 0;
  }

  void _zero(List<int>? value) {
    if (value == null) return;
    for (var index = 0; index < value.length; index++) {
      value[index] = 0;
    }
  }

  bool _isValidEncodedKey(String? value) {
    if (value == null || value.isEmpty) return false;
    try {
      return base64Url.decode(value).length == 32;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeKeyFile(File file, String encoded) async {
    await file.parent.create(recursive: true);
    final part = File('${file.path}.new');
    if (await part.exists()) await part.delete();
    await part.writeAsString('$encoded\n', flush: true);
    await _harden(file: part);
    if (Platform.isWindows && await file.exists()) await file.delete();
    await part.rename(file.path);
    await _harden(file: file);
  }

  Future<void> _harden({required File file}) async {
    if (Platform.isWindows || !await file.exists()) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {}
  }

  static const _categoryModel = 1;
  static const _categoryConversation = 2;
  static const _categoryMove = 3;
  static const _categoryGame = 4;
  static const _categoryPreferences = 5;
  static final Uint8List _emptySessionDigest = Uint8List(32);
}
