import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hengyang_web/main.dart';
import 'package:hengyang_web/telemetry_stream.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('native API retains session and sends origin for protected requests',
      () async {
    final token = 'a' * 64;
    final requests = <http.Request>[];
    final api = Api(client: MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/login')) {
        return http.Response('{"username":"admin","must_change":false}', 200,
            headers: {
              'set-cookie': 'hengyang_session=$token; Secure; HttpOnly'
            });
      }
      if (request.url.path.endsWith('/password')) {
        return http.Response('{"error":"incorrect"}', 401);
      }
      if (request.url.path.endsWith('/logout')) return http.Response('', 204);
      return http.Response('[]', 200);
    }));
    await api.request('POST', '/login', {});
    await expectLater(
        api.request('POST', '/password', {}), throwsA(isA<ApiException>()));
    await api.request('GET', '/devices');
    await api.request('POST', '/logout');
    await api.request('GET', '/devices');
    expect(requests[0].url.origin, Api.origin);
    expect(requests[0].headers['origin'], Api.origin);
    expect(requests[1].headers['cookie'], 'hengyang_session=$token');
    expect(requests[2].headers['cookie'], 'hengyang_session=$token');
    expect(requests[4].headers['cookie'], isNull);
  });

  testWidgets('telemetry updates devices and reconnect refreshes after failure',
      (tester) async {
    late void Function() fireOpen, fireUpdate, fireError;
    var volume = 20;
    final api = Api(client: MockClient((request) async {
      switch (request.url.path) {
        case '/api/v1/models':
          return http.Response(
              '[{"id":1,"name":"model","fields":["volume"],"commands":[]}]',
              200);
        case '/api/v1/devices':
          return http.Response(
              jsonEncode([
                {
                  'imei': '123456789012345',
                  'name': 'device',
                  'model_id': 1,
                  'status': {'volume': volume}
                }
              ]),
              200);
        case '/api/v1/settings':
          return http.Response('{"latitude":37.76,"longitude":117.58}', 200);
        default:
          return http.Response('not found', 404);
      }
    }));
    await tester.pumpWidget(MaterialApp(
      home: Dashboard(
        api: api,
        onLogout: () {},
        createTelemetryStream: (
            {required onOpen, required onUpdate, required onError}) {
          fireOpen = onOpen;
          fireUpdate = onUpdate;
          fireError = onError;
          return TelemetryStream(
              onOpen: onOpen, onUpdate: onUpdate, onError: onError);
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('设备上报音量：20'), findsOneWidget);
    fireOpen();
    await tester.pumpAndSettle();
    volume = 40;
    fireUpdate();
    await tester.pumpAndSettle();
    expect(find.textContaining('设备上报音量：40'), findsOneWidget);
    fireError();
    await tester.pumpAndSettle();
    expect(find.textContaining('遥测连接中断'), findsOneWidget);
    volume = 70;
    fireOpen();
    await tester.pumpAndSettle();
    expect(find.textContaining('设备上报音量：70'), findsOneWidget);
    expect(find.textContaining('遥测连接中断'), findsNothing);
  });

  testWidgets('login sends credentials and returns session', (tester) async {
    Map<String, dynamic>? session;
    final api = Api(client: MockClient((request) async {
      expect(request.url.path, '/api/v1/login');
      expect(
          jsonDecode(request.body), {'username': 'admin', 'password': 'admin'});
      return http.Response(
          '{"username":"admin","must_change":true}', 200, headers: {
        'set-cookie': 'hengyang_session=${'a' * 64}; Path=/; Secure; HttpOnly'
      });
    }));
    await tester.pumpWidget(MaterialApp(
      home: LoginPage(api: api, onLogin: (value, _) => session = value),
    ));
    await tester.enterText(find.byType(TextField).last, 'admin');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(session?['must_change'], true);
  });

  testWidgets('coordinates reject out of range values', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home:
          Scaffold(body: CoordinatesDialog(latitude: 37.76, longitude: 117.58)),
    ));
    await tester.enterText(find.byType(TextField).first, '181');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的 WGS-84 经纬度'), findsOneWidget);
  });

  testWidgets('change password requires a successful login', (tester) async {
    bool? changeRequested;
    final api = Api(client: MockClient((request) async {
      expect(request.url.path, '/api/v1/login');
      return http.Response(
          '{"username":"admin","must_change":false}', 200, headers: {
        'set-cookie': 'hengyang_session=${'a' * 64}; Path=/; Secure; HttpOnly'
      });
    }));
    await tester.pumpWidget(MaterialApp(
      home: LoginPage(
          api: api,
          onLogin: (_, changePassword) => changeRequested = changePassword),
    ));
    await tester.tap(find.text('忘记密码？'));
    await tester.pumpAndSettle();
    expect(find.text('请先验证账号和当前密码'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'old-password');
    await tester.tap(find.text('验证并继续'));
    await tester.pumpAndSettle();
    expect(changeRequested, true);
  });

  testWidgets(
      'volume slider sends selected value without changing reported value',
      (tester) async {
    int? sent;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body:
            VolumeControl(reported: 60, onSend: (value) async => sent = value),
      ),
    ));
    await tester.drag(find.byType(Slider), const Offset(100, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置音量'));
    await tester.pump(const Duration(milliseconds: 201));
    expect(sent, greaterThan(60));
    expect(find.textContaining('设备上报音量：60'), findsOneWidget);
  });

  testWidgets('command button blocks repeats for 200 ms and until completion',
      (tester) async {
    final pending = Completer<void>();
    var count = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CommandButton(
          onPressed: () {
            count++;
            return count == 1 ? Future.value() : pending.future;
          },
          child: const Text('PLAY'),
        ),
      ),
    ));
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    expect(count, 1);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull);
    await tester.pump(const Duration(milliseconds: 199));
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNotNull);
    await tester.tap(find.text('PLAY'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(count, 2);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull);
    pending.complete();
    await tester.pump();
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNotNull);
  });

  testWidgets('device command is sent directly without confirmation',
      (tester) async {
    var sent = 0;
    final api = Api(client: MockClient((request) async {
      switch (request.url.path) {
        case '/api/v1/models':
          return http.Response(
              '[{"id":1,"name":"model","fields":[],"commands":["PLAY"]}]', 200);
        case '/api/v1/devices':
          return http.Response(
              '[{"imei":"123456789012345","name":"device","model_id":1}]', 200);
        case '/api/v1/settings':
          return http.Response('{"latitude":37.76,"longitude":117.58}', 200);
        case '/api/v1/devices/123456789012345/commands':
          sent++;
          expect(jsonDecode(request.body), {'command': 'PLAY'});
          return http.Response('{"status":"published"}', 202);
        default:
          return http.Response('not found', 404);
      }
    }));
    await tester.pumpWidget(MaterialApp(
      home: Dashboard(api: api, onLogout: () {}),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    expect(sent, 1);
    expect(find.text('确认下发命令'), findsNothing);
    expect(find.text('命令已发布'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 201));
  });

  testWidgets(
      'player requests the device playlist and sends the selected index',
      (tester) async {
    final api = Api(client: MockClient((request) async {
      switch (request.url.path) {
        case '/api/v1/models':
          return http.Response(
              '[{"id":1,"name":"model","fields":["volume"],"commands":["PLAY","PAUSE","SET_VOLUME"]}]',
              200);
        case '/api/v1/devices':
          return http.Response(
              '[{"imei":"123456789012345","name":"device","model_id":1,"status":{"playing":true,"trackId":1,"trackName":"第一首","volume":60}}]',
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        case '/api/v1/settings':
          return http.Response('{"latitude":37.76,"longitude":117.58}', 200);
        case '/api/v1/devices/123456789012345/playlist':
          expect(request.method, 'POST');
          expect(jsonDecode(request.body), {'offset': 0});
          return http.Response(
              '{"offset":0,"total":2,"items":[{"index":0,"name":"第一首"},{"index":1,"name":"第二首"}]}',
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        case '/api/v1/devices/123456789012345/commands':
          expect(
              jsonDecode(request.body), {'command': 'PLAY', 'song_index': 1});
          return http.Response('{"status":"published"}', 202);
        default:
          return http.Response('not found', 404);
      }
    }));
    await tester
        .pumpWidget(MaterialApp(home: Dashboard(api: api, onLogout: () {})));
    await tester.pumpAndSettle();
    final music = find.byType(DevicePlayer);
    expect(find.descendant(of: music, matching: find.text('音乐播放')),
        findsOneWidget);
    expect(find.descendant(of: music, matching: find.byType(VolumeControl)),
        findsOneWidget);
    expect(find.text('volume：60'), findsNothing);
    expect(find.byTooltip('暂停'), findsOneWidget);
    await tester.tap(find.text('获取歌单'));
    await tester.pumpAndSettle();
    final firstSong = find.widgetWithText(ListTile, '第一首');
    expect(tester.widget<ListTile>(firstSong).selected, isTrue);
    final secondSong = find.widgetWithText(ListTile, '第二首');
    final playSong =
        find.descendant(of: secondSong, matching: find.byTooltip('播放此曲'));
    await tester.ensureVisible(playSong);
    await tester.pumpAndSettle();
    await tester.tap(playSong);
    await tester.pump(const Duration(milliseconds: 201));
    expect(find.text('命令已发布'), findsOneWidget);
    expect(tester.widget<ListTile>(firstSong).selected, isTrue);
  });

  testWidgets('ultrasonic toggles follow telemetry and send distinct commands',
      (tester) async {
    final sent = <String>[];
    var status = <String, Object>{};
    final api = Api(client: MockClient((request) async {
      switch (request.url.path) {
        case '/api/v1/models':
          return http.Response(
              jsonEncode([
                {
                  'id': 1,
                  'name': 'model',
                  'fields': ['ultrasonicMode', 'ultrasonicPlaying'],
                  'commands': ['PLAY', ...ultrasonicCommands.keys]
                }
              ]),
              200);
        case '/api/v1/devices':
          return http.Response(
              jsonEncode([
                {
                  'imei': '123456789012345',
                  'name': 'device',
                  'model_id': 1,
                  'status': status
                }
              ]),
              200);
        case '/api/v1/settings':
          return http.Response('{"latitude":37.76,"longitude":117.58}', 200);
        case '/api/v1/devices/123456789012345/commands':
          sent.add(jsonDecode(request.body)['command'] as String);
          return http.Response('{"status":"published"}', 202);
        default:
          return http.Response('not found', 404);
      }
    }));
    await tester
        .pumpWidget(MaterialApp(home: Dashboard(api: api, onLogout: () {})));
    await tester.pumpAndSettle();
    final ultrasonic = find.byType(UltrasonicControl);
    final modeSwitch = find.byType(SegmentedButton<String>);
    Set<String> selectedMode() =>
        tester.widget<SegmentedButton<String>>(modeSwitch).selected;
    expect(ultrasonic, findsOneWidget);
    expect(find.descendant(of: find.byType(DevicePlayer), matching: ultrasonic),
        findsNothing);
    expect(find.text('超声状态：未知；模式：未知'), findsOneWidget);
    expect(selectedMode(), isEmpty);
    expect(find.text('暂停超声'), findsNothing);
    await tester.tap(find.text('播放超声'));
    await tester.pump(const Duration(milliseconds: 201));
    expect(sent, ['ULTRASONIC_PLAY']);
    expect(find.text('播放超声'), findsOneWidget);
    await tester.tap(find.text('扫频'));
    await tester.pump();
    expect(
        tester.widget<SegmentedButton<String>>(modeSwitch).onSelectionChanged,
        isNull);
    await tester.pump(const Duration(milliseconds: 201));
    expect(sent, ['ULTRASONIC_PLAY', 'ULTRASONIC_SWEEP']);
    expect(selectedMode(), isEmpty);

    status = {'ultrasonicPlaying': true, 'ultrasonicMode': 'sweep'};
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(selectedMode(), {'sweep'});
    expect(find.text('超声状态：播放中；模式：扫频 20–50 kHz'), findsOneWidget);
    expect(find.text('ultrasonicMode：sweep'), findsNothing);
    expect(find.text('播放超声'), findsNothing);
    await tester.ensureVisible(find.text('暂停超声'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停超声'));
    await tester.pump(const Duration(milliseconds: 201));
    await tester.tap(find.text('定频'));
    await tester.pump(const Duration(milliseconds: 201));
    expect(sent, [
      'ULTRASONIC_PLAY',
      'ULTRASONIC_SWEEP',
      'ULTRASONIC_STOP',
      'ULTRASONIC_FIXED'
    ]);
    expect(selectedMode(), {'sweep'});
    expect(find.text('暂停超声'), findsOneWidget);

    status = {'ultrasonicPlaying': false, 'ultrasonicMode': 'fixed'};
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(selectedMode(), {'fixed'});
    expect(find.text('超声状态：已停止；模式：定频 25 kHz'), findsOneWidget);
    expect(find.text('播放超声'), findsOneWidget);
  });

  testWidgets('model ultrasonic checkbox adds and removes command bundle',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: ModelDialog())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用超声控制'));
    await tester.pump();
    final commandField = tester.widget<TextField>(find.byType(TextField).last);
    expect(
        ultrasonicCommands.keys.every(commandField.controller!.text.contains),
        isTrue);
    await tester.tap(find.text('启用超声控制'));
    await tester.pump();
    expect(ultrasonicCommands.keys.any(commandField.controller!.text.contains),
        isFalse);
  });

  testWidgets('map zoom controls change the zoom level', (tester) async {
    final api = Api(client: MockClient((request) async {
      switch (request.url.path) {
        case '/api/v1/models':
        case '/api/v1/devices':
          return http.Response('[]', 200);
        case '/api/v1/settings':
          return http.Response('{"latitude":37.76,"longitude":117.58}', 200);
        default:
          return http.Response('not found', 404);
      }
    }));
    await tester.pumpWidget(MaterialApp(
      home: Dashboard(api: api, onLogout: () {}),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('地图'));
    await tester.pump();
    expect(find.byTooltip('放大地图'), findsOneWidget);
    final controller =
        tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!;
    expect(controller.camera.zoom, 11);
    await tester.tap(find.byTooltip('放大地图'));
    await tester.pump();
    expect(controller.camera.zoom, 12);
    await tester.tap(find.byTooltip('缩小地图'));
    await tester.pump();
    expect(controller.camera.zoom, 11);
    expect(tester.takeException(), isNull);
  });

  test('telemetry time uses local time without ISO separators', () {
    final value = formatTelemetryTime('2026-11-18T01:27:58Z');
    expect(value, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')));
    expect(formatTelemetryTime('bad timestamp'), '时间无效');
  });

  test('API reports server errors', () async {
    final api = Api(
        client:
            MockClient((_) async => http.Response('{"error":"expired"}', 401)));
    await expectLater(api.request('GET', '/session'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
  });
}
