import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_chess_llm/nexus_local_store.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory directory;
  late NexusLocalStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nexus-chess-store-');
    store = NexusLocalStore.forTesting(directory);
    await store.initialize();
  });

  tearDown(() async {
    await store.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'stores model identity and history in authenticated encrypted rows',
    () async {
      const secretMessage = 'private position explanation';
      final modelHash = 'a' * 64;
      await store.writeModelVerification(
        NexusModelVerification(
          model: 'gemma-4-E2B-it.litertlm',
          sha256: modelHash,
          byteLength: 128,
          path: '/tmp/gemma-4-E2B-it.litertlm',
          fileSize: 128,
          modifiedAt: 42,
          verifiedAt: 43,
        ),
      );
      await store.appendConversation(
        sessionId: 'game-1',
        speaker: 'YOU',
        message: secretMessage,
      );
      await store.appendMove(
        sessionId: 'game-1',
        ply: 1,
        actor: 'YOU',
        uci: 'e2e4',
        algebraic: 'Pe2-e4',
        stateHash: modelHash,
      );

      final verification = await store.readModelVerification();
      expect(verification?.sha256, modelHash);
      final history = await store.recentHistory(sessionId: 'game-1');
      expect(history, hasLength(2));
      expect(history.first['message'], secretMessage);
      expect(history.last['uci'], 'e2e4');

      final raw = latin1.decode(
        await File('${directory.path}/nexus_chess_local.sqlite3').readAsBytes(),
        allowInvalid: true,
      );
      expect(raw, isNot(contains(secretMessage)));
      expect(raw, isNot(contains('game-1')));
      expect(raw, isNot(contains('e2e4')));
    },
  );

  test('rejects malformed history before it reaches SQLite', () {
    expect(
      () => store.appendConversation(
        sessionId: 'bad session',
        speaker: 'YOU',
        message: 'hello',
      ),
      throwsA(isA<NexusLocalStoreException>()),
    );
    expect(
      () => store.appendMove(
        sessionId: 'game-1',
        ply: 1,
        actor: 'YOU',
        uci: 'e9e4',
        algebraic: 'bad',
        stateHash: 'b' * 64,
      ),
      throwsA(isA<NexusLocalStoreException>()),
    );
  });

  test(
    'fails closed when an existing database loses its protected key',
    () async {
      final isolatedDirectory = await Directory.systemTemp.createTemp(
        'nexus-chess-key-',
      );
      final keyProvider = NexusMemoryStoreKeyProvider();
      final first = NexusLocalStore.forTesting(
        isolatedDirectory,
        keyProvider: keyProvider,
      );
      await first.initialize();
      await first.appendConversation(
        sessionId: 'game-2',
        speaker: 'CAISSA',
        message: 'stored',
      );
      await first.close();
      await File('${isolatedDirectory.path}/nexus_chess_local.key').delete();

      final second = NexusLocalStore.forTesting(
        isolatedDirectory,
        keyProvider: NexusMemoryStoreKeyProvider(),
      );
      await expectLater(
        second.initialize(),
        throwsA(
          isA<NexusLocalStoreException>().having(
            (error) => error.code,
            'code',
            'store_key_missing',
          ),
        ),
      );
      await second.close();
      await isolatedDirectory.delete(recursive: true);
    },
  );

  test('does not accept malformed model verification payloads', () async {
    expect(
      () => store.writeModelVerification(
        const NexusModelVerification(
          model: 'gemma',
          sha256: 'not-a-hash',
          byteLength: 4,
          path: '/tmp/model',
          fileSize: 4,
          modifiedAt: 1,
          verifiedAt: 2,
        ),
      ),
      throwsA(isA<NexusLocalStoreException>()),
    );
    expect(utf8.encode('sanitization'), isNotEmpty);
  });

  test('saves, lists, loads, and deletes a sanitized game snapshot', () async {
    final board = List<String>.filled(64, '');
    board[60] = 'wK';
    board[4] = 'bK';
    final state = <String, dynamic>{
      'revision': 0,
      'players': {'white': 'YOU', 'black': 'CAISSA'},
      'turn': 'white',
      'board': board,
      'castling': {
        'white_kingside': true,
        'white_queenside': true,
        'black_kingside': true,
        'black_queenside': true,
      },
      'en_passant': -1,
      'halfmove_clock': 0,
      'fullmove_number': 1,
      'status': 'active',
      'winner': '',
      'winner_player': '',
      'result': '',
      'check': false,
    };
    await store.saveGame(
      gameId: 'game-slot-1',
      name: 'Quiet opening',
      sessionId: 'game-1',
      state: state,
      history: const [],
    );
    expect((await store.listGames()).single['name'], 'Quiet opening');
    final loaded = await store.loadGame('game-slot-1');
    expect(loaded?['name'], 'Quiet opening');
    expect((loaded?['state'] as Map)['board'], board);
    await store.deleteGame('game-slot-1');
    expect(await store.listGames(), isEmpty);
  });

  test(
    'recalls encrypted move vectors and applies final game reward',
    () async {
      final vector = List<double>.generate(32, (index) => index / 64.0);
      await store.appendMove(
        sessionId: 'past-game',
        ply: 1,
        actor: 'CAISSA',
        uci: 'e7e5',
        algebraic: 'Pe7-e5',
        stateHash: 'c' * 64,
        positionVector: vector,
        quantumState: '0.62500000',
        skillColor: 'yellow',
        styleId: 'adaptive',
      );
      await store.finalizeGameMemory(
        sessionId: 'past-game',
        result: 'checkmate',
        winner: 'black',
      );
      final recalled = await store.recallMoves(
        sessionId: 'current-game',
        positionVector: vector,
        limit: 8,
      );
      expect(recalled, hasLength(1));
      expect(recalled.single['uci'], 'e7e5');
      expect(recalled.single['similarity'], closeTo(1.0, 0.000001));
      expect(recalled.single['outcome'], 'black_win');
      expect(recalled.single['reward'], 1.0);
      expect(
        await store.recallMoves(sessionId: 'past-game', positionVector: vector),
        isEmpty,
      );
    },
  );

  test('persists sanitized agent preferences in the protected store', () async {
    expect(await store.readAgentPreferences(), {
      'memory_enabled': true,
      'skill_color': 'yellow',
      'style_id': 'adaptive',
      'player_side': 'white',
    });
    await store.writeAgentPreferences(
      memoryEnabled: false,
      skillColor: 'blue',
      styleId: 'capablanca',
      playerSide: 'black',
    );
    expect(await store.readAgentPreferences(), {
      'memory_enabled': false,
      'skill_color': 'blue',
      'style_id': 'capablanca',
      'player_side': 'black',
    });
  });

  test('migrates the earlier history schema without dropping rows', () async {
    final isolated = await Directory.systemTemp.createTemp(
      'nexus-chess-migrate-',
    );
    final keyProvider = NexusMemoryStoreKeyProvider();
    await keyProvider.write(
      'nexus-chess-local-store-key-v1',
      base64UrlEncode(List<int>.filled(32, 7)),
    );
    final database = sqlite.sqlite3.open(
      '${isolated.path}/nexus_chess_local.sqlite3',
    );
    database.execute('''
CREATE TABLE encrypted_records (
  record_id BLOB PRIMARY KEY NOT NULL CHECK(length(record_id) = 32),
  category INTEGER NOT NULL CHECK(category IN (1, 2, 3)),
  session_id BLOB NOT NULL CHECK(length(session_id) = 32),
  nonce BLOB NOT NULL CHECK(length(nonce) = 12),
  cipher_text BLOB NOT NULL,
  mac BLOB NOT NULL CHECK(length(mac) = 16),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) WITHOUT ROWID;
''');
    database.userVersion = 1;
    database.close();
    final migrated = NexusLocalStore.forTesting(
      isolated,
      keyProvider: keyProvider,
    );
    await migrated.initialize();
    await migrated.close();
    final reopened = sqlite.sqlite3.open(
      '${isolated.path}/nexus_chess_local.sqlite3',
    );
    expect(reopened.userVersion, 3);
    reopened.close();
    await isolated.delete(recursive: true);
  });
}
