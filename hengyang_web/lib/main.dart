import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'telemetry_stream.dart';

const ultrasonicCommands = {
  'ULTRASONIC_PLAY': '超声播放',
  'ULTRASONIC_STOP': '超声停止',
  'ULTRASONIC_SWEEP': '扫频 20–50 kHz',
  'ULTRASONIC_FIXED': '定频 25 kHz',
};
const musicCommands = {'PLAY', 'PAUSE', 'NEXT', 'PREV'};

void main() => runApp(const HengyangApp());

class ApiException implements Exception {
  ApiException(this.message, this.status);
  final String message;
  final int status;
  @override
  String toString() => message;
}

class Api {
  Api({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  static const origin = 'https://iot.hengyanghk.com';
  String? _sessionCookie;

  Uri uri(String path) => Uri.parse('${kIsWeb ? '' : origin}/api/v1$path');

  Future<dynamic> request(String method, String path, [Object? data]) async {
    final request = http.Request(method, uri(path));
    if (!kIsWeb) request.followRedirects = false;
    if (!kIsWeb) {
      if (_sessionCookie != null) {
        request.headers['Cookie'] = _sessionCookie!;
      }
      if (method != 'GET') request.headers['Origin'] = origin;
    }
    if (data != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(data);
    }
    final response = await http.Response.fromStream(await client.send(request));
    if (!kIsWeb && path == '/login' && response.statusCode == 200) {
      final match = RegExp(r'(?:^|,\s*)hengyang_session=([0-9a-f]{64})(?:;|$)')
          .firstMatch(response.headers['set-cookie'] ?? '');
      if (match == null) {
        throw ApiException('登录成功但未收到有效会话', response.statusCode);
      }
      _sessionCookie = 'hengyang_session=${match[1]}';
    }
    if (!kIsWeb &&
        ((response.statusCode == 401 &&
                path != '/login' &&
                path != '/password') ||
            (path == '/logout' && response.statusCode == 204))) {
      _sessionCookie = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = '请求失败（${response.statusCode}）';
      try {
        message = (jsonDecode(response.body) as Map<String, dynamic>)['error']
                as String? ??
            message;
      } on FormatException {
        // Keep the HTTP status when the server does not return JSON.
      }
      throw ApiException(message, response.statusCode);
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }
}

String formatTelemetryTime(Object? value) {
  if (value is! String) return '时间未知';
  final time = DateTime.tryParse(value);
  if (time == null) return '时间无效';
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class HengyangApp extends StatelessWidget {
  const HengyangApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '恒洋物联',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff126e78)),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xfff3f7f7),
        ),
        home: const AppRoot(),
      );
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});
  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  final api = Api();
  Map<String, dynamic>? session;
  bool loading = true;
  bool changingPassword = false;
  String? error;

  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    try {
      final result = await api.request('GET', '/session');
      if (mounted) setState(() => session = result as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.status != 401 && mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = '无法连接平台：$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (session == null) {
      return LoginPage(
        api: api,
        initialError: error,
        onLogin: (value, changePassword) => setState(() {
          session = value;
          changingPassword = changePassword;
        }),
      );
    }
    if (session!['must_change'] == true || changingPassword) {
      return PasswordPage(
        api: api,
        requiredChange: session!['must_change'] == true,
        onChanged: () => setState(() {
          session!['must_change'] = false;
          changingPassword = false;
        }),
        onCancel: () => setState(() => changingPassword = false),
      );
    }
    return Dashboard(
      api: api,
      onLogout: () => setState(() => session = null),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage(
      {super.key, required this.api, required this.onLogin, this.initialError});
  final Api api;
  final void Function(Map<String, dynamic>, bool) onLogin;
  final String? initialError;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final username = TextEditingController(text: 'admin');
  final password = TextEditingController();
  bool busy = false;
  bool changingPassword = false;
  String? error;

  @override
  void initState() {
    super.initState();
    error = widget.initialError;
  }

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> login({bool changePassword = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request('POST', '/login',
          {'username': username.text, 'password': password.text});
      widget.onLogin(result as Map<String, dynamic>, changePassword);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.hub_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 16),
                      Text(changingPassword ? '修改密码' : '恒洋物联',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      Text(changingPassword ? '请先验证账号和当前密码' : '设备连接 · 远程管理',
                          textAlign: TextAlign.center),
                      const SizedBox(height: 28),
                      TextField(
                          controller: username,
                          decoration: const InputDecoration(labelText: '账号')),
                      TextField(
                          controller: password,
                          obscureText: true,
                          onSubmitted: (_) => changingPassword
                              ? login(changePassword: true)
                              : login(),
                          decoration: const InputDecoration(labelText: '密码')),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        Text(error!, style: const TextStyle(color: Colors.red)),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : changingPassword
                                  ? () => login(changePassword: true)
                                  : () => login(),
                          child: Text(busy
                              ? '验证中…'
                              : changingPassword
                                  ? '验证并继续'
                                  : '登录')),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                    changingPassword = !changingPassword;
                                    error = null;
                                  }),
                          style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              textStyle: Theme.of(context).textTheme.bodySmall),
                          child: Text(changingPassword ? '返回登录' : '忘记密码？'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class PasswordPage extends StatefulWidget {
  const PasswordPage(
      {super.key,
      required this.api,
      required this.onChanged,
      required this.onCancel,
      required this.requiredChange});
  final Api api;
  final VoidCallback onChanged;
  final VoidCallback onCancel;
  final bool requiredChange;
  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final current = TextEditingController();
  final next = TextEditingController();
  final confirm = TextEditingController();
  String? error;
  bool busy = false;

  @override
  void dispose() {
    current.dispose();
    next.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (next.text != confirm.text) {
      setState(() => error = '两次输入的新密码不一致');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.request(
          'POST', '/password', {'current': current.text, 'new': next.text});
      widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 420,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(widget.requiredChange ? '首次登录：修改初始密码' : '修改密码',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(widget.requiredChange
                          ? '新密码至少 10 字节；修改后才能使用平台。'
                          : '请输入当前密码，新密码至少 10 字节。'),
                      for (final item in [
                        (current, '当前密码'),
                        (next, '新密码'),
                        (confirm, '确认新密码'),
                      ])
                        TextField(
                            controller: item.$1,
                            obscureText: true,
                            decoration: InputDecoration(labelText: item.$2)),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(error!, style: const TextStyle(color: Colors.red)),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                          onPressed: busy ? null : save,
                          child: const Text('保存密码')),
                      if (!widget.requiredChange)
                        TextButton(
                            onPressed: busy ? null : widget.onCancel,
                            child: const Text('取消')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class Dashboard extends StatefulWidget {
  const Dashboard(
      {super.key,
      required this.api,
      required this.onLogout,
      this.createTelemetryStream});
  final Api api;
  final VoidCallback onLogout;
  final TelemetryStream Function({
    required void Function() onOpen,
    required void Function() onUpdate,
    required void Function() onError,
  })? createTelemetryStream;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  List<Map<String, dynamic>> models = [];
  List<Map<String, dynamic>> devices = [];
  double latitude = 37.76, longitude = 117.58;
  bool loading = true;
  String? error;
  int page = 0;
  final mapController = MapController();
  TelemetryStream? telemetryStream;
  bool telemetryDisconnected = false;
  bool telemetryConnected = false;
  bool deviceRefreshInProgress = false;
  bool deviceRefreshPending = false;
  int deviceRequestVersion = 0;
  int appliedDeviceVersion = 0;

  @override
  void initState() {
    super.initState();
    refresh();
    telemetryStream = (widget.createTelemetryStream ??
        ({required onOpen, required onUpdate, required onError}) =>
            TelemetryStream(
              uri: widget.api.uri('/telemetry/events'),
              cookie: widget.api._sessionCookie,
              onOpen: onOpen,
              onUpdate: onUpdate,
              onError: onError,
            ))(
      onOpen: () {
        if (!mounted) return;
        setState(() {
          telemetryConnected = true;
          telemetryDisconnected = false;
        });
        refreshDevices();
      },
      onUpdate: refreshDevices,
      onError: () {
        if (!mounted) return;
        setState(() {
          telemetryConnected = false;
          telemetryDisconnected = true;
        });
        refreshDevices();
      },
    );
  }

  @override
  void dispose() {
    telemetryStream?.close();
    mapController.dispose();
    super.dispose();
  }

  Future<void> refreshDevices() async {
    if (!mounted) return;
    if (deviceRefreshInProgress) {
      deviceRefreshPending = true;
      return;
    }
    deviceRefreshInProgress = true;
    do {
      deviceRefreshPending = false;
      final version = ++deviceRequestVersion;
      try {
        final result = await widget.api.request('GET', '/devices');
        if (mounted && version > appliedDeviceVersion) {
          setState(() {
            appliedDeviceVersion = version;
            devices = (result as List).cast<Map<String, dynamic>>();
            telemetryDisconnected = !telemetryConnected;
          });
        }
      } on ApiException catch (e) {
        if (mounted && e.status == 401) {
          widget.onLogout();
        } else if (mounted) {
          setState(() => telemetryDisconnected = true);
          debugPrint('遥测刷新失败：${e.message}');
        }
      } catch (e) {
        if (mounted) {
          setState(() => telemetryDisconnected = true);
          debugPrint('遥测刷新失败：$e');
        }
      }
    } while (mounted && deviceRefreshPending);
    deviceRefreshInProgress = false;
  }

  Future<void> refresh() async {
    final version = ++deviceRequestVersion;
    try {
      final values = await Future.wait([
        widget.api.request('GET', '/models'),
        widget.api.request('GET', '/devices'),
        widget.api.request('GET', '/settings'),
      ]);
      final settings = values[2] as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        models = (values[0] as List).cast<Map<String, dynamic>>();
        if (version > appliedDeviceVersion) {
          appliedDeviceVersion = version;
          devices = (values[1] as List).cast<Map<String, dynamic>>();
        }
        latitude = (settings['latitude'] as num).toDouble();
        longitude = (settings['longitude'] as num).toDouble();
        error = null;
        loading = false;
      });
    } on ApiException catch (e) {
      if (e.status == 401) {
        widget.onLogout();
      } else if (mounted) {
        setState(() {
          error = e.message;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  Future<void> perform(Future<void> Function() action) async {
    try {
      await action();
      await refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Map<String, dynamic>? modelFor(Object? id) {
    for (final item in models) {
      if (item['id'] == id) return item;
    }
    return null;
  }

  Future<bool> confirmDelete(String label) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认删除'),
          content: Text('确定删除“$label”吗？此操作不可撤销。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除')),
          ],
        ),
      ) ??
      false;

  Future<void> editModel([Map<String, dynamic>? existing]) async {
    final result = await showDialog<Map<String, dynamic>>(
        context: context, builder: (_) => ModelDialog(existing: existing));
    if (result == null) return;
    await perform(() async {
      await widget.api.request(existing == null ? 'POST' : 'PUT',
          existing == null ? '/models' : '/models/${existing['id']}', result);
    });
  }

  Future<void> editDevice([Map<String, dynamic>? existing]) async {
    if (models.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先添加设备型号')));
      return;
    }
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => DeviceDialog(models: models, existing: existing));
    if (result == null) return;
    await perform(() async {
      await widget.api.request(
          existing == null ? 'POST' : 'PUT',
          existing == null ? '/devices' : '/devices/${existing['imei']}',
          result);
    });
  }

  Future<void> editCoordinates() async {
    final result = await showDialog<LatLng>(
        context: context,
        builder: (_) =>
            CoordinatesDialog(latitude: latitude, longitude: longitude));
    if (result == null) return;
    await perform(() async {
      await widget.api.request('PUT', '/settings',
          {'latitude': result.latitude, 'longitude': result.longitude});
      mapController.move(result, 11);
    });
  }

  Future<void> sendCommand(Map<String, dynamic> device, String command,
      {int? volume, int? songIndex}) async {
    try {
      await widget.api.request('POST', '/devices/${device['imei']}/commands', {
        'command': command,
        if (volume != null) 'volume': volume,
        if (songIndex != null) 'song_index': songIndex,
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('命令已发布')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    final titles = ['设备', '型号', '地图'];
    return Scaffold(
      appBar: AppBar(
        title: const Text('恒洋物联'),
        actions: [
          IconButton(
              onPressed: refresh,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh)),
          IconButton(
            tooltip: '退出登录',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              try {
                await widget.api.request('POST', '/logout');
                widget.onLogout();
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(e.toString())));
                }
              }
            },
          ),
        ],
      ),
      bottomNavigationBar: compact
          ? NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (value) => setState(() => page = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.devices), label: '设备'),
                NavigationDestination(
                    icon: Icon(Icons.category_outlined), label: '型号'),
                NavigationDestination(
                    icon: Icon(Icons.map_outlined), label: '地图'),
              ],
            )
          : null,
      body: Row(
        children: [
          if (!compact)
            NavigationRail(
              selectedIndex: page,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (value) => setState(() => page = value),
              destinations: const [
                NavigationRailDestination(
                    icon: Icon(Icons.devices), label: Text('设备')),
                NavigationRailDestination(
                    icon: Icon(Icons.category_outlined), label: Text('型号')),
                NavigationRailDestination(
                    icon: Icon(Icons.map_outlined), label: Text('地图')),
              ],
            ),
          Expanded(
            child: Column(children: [
              if (telemetryDisconnected)
                const MaterialBanner(
                  content: Text('遥测连接中断，正在重连；显示的数据可能不是最新。'),
                  actions: [SizedBox.shrink()],
                ),
              Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : error != null
                          ? Center(child: Text('加载失败：$error'))
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(24, 20, 24, 12),
                                  child: Row(children: [
                                    Expanded(
                                        child: Text(titles[page],
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall)),
                                    if (page == 0)
                                      FilledButton.icon(
                                          onPressed: () => editDevice(),
                                          icon: const Icon(Icons.add),
                                          label: const Text('添加设备')),
                                    if (page == 1)
                                      FilledButton.icon(
                                          onPressed: () => editModel(),
                                          icon: const Icon(Icons.add),
                                          label: const Text('添加型号')),
                                    if (page == 2)
                                      FilledButton.icon(
                                          onPressed: editCoordinates,
                                          icon: const Icon(
                                              Icons.edit_location_alt_outlined),
                                          label: const Text('设置中心')),
                                  ]),
                                ),
                                Expanded(
                                  child: switch (page) {
                                    0 => deviceList(),
                                    1 => modelList(),
                                    _ => mapView(),
                                  },
                                ),
                              ],
                            )),
            ]),
          ),
        ],
      ),
    );
  }

  Widget deviceList() {
    if (devices.isEmpty) return const Center(child: Text('暂无设备，请先添加型号和设备'));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        final model = modelFor(device['model_id']);
        final status = device['status'] as Map<String, dynamic>?;
        final fields = (model?['fields'] as List?) ?? [];
        final commands =
            ((model?['commands'] as List?) ?? []).whereType<String>().toSet();
        final showVolume =
            commands.contains('SET_VOLUME') || fields.contains('volume');
        final showUltrasonic = commands.any(ultrasonicCommands.containsKey);
        return Card(
          key: ValueKey(device['imei']),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    Text('${device['name']}',
                        style: Theme.of(context).textTheme.titleLarge),
                    Chip(label: Text('${model?['name'] ?? '未知型号'}')),
                    Text('IMEI ${device['imei']}'),
                    IconButton(
                        onPressed: () => editDevice(device),
                        tooltip: '编辑',
                        icon: const Icon(Icons.edit_outlined)),
                    IconButton(
                        onPressed: () async {
                          if (await confirmDelete('${device['name']}')) {
                            await perform(() async => widget.api.request(
                                'DELETE', '/devices/${device['imei']}'));
                          }
                        },
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(device['received_at'] == null
                    ? '尚未收到设备遥测'
                    : '最近遥测：${formatTelemetryTime(device['received_at'])}'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    for (final field in fields.where((field) =>
                        !(showVolume && field == 'volume') &&
                        !(showUltrasonic &&
                            (field == 'ultrasonicPlaying' ||
                                field == 'ultrasonicMode'))))
                      Text('$field：${status?[field] ?? '—'}'),
                  ],
                ),
                if (commands.isNotEmpty || showVolume)
                  const SizedBox(height: 12),
                if (commands.any(musicCommands.contains) || showVolume)
                  DevicePlayer(
                    status: status,
                    commands: commands,
                    volume: showVolume
                        ? VolumeControl(
                            reported: status?['volume'],
                            enabled: commands.contains('SET_VOLUME'),
                            onSend: (volume) => sendCommand(
                                device, 'SET_VOLUME',
                                volume: volume),
                          )
                        : null,
                    fetchPlaylist: (offset) async {
                      try {
                        final result = await widget.api.request(
                            'POST',
                            '/devices/${device['imei']}/playlist',
                            {'offset': offset});
                        return result as Map<String, dynamic>;
                      } on ApiException catch (error) {
                        if (mounted && error.status == 401) widget.onLogout();
                        rethrow;
                      }
                    },
                    onCommand: (command, index) =>
                        sendCommand(device, command, songIndex: index),
                  ),
                if (showUltrasonic)
                  UltrasonicControl(
                    status: status,
                    commands: commands,
                    onCommand: (command) => sendCommand(device, command),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final command in commands.where((e) =>
                        e != 'SET_VOLUME' &&
                        !musicCommands.contains(e) &&
                        !ultrasonicCommands.containsKey(e)))
                      CommandButton(
                        enabled: false,
                        onPressed: () async {},
                        child: Text(command),
                      ),
                  ],
                ),
                if (commands.any((e) => ![
                      'PLAY',
                      'PAUSE',
                      'NEXT',
                      'PREV',
                      'SET_VOLUME',
                      ...ultrasonicCommands.keys,
                    ].contains(e)))
                  const Text('灰色命令暂不可执行。'),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget modelList() {
    if (models.isEmpty) return const Center(child: Text('暂无型号，添加型号后即可注册设备'));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: models.length,
      itemBuilder: (context, index) {
        final model = models[index];
        return Card(
          child: ListTile(
            title: Text('${model['name']}'),
            subtitle: Text('展示：${(model['fields'] as List).join('、')}\n'
                '命令：${(model['commands'] as List).join('、')}'),
            isThreeLine: true,
            trailing: Wrap(children: [
              IconButton(
                  onPressed: () => editModel(model),
                  tooltip: '编辑',
                  icon: const Icon(Icons.edit_outlined)),
              IconButton(
                  onPressed: () async {
                    if (await confirmDelete('${model['name']}')) {
                      await perform(() async => widget.api
                          .request('DELETE', '/models/${model['id']}'));
                    }
                  },
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline)),
            ]),
          ),
        );
      },
    );
  }

  Widget mapView() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: FlutterMap(
            mapController: mapController,
            options: MapOptions(
                initialCenter: LatLng(latitude, longitude), initialZoom: 11),
            children: [
              TileLayer(
                urlTemplate: const String.fromEnvironment('MAP_TILE_URL',
                    defaultValue:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
                userAgentPackageName: 'com.hengyang.platform',
              ),
              MarkerLayer(markers: [
                Marker(
                  point: LatLng(latitude, longitude),
                  width: 40,
                  height: 40,
                  child: const Icon(Icons.location_on,
                      color: Colors.red, size: 40),
                ),
              ]),
              Positioned(
                top: 12,
                right: 12,
                child: Card(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                        tooltip: '放大地图',
                        onPressed: () => mapController.move(
                            mapController.camera.center,
                            (mapController.camera.zoom + 1).clamp(0, 19)),
                        icon: const Icon(Icons.add)),
                    IconButton(
                        tooltip: '缩小地图',
                        onPressed: () => mapController.move(
                            mapController.camera.center,
                            (mapController.camera.zoom - 1).clamp(0, 19)),
                        icon: const Icon(Icons.remove)),
                  ]),
                ),
              ),
              RichAttributionWidget(attributions: [
                TextSourceAttribution('© OpenStreetMap contributors',
                    onTap: () => launchUrl(
                        Uri.parse('https://www.openstreetmap.org/copyright'))),
              ]),
            ],
          ),
        ),
      );
}

