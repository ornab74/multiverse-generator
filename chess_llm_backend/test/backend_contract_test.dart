import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_chess_llm/backend_contract.dart';

void main() {
  group('bearer authentication', () {
    test('accepts only bounded RFC 6750 token characters', () {
      expect(isValidBearerToken('a' * 32), isTrue);
      expect(isValidBearerToken('A0-._~+/b' * 20), isTrue);
      expect(isValidBearerToken('${'x' * 31}='), isTrue);
      expect(isValidBearerToken('a' * 31), isFalse);
      expect(isValidBearerToken('a' * 257), isFalse);
      expect(isValidBearerToken('${'a' * 31} '), isFalse);
      expect(isValidBearerToken('${'a' * 31}\n'), isFalse);
      expect(isValidBearerToken('${'a' * 31}☃'), isFalse);
      expect(isValidBearerToken('${'a' * 30}=a'), isFalse);
      expect(isValidBearerToken('=' * 32), isFalse);
    });

    test('compares the complete authorization value', () {
      const token = '0123456789abcdef0123456789abcdef';
      expect(constantTimeEquals('Bearer $token', 'Bearer $token'), isTrue);
      expect(constantTimeEquals('bearer $token', 'Bearer $token'), isFalse);
      expect(constantTimeEquals('Bearer ${token}0', 'Bearer $token'), isFalse);
      expect(constantTimeEquals('', 'Bearer $token'), isFalse);
      expect(isAuthorizedBearerHeader('Bearer $token', token), isTrue);
      expect(isAuthorizedBearerHeader(null, token), isFalse);
      expect(isAuthorizedBearerHeader('bearer $token', token), isFalse);
      expect(isAuthorizedBearerHeader('Bearer ${token}0', token), isFalse);
      expect(isAuthorizedBearerHeader('Bearer short', 'short'), isFalse);
    });
  });

  group('server configuration', () {
    test('accepts only a valid TCP port', () {
      expect(configuredServerPort(null), 47621);
      expect(configuredServerPort(' 48123 '), 48123);
      expect(() => configuredServerPort('0'), throwsFormatException);
      expect(() => configuredServerPort('65536'), throwsFormatException);
      expect(() => configuredServerPort('not-a-port'), throwsFormatException);
    });
  });

  group('CPU-only contract', () {
    test('never advertises a GPU inference path', () {
      expect(cpuOnlyReport, const <String, Object>{
        'local_only': true,
        'inference_backend': 'cpu',
        'gpu_inference_allowed': false,
      });
    });
  });

  group('pinned model identity', () {
    test('requires the exact known byte length', () {
      expect(modelRepository, 'litert-community/gemma-4-E2B-it-litert-lm');
      expect(modelRevision, hasLength(40));
      expect(modelRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(modelUrl, contains('/resolve/$modelRevision/$modelName'));
      expect(modelByteLength, 2583085056);
      expect(hasExactModelByteLength(modelByteLength), isTrue);
      expect(hasExactModelByteLength(modelByteLength - 1), isFalse);
      expect(hasExactModelByteLength(modelByteLength + 1), isFalse);
      expect(modelSha256, hasLength(64));
      expect(modelSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('resolves configured files and directories deterministically', () {
      expect(
        configuredModelPath('/opt/nexus/models'),
        '/opt/nexus/models/$modelName',
      );
      expect(
        configuredModelPath('/opt/nexus/models///'),
        '/opt/nexus/models/$modelName',
      );
      expect(
        configuredModelPath(' /tmp/custom.LITERTLM '),
        '/tmp/custom.LITERTLM',
      );
      expect(configuredModelPath('/'), '/$modelName');
      expect(
        configuredModelPath('C:\\models\\', pathSeparator: '\\'),
        'C:\\models\\gemma-4-E2B-it.litertlm',
      );
      expect(() => configuredModelPath('   '), throwsFormatException);
      expect(() => configuredModelPath('bad\u0000path'), throwsFormatException);
    });

    test('allows only credential-free HTTPS model hosts', () {
      expect(isAllowedModelUri(Uri.parse(modelUrl)), isTrue);
      expect(
        isAllowedModelUri(
          Uri.parse('https://cdn-lfs.huggingface.co/model.bin'),
        ),
        isTrue,
      );
      expect(
        isAllowedModelUri(
          Uri.parse('https://cas-bridge.xethub.hf.co/blob?token=signed'),
        ),
        isTrue,
      );
      expect(
        isAllowedModelUri(
          Uri.parse('https://us.aws.cdn.hf.co/blob?token=signed'),
        ),
        isTrue,
      );
      expect(
        isAllowedModelUri(Uri.parse('http://huggingface.co/model')),
        isFalse,
      );
      expect(
        isAllowedModelUri(Uri.parse('https://evil-huggingface.co/model')),
        isFalse,
      );
      expect(
        isAllowedModelUri(Uri.parse('https://cdn.hf.co.evil.example/model')),
        isFalse,
      );
      expect(
        isAllowedModelUri(Uri.parse('https://user@huggingface.co/model')),
        isFalse,
      );
      expect(
        isAllowedModelUri(Uri.parse('https://huggingface.co:8443/model')),
        isFalse,
      );
      expect(
        isAllowedModelUri(Uri.parse('https://huggingface.co/model#fragment')),
        isFalse,
      );
    });

    test('accepts only canonical bounded Content-Range responses', () {
      expect(parseContentRange('bytes 1048576-2583085055/2583085056'), (
        start: 1048576,
        end: 2583085055,
        total: 2583085056,
      ));
      expect(parseContentRange('bytes */2583085056'), isNull);
      expect(parseContentRange('bytes 9-8/10'), isNull);
      expect(parseContentRange('bytes 0-10/10'), isNull);
      expect(parseContentRange('items 0-9/10'), isNull);
      expect(parseContentRange(null), isNull);
    });
  });

  group('request validation', () {
    test('accepts a trimmed prompt and bounded token request', () {
      expect(validatedPrompt(<String, dynamic>{'prompt': '  e4  '}), 'e4');
      expect(
        validatedPrompt(<String, dynamic>{'message': 'position?'}),
        'position?',
      );
      expect(normalizedMaxOutputTokens(null), 512);
      expect(normalizedMaxOutputTokens('128'), 512);
      expect(normalizedMaxOutputTokens(-1), 16);
      expect(normalizedMaxOutputTokens(128), 128);
      expect(normalizedMaxOutputTokens(5000), 768);
      expect(normalizedTemperature(0.48), 0.48);
      expect(normalizedTemperature(9.0), 0.9);
      expect(normalizedTopK(2), 4);
      expect(normalizedTopK(32), 32);
      expect(normalizedTopP(0.2), 0.55);
      expect(normalizedRandomSeed(1467), 1467);
    });

    test('rejects empty and oversized prompts', () {
      expect(
        () => validatedPrompt(<String, dynamic>{'prompt': '  '}),
        throwsA(
          isA<RequestFailure>().having(
            (failure) => failure.code,
            'code',
            'prompt_invalid',
          ),
        ),
      );
      expect(
        () => validatedPrompt(<String, dynamic>{
          'prompt': 'x' * (maxPromptCharacters + 1),
        }),
        throwsA(isA<RequestFailure>()),
      );
      expect(
        () => validatedPrompt(<String, dynamic>{'prompt': 42}),
        throwsA(isA<RequestFailure>()),
      );
    });

    test('decodes only UTF-8 JSON objects', () {
      expect(decodeJsonObject(const <int>[]), isEmpty);
      expect(
        decodeJsonObject(utf8.encode('{"prompt":"e4"}')),
        <String, dynamic>{'prompt': 'e4'},
      );
      expect(
        () => decodeJsonObject(const <int>[0xc3, 0x28]),
        throwsA(
          isA<RequestFailure>().having(
            (failure) => failure.code,
            'code',
            'json_invalid',
          ),
        ),
      );
      expect(
        () => decodeJsonObject(utf8.encode('[1,2,3]')),
        throwsA(
          isA<RequestFailure>().having(
            (failure) => failure.code,
            'code',
            'json_object_required',
          ),
        ),
      );
    });

    test(
      'validates fixed move vectors, memory operations, and preferences',
      () {
        final vector = List<double>.filled(positionVectorDimensions, 0.25);
        expect(validatedPositionVector(vector), vector);
        expect(
          () => validatedPositionVector(List<double>.filled(31, 0.0)),
          throwsA(isA<RequestFailure>()),
        );
        final recalled = validatedHistoryRequest(<String, dynamic>{
          'operation': 'recall_moves',
          'session_id': 'game-1',
          'position_vector': vector,
          'limit': 16,
        });
        expect(recalled['position_vector'], vector);
        final finalized = validatedHistoryRequest(<String, dynamic>{
          'operation': 'finalize_game',
          'session_id': 'game-1',
          'result': 'checkmate',
          'winner': 'black',
        });
        expect(finalized['winner'], 'black');
        final preferences = validatedPreferencesRequest(<String, dynamic>{
          'operation': 'set',
          'memory_enabled': true,
          'skill_color': 'yellow',
          'style_id': 'tal',
          'player_side': 'black',
        });
        expect(preferences['style_id'], 'tal');
        expect(preferences['player_side'], 'black');
        expect(
          () => validatedPreferencesRequest(<String, dynamic>{
            'operation': 'set',
            'memory_enabled': true,
            'skill_color': 'ultraviolet',
            'style_id': 'tal',
            'player_side': 'white',
          }),
          throwsA(isA<RequestFailure>()),
        );
      },
    );
  });
}
