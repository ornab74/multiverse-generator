// Loopback-only Gemma sidecar for the Godot LLM Arena.
// Run with: flutter run -d linux --target tool/godot_agent_bridge.dart
// The endpoint never accepts arbitrary files, code, private keys, or remote hosts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:naza_one/main.dart' as app;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final port =
      int.tryParse(Platform.environment['NAZA_GODOT_BRIDGE_PORT'] ?? '') ??
      47621;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('NAZA_GODOT_BRIDGE_READY http://127.0.0.1:$port');
  unawaited(_warmGemma());
  await for (final request in server) {
    await _handle(request);
  }
}

Future<void> _handle(HttpRequest request) async {
  request.response.headers.contentType = ContentType.json;
  request.response.headers.set(
    'Access-Control-Allow-Origin',
    'http://127.0.0.1',
  );
  if (request.method != 'POST') {
    request.response.statusCode = HttpStatus.methodNotAllowed;
    request.response.write(jsonEncode({'ok': false, 'code': 'post_required'}));
    await request.response.close();
    return;
  }
  final raw = await utf8.decoder.bind(request).join();
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    await _write(request, {
      'ok': false,
      'code': 'json_object_required',
    }, HttpStatus.badRequest);
    return;
  }
  try {
    if (request.uri.path == '/health') {
      final runtime = app.NazaLocalGemma.instance.snapshot.value;
      await _write(request, {
        'ok': runtime.modelLoaded,
        'service': 'naza-flutter-gemma4',
        'local_only': true,
        'inference_backend': 'cpu',
        'model_ready': runtime.modelLoaded,
        'phase': runtime.phase,
        'error': runtime.error,
        'schema': 'naza.godot-bridge/1',
      });
      return;
    }
    if (request.uri.path != '/v1/agent/turn' &&
        request.uri.path != '/v1/chat') {
      await _write(request, {
        'ok': false,
        'code': 'route_not_found',
      }, HttpStatus.notFound);
      return;
    }
    final map = Map<String, dynamic>.from(decoded);
    final prompt = (map['prompt'] ?? map['message'] ?? '').toString().trim();
    if (prompt.isEmpty || prompt.length > 24000) {
      await _write(request, {
        'ok': false,
        'code': 'prompt_invalid',
      }, HttpStatus.badRequest);
      return;
    }
    final response = await app.NazaLocalGemma.instance.send(
      prompt,
      useMemory: false,
      persistTurn: false,
      maxContinuationsOverride: 0,
      systemInstructionOverride: app.NazaAppConfig.systemInstruction,
    );
    await _write(request, {
      'ok': true,
      'text': response.text,
      'route': response.route,
      'local_only': true,
      'model': app.NazaAppConfig.modelFileName,
      'sha256': app.NazaAppConfig.modelSha256,
    });
  } catch (error) {
    await _write(request, {
      'ok': false,
      'code': 'local_model_error',
      'error': '$error',
    }, HttpStatus.serviceUnavailable);
  }
}

Future<void> _warmGemma() async {
  try {
    await app.NazaLocalGemma.instance.ensureReadyForHeadlessBridge(
      cpuOnly: true,
    );
  } catch (error) {
    stderr.writeln('NAZA_GODOT_BRIDGE_MODEL_WARMUP_FAILED $error');
  }
}

Future<void> _write(
  HttpRequest request,
  Map<String, dynamic> body, [
  int status = HttpStatus.ok,
]) async {
  request.response.statusCode = status;
  request.response.write(jsonEncode(body));
  await request.response.close();
}