class VolumeControl extends StatefulWidget {
  const VolumeControl(
      {super.key,
      required this.reported,
      required this.onSend,
      this.enabled = true});
  final Object? reported;
  final Future<void> Function(int) onSend;
  final bool enabled;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  double? selected;

  @override
  Widget build(BuildContext context) {
    final reported = widget.reported;
    final valid = reported is num && reported >= 0 && reported <= 100;
    final value = selected ?? (valid ? (reported).toDouble() : 50.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('设备上报音量：${valid ? reported : '未知'}；设置音量：${value.round()}'),
      if (!widget.enabled) const Text('请在设备型号的命令列表中添加 SET_VOLUME'),
      Row(children: [
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 100,
            divisions: 100,
            label: '${value.round()}',
            onChanged: widget.enabled
                ? (value) => setState(() => selected = value)
                : null,
          ),
        ),
        CommandButton(
            filled: true,
            enabled: widget.enabled,
            onPressed: () => widget.onSend(value.round()),
            child: const Text('设置音量')),
      ]),
    ]);
  }
}

class DevicePlayer extends StatefulWidget {
  const DevicePlayer({
    super.key,
    required this.status,
    required this.commands,
    required this.fetchPlaylist,
    required this.onCommand,
    this.volume,
  });

  final Map<String, dynamic>? status;
  final Set<String> commands;
  final Future<Map<String, dynamic>> Function(int) fetchPlaylist;
  final Future<void> Function(String, int?) onCommand;
  final VolumeControl? volume;

  @override
  State<DevicePlayer> createState() => _DevicePlayerState();
}

class _DevicePlayerState extends State<DevicePlayer> {
  static const pageSize = 20;
  List<Map<String, dynamic>>? songs;
  int offset = 0, total = 0;
  bool loading = false;
  String? error;

  Future<void> loadPage(int target) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.fetchPlaylist(target);
      if (!mounted) return;
      final pageTotal = page['total'] as int;
      final pageSongs = (page['items'] as List).cast<Map<String, dynamic>>();
      setState(() {
        if (target != 0 && pageTotal != total) {
          songs = null;
          offset = total = 0;
          error = '设备歌单已变化，请重新获取。';
          return;
        }
        songs = pageSongs;
        offset = page['offset'] as int;
        total = pageTotal;
      });
    } on Exception catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playing = widget.status?['playing'];
    final playCommand = widget.commands.contains('PAUSE') &&
            (playing == true || !widget.commands.contains('PLAY'))
        ? 'PAUSE'
        : 'PLAY';
    final trackId = widget.status?['trackId'];
    final name = widget.status?['trackName'];
    final title = name is String && name.isNotEmpty
        ? name
        : trackId is int && trackId > 0
            ? '曲目 $trackId'
            : '尚无曲目信息';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('音乐播放', style: theme.textTheme.titleMedium),
          if (widget.commands.any(musicCommands.contains)) ...[
            const SizedBox(height: 10),
            Row(children: [
              const Icon(Icons.album_outlined, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    Text(playing == true
                        ? '播放中'
                        : playing == false
                            ? '未播放'
                            : '状态未知'),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.commands.contains('PREV'))
                  CommandButton(
                    onPressed: () => widget.onCommand('PREV', null),
                    child: const Tooltip(
                        message: '上一首', child: Icon(Icons.skip_previous)),
                  ),
                if (widget.commands.contains(playCommand))
                  CommandButton(
                    key: const ValueKey('play-pause'),
                    onPressed: () => widget.onCommand(playCommand, null),
                    child: Tooltip(
                      message: playCommand == 'PLAY' ? '播放' : '暂停',
                      child: Icon(playCommand == 'PLAY'
                          ? Icons.play_arrow
                          : Icons.pause),
                    ),
                  ),
                if (widget.commands.contains('NEXT'))
                  CommandButton(
                    onPressed: () => widget.onCommand('NEXT', null),
                    child: const Tooltip(
                        message: '下一首', child: Icon(Icons.skip_next)),
                  ),
                if (widget.commands.contains('PLAY'))
                  OutlinedButton.icon(
                    onPressed: loading ? null : () => loadPage(0),
                    icon: const Icon(Icons.queue_music),
                    label: Text(songs == null ? '获取歌单' : '重新获取歌单'),
                  ),
              ],
            ),
          ],
          if (widget.volume != null) ...[
            if (widget.commands.any(musicCommands.contains)) const Divider(),
            widget.volume!,
          ],
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Text(error!, style: TextStyle(color: theme.colorScheme.error)),
          if (songs != null && widget.commands.contains('PLAY')) ...[
            const Divider(),
            Text(total == 0 ? '设备歌单为空' : '设备歌单 · $total 首'),
            for (final song in songs!)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Text('${(song['index'] as int) + 1}'),
                title: Text((song['name'] as String).isEmpty
                    ? '未命名曲目'
                    : song['name'] as String),
                selected: trackId == (song['index'] as int) + 1,
                trailing: CommandButton(
                  key: ValueKey(song['index']),
                  enabled: !loading && error == null,
                  onPressed: () =>
                      widget.onCommand('PLAY', song['index'] as int),
                  child: const Tooltip(
                      message: '播放此曲', child: Icon(Icons.play_arrow)),
                ),
              ),
            if (total > pageSize)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: !loading && offset > 0
                        ? () => loadPage(offset - pageSize)
                        : null,
                    child: const Text('上一页'),
                  ),
                  Text(
                      '${offset ~/ pageSize + 1} / ${(total + pageSize - 1) ~/ pageSize}'),
                  TextButton(
                    onPressed: !loading && offset + pageSize < total
                        ? () => loadPage(offset + pageSize)
                        : null,
                    child: const Text('下一页'),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class UltrasonicControl extends StatefulWidget {
  const UltrasonicControl({
    super.key,
    required this.status,
    required this.commands,
    required this.onCommand,
  });

  final Map<String, dynamic>? status;
  final Set<String> commands;
  final Future<void> Function(String) onCommand;

  @override
  State<UltrasonicControl> createState() => _UltrasonicControlState();
}

class _UltrasonicControlState extends State<UltrasonicControl> {
  static const modeCommands = {
    'sweep': 'ULTRASONIC_SWEEP',
    'fixed': 'ULTRASONIC_FIXED',
  };
  bool modeBusy = false;

  Future<void> selectMode(Set<String> selection) async {
    if (modeBusy || selection.isEmpty) return;
    setState(() => modeBusy = true);
    try {
      await runWithCommandCooldown(
          () => widget.onCommand(modeCommands[selection.single]!));
    } finally {
      if (mounted) setState(() => modeBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playing = widget.status?['ultrasonicPlaying'];
    final mode = widget.status?['ultrasonicMode'];
    final canPlay = widget.commands.contains('ULTRASONIC_PLAY');
    final canStop = widget.commands.contains('ULTRASONIC_STOP');
    final stop = playing == true || (playing == null && !canPlay && canStop);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('超声控制', style: Theme.of(context).textTheme.titleMedium),
          Text(
              '超声状态：${playing == true ? '播放中' : playing == false ? '已停止' : '未知'}；'
              '模式：${mode == 'sweep' ? '扫频 20–50 kHz' : mode == 'fixed' ? '定频 25 kHz' : '未知'}'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (canPlay || canStop)
                CommandButton(
                  filled: true,
                  enabled: stop ? canStop : canPlay,
                  onPressed: () => widget
                      .onCommand(stop ? 'ULTRASONIC_STOP' : 'ULTRASONIC_PLAY'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(stop ? Icons.pause : Icons.play_arrow),
                      const SizedBox(width: 4),
                      Text(stop ? '暂停超声' : '播放超声'),
                    ],
                  ),
                ),
              if (modeCommands.values.any(widget.commands.contains))
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'sweep',
                      label: const Text('扫频'),
                      enabled: widget.commands.contains(modeCommands['sweep']),
                    ),
                    ButtonSegment(
                      value: 'fixed',
                      label: const Text('定频'),
                      enabled: widget.commands.contains(modeCommands['fixed']),
                    ),
                  ],
                  selected: mode is String && modeCommands.containsKey(mode)
                      ? {mode}
                      : const {},
                  emptySelectionAllowed: true,
                  onSelectionChanged: modeBusy ? null : selectMode,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> runWithCommandCooldown(Future<void> Function() send) async {
  await Future.wait([
    Future<void>.delayed(const Duration(milliseconds: 200)),
    Future<void>.sync(send),
  ]);
}

class CommandButton extends StatefulWidget {
  const CommandButton(
      {super.key,
      required this.onPressed,
      required this.child,
      this.enabled = true,
      this.filled = false});
  final Future<void> Function() onPressed;
  final Widget child;
  final bool enabled;
  final bool filled;

  @override
  State<CommandButton> createState() => _CommandButtonState();
}

class _CommandButtonState extends State<CommandButton> {
  bool busy = false;

  Future<void> press() async {
    if (busy || !widget.enabled) return;
    setState(() => busy = true);
    try {
      await runWithCommandCooldown(widget.onPressed);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedScale(
        scale: busy ? 0.94 : 1,
        duration: const Duration(milliseconds: 100),
        child: widget.filled
            ? FilledButton(
                onPressed: widget.enabled && !busy ? press : null,
                child: widget.child)
            : OutlinedButton(
                onPressed: widget.enabled && !busy ? press : null,
                child: widget.child),
      );
}

class ModelDialog extends StatefulWidget {
  const ModelDialog({super.key, this.existing});
  final Map<String, dynamic>? existing;
  @override
  State<ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<ModelDialog> {
  late final TextEditingController name, fields, commands;
  @override
  void initState() {
    super.initState();
    name =
        TextEditingController(text: widget.existing?['name'] as String? ?? '');
    fields = TextEditingController(
        text: ((widget.existing?['fields'] as List?) ??
                ['playing', 'trackName', 'volume'])
            .join(', '));
    commands = TextEditingController(
        text: ((widget.existing?['commands'] as List?) ??
                ['PLAY', 'PAUSE', 'NEXT', 'PREV'])
            .join(', '));
  }

  @override
  void dispose() {
    name.dispose();
    fields.dispose();
    commands.dispose();
    super.dispose();
  }

  List<String> split(String text) =>
      text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? '添加型号' : '编辑型号'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '型号名称')),
              TextField(
                  controller: fields,
                  decoration: const InputDecoration(
                      labelText: '遥测字段（逗号分隔）',
                      helperText: '字段名必须与设备上报 JSON 一致')),
              TextField(
                  controller: commands,
                  decoration: const InputDecoration(
                      labelText: '命令（逗号分隔）', helperText: '音量控制需添加 SET_VOLUME'),
                  onChanged: (_) => setState(() {})),
              CheckboxListTile(
                title: const Text('启用超声控制'),
                value: ultrasonicCommands.keys
                    .every(split(commands.text).contains),
                onChanged: (enabled) {
                  final current = split(commands.text)
                      .where(
                          (command) => !ultrasonicCommands.containsKey(command))
                      .toList();
                  if (enabled == true) current.addAll(ultrasonicCommands.keys);
                  setState(() => commands.text = current.join(', '));
                },
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, {
                    'name': name.text,
                    'fields': split(fields.text),
                    'commands': split(commands.text),
                  }),
              child: const Text('保存')),
        ],
      );
}

class DeviceDialog extends StatefulWidget {
  const DeviceDialog({super.key, required this.models, this.existing});
  final List<Map<String, dynamic>> models;
  final Map<String, dynamic>? existing;
  @override
  State<DeviceDialog> createState() => _DeviceDialogState();
}

class _DeviceDialogState extends State<DeviceDialog> {
  late final TextEditingController name, imei;
  late int modelId;
  @override
  void initState() {
    super.initState();
    name =
        TextEditingController(text: widget.existing?['name'] as String? ?? '');
    imei =
        TextEditingController(text: widget.existing?['imei'] as String? ?? '');
    modelId =
        (widget.existing?['model_id'] ?? widget.models.first['id']) as int;
  }

  @override
  void dispose() {
    name.dispose();
    imei.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? '添加设备' : '编辑设备'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '设备名称')),
            TextField(
                controller: imei,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'IMEI（15 位数字）')),
            DropdownButtonFormField<int>(
              value: modelId,
              decoration: const InputDecoration(labelText: '设备型号'),
              items: [
                for (final model in widget.models)
                  DropdownMenuItem(
                      value: model['id'] as int,
                      child: Text('${model['name']}'))
              ],
              onChanged: (value) => setState(() => modelId = value!),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context,
                  {'name': name.text, 'imei': imei.text, 'model_id': modelId}),
              child: const Text('保存')),
        ],
      );
}

class CoordinatesDialog extends StatefulWidget {
  const CoordinatesDialog(
      {super.key, required this.latitude, required this.longitude});
  final double latitude, longitude;
  @override
  State<CoordinatesDialog> createState() => _CoordinatesDialogState();
}

class _CoordinatesDialogState extends State<CoordinatesDialog> {
  late final TextEditingController lat, lon;
  String? error;
  @override
  void initState() {
    super.initState();
    lat = TextEditingController(text: '${widget.latitude}');
    lon = TextEditingController(text: '${widget.longitude}');
  }

  @override
  void dispose() {
    lat.dispose();
    lon.dispose();
    super.dispose();
  }

  void save() {
    final latitude = double.tryParse(lat.text);
    final longitude = double.tryParse(lon.text);
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      setState(() => error = '请输入有效的 WGS-84 经纬度');
      return;
    }
    Navigator.pop(context, LatLng(latitude, longitude));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('设置地图中心'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: lon,
                decoration: const InputDecoration(labelText: '经度')),
            TextField(
                controller: lat,
                decoration: const InputDecoration(labelText: '纬度')),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: save, child: const Text('保存')),
        ],
      );
}
