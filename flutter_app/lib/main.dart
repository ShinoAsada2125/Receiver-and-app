import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:math';

// ignore_for_file: prefer_const_constructors, sized_box_for_whitespace

void main() => runApp(const MyApp());

const String bleDeviceName = 'LoRaReceiver';
final Uuid serviceUuid = Uuid.parse('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
final Uuid txChar = Uuid.parse('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');
final Uuid rxChar = Uuid.parse('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');

class AppColors {
  static const Color bg = Color(0xFF000000);
  static const Color card = Color(0xFF212020);
  static const Color cardLight = Color(0xFF2A2929);
  static const Color accent = Color(0xFF90878E);
  static const Color textPrimary = Color(0xFFECE8E5);
  static const Color textSecondary = Color(0xFFC6C2C3);
  static const Color surface = Color(0xFF181717);
  static const Color activeGreen = Color(0xCC4CAF50);
  static const Color alertRed = Color(0xFFD32F2F);
  static const Color amber = Color(0xFFFFB300);
  static const Color navBar = Color(0xFF212020);
}

class AppColorsLight {
  static const Color bg = Color(0xFFECE8E5);
  static const Color card = Color(0xFFFFFFFF);
  static const Color cardLight = Color(0xFFF5F3F1);
  static const Color accent = Color(0xFF90878E);
  static const Color textPrimary = Color(0xFF212020);
  static const Color textSecondary = Color(0xFF6B6567);
  static const Color surface = Color(0xFFC6C2C3);
  static const Color activeGreen = Color(0xCC4CAF50);
  static const Color alertRed = Color(0xFFD32F2F);
  static const Color amber = Color(0xFFFFB300);
  static const Color navBar = Color(0xFFFFFFFF);
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isDark = true;
  void _toggleTheme() => setState(() => _isDark = !_isDark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoRa Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: _isDark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: _isDark ? AppColors.bg : AppColorsLight.bg,
        cardColor: _isDark ? AppColors.card : AppColorsLight.card,
        primaryColor: AppColors.accent,
        fontFamily: 'Roboto',
      ),
      home: DashboardPage(isDark: _isDark, onToggleTheme: _toggleTheme),
    );
  }
}
class DashboardPage extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;
  const DashboardPage({Key? key, required this.isDark, required this.onToggleTheme}) : super(key: key);
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with TickerProviderStateMixin {
  final _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BleStatus>? _bleStatusSub;

  String? _deviceId;
  bool _connected = false;
  String _status = 'Idle';
  int _currentTab = 0;

  Map<String, dynamic> sensor = {
    'temp1': null, 'humid1': null, 'temp2': null, 'humid2': null,
    'water_level': null, 'volume': null, 'percent': null,
    'packet': null, 'tank_full': null,
    'rssi': null, 'snr': null, 'timestamp': null,
  };

  final List<String> _log = [];
  bool heaterOn = false, dehumOn = false;
  bool fan1On = false, fan2On = false, fan3On = false;
  bool _tankFull = false, _masterOn = false;
  String _messageBuffer = '';
  late AnimationController _pulseController;
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  Color get _bg => widget.isDark ? AppColors.bg : AppColorsLight.bg;
  Color get _card => widget.isDark ? AppColors.card : AppColorsLight.card;
  Color get _textPrimary => widget.isDark ? AppColors.textPrimary : AppColorsLight.textPrimary;
  Color get _textSecondary => widget.isDark ? AppColors.textSecondary : AppColorsLight.textSecondary;
  Color get _navBar => widget.isDark ? AppColors.navBar : AppColorsLight.navBar;
  Color get _accent => AppColors.accent;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
    _bleStatusSub = _ble.statusStream.listen((status) {
      String s;
      switch (status) {
        case BleStatus.ready: s = _connected ? 'Connected' : 'Idle'; break;
        case BleStatus.poweredOff: s = 'Bluetooth disabled'; break;
        case BleStatus.unauthorized: s = 'Bluetooth unauthorized'; break;
        case BleStatus.unsupported: s = 'Bluetooth unsupported'; break;
        case BleStatus.locationServicesDisabled: s = 'Location services disabled'; break;
        default: s = 'BLE: $status';
      }
      setState(() => _status = s);
      _logAdd('BLE adapter: $status');
    });
    _ensurePermissionsAndStart();
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _notificationsPlugin.initialize(initSettings);
    // Request notification permission on Android 13+
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
  }

  Future<void> _showTankFullNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'tank_alerts',
      'Tank Alerts',
      channelDescription: 'Notifications when water tank is full',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      icon: '@mipmap/ic_launcher',
    );
    const details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(
      0,
      'TANK FULL',
      'Water tank is full — all devices have been shut down!',
      details,
    );
  }

  Future<void> _ensurePermissionsAndStart() async {
    bool granted = true;
    try {
      if (Platform.isAndroid) {
        final statuses = await [
          Permission.bluetoothScan, Permission.bluetoothConnect,
          Permission.bluetooth, Permission.locationWhenInUse,
        ].request();
        granted = statuses.values.every((s) => s.isGranted);
      } else if (Platform.isIOS) {
        final status = await Permission.bluetooth.request();
        granted = status.isGranted;
      }
    } catch (e) {
      _logAdd('Permission error: $e');
      granted = false;
    }
    if (granted) { _startScan(); }
    else {
      setState(() => _status = 'Permissions required');
      _logAdd('Required permissions not granted.');
    }
  }

  void _startScan() {
    _scanSub?.cancel();
    _scanSub = null;
    _ble.statusStream.firstWhere((status) => status == BleStatus.ready).then((_) {
      _logAdd('Scanning for LoRaReceiver...');
      setState(() => _status = 'Scanning...');
      _scanSub = _ble.scanForDevices(withServices: [serviceUuid], scanMode: ScanMode.lowLatency).listen((device) {
        String name = device.name.isNotEmpty ? device.name : 'N/A';
        if ((_deviceId == null) && name == bleDeviceName) {
          _logAdd('Found: $name (${device.id}) RSSI:${device.rssi}');
          _scanSub?.cancel(); _scanSub = null;
          _deviceId = device.id;
          _connectToDevice(device.id);
        }
      }, onError: (e) => _logAdd('Scan error: $e'));
      Future.delayed(const Duration(seconds: 5), () {
        if (_deviceId == null && _scanSub != null) {
          _scanSub?.cancel(); _scanSub = null;
          _logAdd('UUID scan timeout - trying name fallback...');
          _scanSub = _ble.scanForDevices(withServices: []).listen((device) {
            if ((_deviceId == null) && device.name == bleDeviceName) {
              _logAdd('Found via fallback: ${device.name} (${device.id})');
              _scanSub?.cancel(); _scanSub = null;
              _deviceId = device.id;
              _connectToDevice(device.id);
            }
          }, onError: (e) => _logAdd('Fallback scan error: $e'));
          Future.delayed(const Duration(seconds: 10), () {
            if (_scanSub != null && _deviceId == null) {
              _scanSub?.cancel(); _scanSub = null;
              _logAdd('Scan failed - retrying...');
              Future.delayed(const Duration(seconds: 2), () { if (!_connected) _startScan(); });
            }
          });
        }
      });
    }).catchError((e) {
      _logAdd('BLE not ready: $e');
      Future.delayed(const Duration(seconds: 2), () { if (!_connected) _startScan(); });
    });
  }

  void _connectToDevice(String id) {
    setState(() => _status = 'Connecting...');
    _connSub = _ble.connectToDevice(id: id, connectionTimeout: const Duration(seconds: 10)).listen((event) async {
      if (event.connectionState == DeviceConnectionState.connected) {
        _logAdd('Connected - clearing GATT cache...');
        try { await _ble.clearGattCache(id); _logAdd('GATT cache cleared'); }
        catch (e) { _logAdd('GATT cache clear failed: $e'); }
        await Future.delayed(const Duration(milliseconds: 500));
        setState(() { _connected = true; _status = 'Connected'; });
        _startNotify(id);
      } else if (event.connectionState == DeviceConnectionState.disconnected) {
        _logAdd('Disconnected');
        setState(() { _connected = false; _status = 'Disconnected'; });
        _deviceId = null;
        _notifySub?.cancel();
      }
    }, onError: (e) {
      _logAdd('Connection error: $e');
      setState(() => _status = 'Connection error');
    });
  }

  void _startNotify(String id) {
    _notifySub = _ble.subscribeToCharacteristic(
      QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: txChar, deviceId: id)
    ).listen((data) {
      _handleIncoming(utf8.decode(data));
    }, onError: (e) => _logAdd('Notify error: $e'));
  }

  void _disconnect() {
    _logAdd('Disconnecting...');
    _notifySub?.cancel(); _notifySub = null;
    _connSub?.cancel(); _connSub = null;
    Future.delayed(const Duration(milliseconds: 500), () {
      setState(() { _connected = false; _status = 'Disconnected'; _deviceId = null; });
      _logAdd('Disconnected');
    });
  }
  void _handleIncoming(String s) {
    _messageBuffer += s;
    while (_messageBuffer.contains('\n')) {
      int newlineIndex = _messageBuffer.indexOf('\n');
      String completeMsg = _messageBuffer.substring(0, newlineIndex).trim();
      _messageBuffer = _messageBuffer.substring(newlineIndex + 1);
      if (completeMsg.isEmpty) continue;
      _logAdd('RX: ${completeMsg.substring(0, min(completeMsg.length, 50))}');
      if (completeMsg.startsWith('{') && completeMsg.endsWith('}')) {
        try {
          String sanitized = completeMsg.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
          final m = jsonDecode(sanitized);
          if (m.containsKey('type')) {
            String msgType = m['type'] ?? 'unknown';
            if (msgType == 'ackcmd') {
              _logAdd('ACK: ${m['raw'] ?? ''} (RSSI: ${m['rssi']})');
            } else if (msgType == 'reject') {
              _logAdd('REJECTED: ${m['command'] ?? ''} - ${m['reason'] ?? ''}');
            } else if (msgType == 'status') {
              bool isFull = m['tank_full'] == true;
              _logAdd(isFull ? 'TANK FULL - All devices shut down!' : 'TANK OK - Devices restored');
              if (isFull && !_tankFull) _showTankFullNotification();
              setState(() {
                _tankFull = isFull; sensor['tank_full'] = isFull;
                if (isFull) { fan1On = false; fan2On = false; fan3On = false; heaterOn = false; dehumOn = false; _masterOn = false; }
                else { fan1On = true; fan2On = true; fan3On = true; heaterOn = true; dehumOn = true; _masterOn = true; }
              });
            } else { _logAdd('Message: ${m['raw'] ?? sanitized}'); }
            setState(() {
              sensor['rssi'] = (m['rssi'] as num?)?.toDouble() ?? sensor['rssi'];
              sensor['snr'] = (m['snr'] as num?)?.toDouble() ?? sensor['snr'];
            });
          } else {
            setState(() {
              sensor['temp1'] = (m['temp1'] as num?)?.toDouble() ?? sensor['temp1'] ?? 0.0;
              sensor['humid1'] = (m['humid1'] as num?)?.toDouble() ?? sensor['humid1'] ?? 0.0;
              sensor['temp2'] = (m['temp2'] as num?)?.toDouble() ?? sensor['temp2'] ?? 0.0;
              sensor['humid2'] = (m['humid2'] as num?)?.toDouble() ?? sensor['humid2'] ?? 0.0;
              sensor['water_level'] = (m['water_level'] as num?)?.toDouble() ?? sensor['water_level'] ?? 0.0;
              sensor['volume'] = (m['volume'] as num?)?.toDouble() ?? sensor['volume'] ?? 0.0;
              sensor['percent'] = (m['percent'] as num?)?.toDouble() ?? sensor['percent'] ?? 0.0;
              sensor['packet'] = m['packet'] ?? sensor['packet'] ?? 0;
              sensor['tank_full'] = m['tank_full'] ?? sensor['tank_full'] ?? false;
              bool newTankFull = sensor['tank_full'] == true;
              if (newTankFull != _tankFull) {
                _tankFull = newTankFull;
                if (_tankFull) { fan1On = false; fan2On = false; fan3On = false; heaterOn = false; dehumOn = false; _masterOn = false; _showTankFullNotification(); }
                else { fan1On = true; fan2On = true; fan3On = true; heaterOn = true; dehumOn = true; _masterOn = true; }
              }
              sensor['rssi'] = (m['rssi'] as num?)?.toDouble() ?? sensor['rssi'] ?? 0.0;
              sensor['snr'] = (m['snr'] as num?)?.toDouble() ?? sensor['snr'] ?? 0.0;
              sensor['timestamp'] = DateTime.now().toIso8601String();
            });
            _logAdd('Sensors updated');
          }
        } catch (e) { _logAdd('JSON parse error: $e'); }
      } else if (completeMsg.startsWith('ACKCMD:') || completeMsg.startsWith('REJECT:') ||
                 completeMsg.startsWith('SENT:') || completeMsg.startsWith('FORWARDED:')) {
        _logAdd(completeMsg);
      } else if (RegExp(r'^[\d.-]+,[\d.-]+,[\d.-]+,[\d.-]+,[\d.-]+,[01]$').hasMatch(completeMsg)) {
        List<String> parts = completeMsg.split(',');
        if (parts.length >= 6) {
          setState(() {
            sensor['temp1'] = double.tryParse(parts[0]) ?? sensor['temp1'];
            sensor['humid1'] = double.tryParse(parts[1]) ?? sensor['humid1'];
            sensor['temp2'] = double.tryParse(parts[2]) ?? sensor['temp2'];
            sensor['humid2'] = double.tryParse(parts[3]) ?? sensor['humid2'];
            sensor['volume'] = double.tryParse(parts[4]) ?? sensor['volume'];
            sensor['tank_full'] = parts[5] == '1';
            sensor['timestamp'] = DateTime.now().toIso8601String();
          });
          _logAdd('CSV parsed');
        }
      }
    }
    if (_messageBuffer.length > 500) { _messageBuffer = ''; }
  }
  void _sendCommand(String cmd) async {
    if (!_connected || _deviceId == null) { _logAdd('Not connected'); return; }
    if (cmd.isEmpty) return;
    _logAdd('TX: $cmd');
    try {
      await _ble.writeCharacteristicWithoutResponse(
        QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: rxChar, deviceId: _deviceId!),
        value: utf8.encode(cmd),
      );
      _logAdd('Write OK: $cmd');
    } catch (e) { _logAdd('Write error: $e'); }
  }

  void _masterToggle() {
    if (_tankFull) return;
    _masterOn = !_masterOn;
    String action = _masterOn ? 'ON' : 'OFF';
    _sendCommand('FAN1:$action');
    Future.delayed(const Duration(milliseconds: 200), () => _sendCommand('FAN2:$action'));
    Future.delayed(const Duration(milliseconds: 400), () => _sendCommand('FAN3:$action'));
    Future.delayed(const Duration(milliseconds: 600), () => _sendCommand('HEATER:$action'));
    Future.delayed(const Duration(milliseconds: 800), () => _sendCommand('DEHUM:$action'));
    setState(() { fan1On = _masterOn; fan2On = _masterOn; fan3On = _masterOn; heaterOn = _masterOn; dehumOn = _masterOn; });
  }

  void _logAdd(String s) {
    setState(() {
      final now = DateTime.now();
      _log.insert(0, '[${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}:${now.second.toString().padLeft(2,'0')}] $s');
      if (_log.length > 300) _log.removeLast();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scanSub?.cancel(); _connSub?.cancel(); _notifySub?.cancel(); _bleStatusSub?.cancel();
    super.dispose();
  }

  // Signal helpers
  String _signalLabel() {
    double? rssi = (sensor['rssi'] as num?)?.toDouble();
    if (rssi == null || !_connected) return 'No Signal';
    if (rssi > -60) return 'Strong';
    if (rssi > -80) return 'Moderate';
    if (rssi > -100) return 'Weak';
    return 'No Signal';
  }
  Color _signalColor() {
    double? rssi = (sensor['rssi'] as num?)?.toDouble();
    if (rssi == null || !_connected) return AppColors.alertRed;
    if (rssi > -60) return AppColors.activeGreen;
    if (rssi > -80) return AppColors.amber;
    if (rssi > -100) return Colors.orange;
    return AppColors.alertRed;
  }
  int _signalBars() {
    double? rssi = (sensor['rssi'] as num?)?.toDouble();
    if (rssi == null || !_connected) return 0;
    if (rssi > -60) return 4;
    if (rssi > -75) return 3;
    if (rssi > -90) return 2;
    if (rssi > -100) return 1;
    return 0;
  }
  String _fmt(dynamic v) {
    if (v == null) return '--';
    if (v is double) return v.toStringAsFixed(1);
    return v.toString();
  }
  String _fmtTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')}';
    } catch (_) { return iso; }
  }
  // ======== BUILD ========
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: IndexedStack(
          index: _currentTab,
          children: [_buildDashboardTab(), _buildDataTab(), _buildControlsTab(), _buildLogsTab()],
        ),
      ),
      bottomNavigationBar: _buildNavBar(),
    );
  }

  Widget _buildNavBar() {
    final items = [
      ['Dashboard', Icons.dashboard_rounded],
      ['Data', Icons.ssid_chart_rounded],
      ['Controls', Icons.power_settings_new_rounded],
      ['Logs', Icons.article_outlined],
    ];
    return Container(
      decoration: BoxDecoration(
        color: _navBar,
        border: Border(top: BorderSide(color: _accent.withOpacity(0.15), width: 0.5)),
      ),
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(items.length, (i) {
          bool sel = _currentTab == i;
          return GestureDetector(
            onTap: () => setState(() => _currentTab = i),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: sel ? BoxDecoration(color: _textPrimary.withOpacity(0.08), borderRadius: BorderRadius.circular(20)) : null,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(items[i][1] as IconData, size: 24, color: sel ? _textPrimary : _accent),
                const SizedBox(height: 4),
                Text(items[i][0] as String, style: TextStyle(fontSize: 10, fontWeight: sel ? FontWeight.w600 : FontWeight.w400, color: sel ? _textPrimary : _accent)),
              ]),
            ),
          );
        }),
      ),
    );
  }
  // ======== TAB 1: DASHBOARD ========
  Widget _buildDashboardTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      // Header row
      Row(children: [
        Text('LoRa Control', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: _textPrimary, letterSpacing: -0.5)),
        const Spacer(),
        GestureDetector(
          onTap: widget.onToggleTheme,
          child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
            child: Icon(widget.isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, color: _textSecondary, size: 20)),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () { if (_connected) _disconnect(); else _startScan(); },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _connected ? AppColors.activeGreen.withOpacity(0.15) : _card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _connected ? AppColors.activeGreen.withOpacity(0.4) : _accent.withOpacity(0.2)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AnimatedBuilder(animation: _pulseController, builder: (ctx, _) {
                return Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
                  color: _connected ? AppColors.activeGreen.withOpacity(0.5 + _pulseController.value * 0.5) : AppColors.alertRed.withOpacity(0.5 + _pulseController.value * 0.5)));
              }),
              const SizedBox(width: 8),
              Text(_connected ? 'Connected' : 'Scan', style: TextStyle(color: _textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Text(_status, style: TextStyle(color: _textSecondary, fontSize: 12)),
      const SizedBox(height: 16),
      if (_tankFull) _buildTankFullBanner(),
      _buildSignalBadge(),
      const SizedBox(height: 16),
      // 2x2 stat cards
      Row(children: [
        Expanded(child: _buildStatCard('Temperature', '${_fmt(sensor['temp1'])}\u00B0C', Icons.thermostat_rounded, Colors.orange)),
        const SizedBox(width: 12),
        Expanded(child: _buildStatCard('Humidity', '${_fmt(sensor['humid1'])}%', Icons.water_drop_rounded, Colors.lightBlue)),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _buildStatCard('Volume', '${_fmt(sensor['volume'])} L', Icons.waves_rounded, Colors.cyan)),
        const SizedBox(width: 12),
        Expanded(child: _buildStatCard('Tank', _tankFull ? 'FULL' : 'OK', _tankFull ? Icons.warning_rounded : Icons.check_circle_rounded, _tankFull ? AppColors.alertRed : AppColors.activeGreen)),
      ]),
      const SizedBox(height: 20),
      Text('Quick Controls', style: TextStyle(color: _textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      _buildQuickControls(),
    ]);
  }

  Widget _buildTankFullBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: AppColors.alertRed.withOpacity(0.15), borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.alertRed.withOpacity(0.4))),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, color: AppColors.alertRed, size: 28),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('TANK FULL', style: TextStyle(color: AppColors.alertRed, fontWeight: FontWeight.w700, fontSize: 15)),
          Text('All devices locked \u2014 emergency shutdown active', style: TextStyle(color: _textSecondary, fontSize: 12)),
        ])),
      ]),
    );
  }

  Widget _buildSignalBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        _buildSignalBarsWidget(_signalBars(), _signalColor(), 18),
        const SizedBox(width: 12),
        Text(_signalLabel(), style: TextStyle(color: _signalColor(), fontWeight: FontWeight.w600, fontSize: 13)),
        const Spacer(),
        if (sensor['rssi'] != null)
          Text('${(sensor['rssi'] as num).toStringAsFixed(0)} dBm', style: TextStyle(color: _textSecondary, fontSize: 12)),
      ]),
    );
  }

  Widget _buildSignalBarsWidget(int bars, Color color, double height) {
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: List.generate(4, (i) {
      double h = height * (0.3 + 0.175 * i);
      return Container(width: 4, height: h, margin: const EdgeInsets.only(right: 2),
        decoration: BoxDecoration(color: i < bars ? color : _accent.withOpacity(0.2), borderRadius: BorderRadius.circular(2)));
    }));
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, color: color, size: 18), const SizedBox(width: 6), Text(label, style: TextStyle(color: _textSecondary, fontSize: 12))]),
        const SizedBox(height: 8),
        Text(value, style: TextStyle(color: _textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _buildQuickControls() {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      _qToggle('FAN1', fan1On, Icons.air_rounded, () { if (_tankFull) return; setState(() => fan1On = !fan1On); _sendCommand('FAN1:${fan1On ? 'ON' : 'OFF'}'); }),
      _qToggle('FAN2', fan2On, Icons.air_rounded, () { if (_tankFull) return; setState(() => fan2On = !fan2On); _sendCommand('FAN2:${fan2On ? 'ON' : 'OFF'}'); }),
      _qToggle('FAN3', fan3On, Icons.air_rounded, () { if (_tankFull) return; setState(() => fan3On = !fan3On); _sendCommand('FAN3:${fan3On ? 'ON' : 'OFF'}'); }),
      _qToggle('HTR', heaterOn, Icons.local_fire_department_rounded, () { if (_tankFull) return; setState(() => heaterOn = !heaterOn); _sendCommand('HEATER:${heaterOn ? 'ON' : 'OFF'}'); }),
      _qToggle('DHM', dehumOn, Icons.opacity_rounded, () { if (_tankFull) return; setState(() => dehumOn = !dehumOn); _sendCommand('DEHUM:${dehumOn ? 'ON' : 'OFF'}'); }),
    ]);
  }

  Widget _qToggle(String label, bool on, IconData icon, VoidCallback onTap) {
    bool locked = _tankFull;
    return GestureDetector(
      onTap: locked ? null : onTap,
      child: Container(width: 64, padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: locked ? AppColors.alertRed.withOpacity(0.1) : on ? AppColors.activeGreen.withOpacity(0.12) : _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: locked ? AppColors.alertRed.withOpacity(0.3) : on ? AppColors.activeGreen.withOpacity(0.4) : _accent.withOpacity(0.12)),
        ),
        child: Column(children: [
          Icon(icon, color: locked ? AppColors.alertRed.withOpacity(0.5) : on ? AppColors.activeGreen : _accent, size: 22),
          const SizedBox(height: 4),
          Text(locked ? 'LOCK' : label, style: TextStyle(color: locked ? AppColors.alertRed.withOpacity(0.7) : _textSecondary, fontSize: 10, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
  // ======== TAB 2: DATA ========
  Widget _buildDataTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Data Monitor', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _textPrimary, letterSpacing: -0.5)),
      const SizedBox(height: 4),
      Text('Sensor readings & signal quality', style: TextStyle(color: _textSecondary, fontSize: 13)),
      const SizedBox(height: 20),
      // Large signal card
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16), border: Border.all(color: _signalColor().withOpacity(0.2))),
        child: Row(children: [
          _buildSignalBarsWidget(_signalBars(), _signalColor(), 36),
          const SizedBox(width: 20),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_signalLabel(), style: TextStyle(color: _signalColor(), fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(sensor['rssi'] != null ? '${(sensor['rssi'] as num).toStringAsFixed(0)} dBm  \u2022  SNR ${sensor['snr'] != null ? (sensor['snr'] as num).toStringAsFixed(1) : '-'} dB' : 'No data received yet', style: TextStyle(color: _textSecondary, fontSize: 12)),
          ])),
        ]),
      ),
      const SizedBox(height: 16),
      _sensorSection('Outside Sensor', Icons.wb_sunny_rounded, [
        ['Temperature', '${_fmt(sensor['temp1'])}\u00B0C', Colors.orange],
        ['Humidity', '${_fmt(sensor['humid1'])}%', Colors.lightBlue],
      ]),
      const SizedBox(height: 12),
      _sensorSection('Chamber Sensor', Icons.house_rounded, [
        ['Temperature', '${_fmt(sensor['temp2'])}\u00B0C', Colors.deepOrange],
        ['Humidity', '${_fmt(sensor['humid2'])}%', Colors.blue],
      ]),
      const SizedBox(height: 12),
      _sensorSection('Water Tank', Icons.water_rounded, [
        ['Volume', '${_fmt(sensor['volume'])} L', Colors.cyan],
        ['Level', '${_fmt(sensor['percent'])}%', Colors.teal],
        ['Tank Status', _tankFull ? 'FULL' : 'Normal', _tankFull ? AppColors.alertRed : AppColors.activeGreen],
      ]),
      const SizedBox(height: 12),
      // Metadata card
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(Icons.info_outline_rounded, color: _accent, size: 16), const SizedBox(width: 8), Text('Metadata', style: TextStyle(color: _textSecondary, fontSize: 13, fontWeight: FontWeight.w600))]),
          const SizedBox(height: 12),
          _metaRow('Packets', '${sensor['packet'] ?? '-'}'),
          _metaRow('Last Update', sensor['timestamp'] != null ? _fmtTime(sensor['timestamp']) : '-'),
          _metaRow('RSSI', '${sensor['rssi'] != null ? (sensor['rssi'] as num).toStringAsFixed(0) : '-'} dBm'),
          _metaRow('SNR', '${sensor['snr'] != null ? (sensor['snr'] as num).toStringAsFixed(1) : '-'} dB'),
        ]),
      ),
    ]);
  }

  Widget _sensorSection(String title, IconData icon, List<List<dynamic>> rows) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, color: _accent, size: 16), const SizedBox(width: 8), Text(title, style: TextStyle(color: _textSecondary, fontSize: 13, fontWeight: FontWeight.w600))]),
        const SizedBox(height: 14),
        ...rows.map((r) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [
          Container(width: 4, height: 4, decoration: BoxDecoration(shape: BoxShape.circle, color: r[2] as Color)),
          const SizedBox(width: 10),
          Text(r[0] as String, style: TextStyle(color: _textSecondary, fontSize: 13)),
          const Spacer(),
          Text(r[1] as String, style: TextStyle(color: _textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
        ]))),
      ]),
    );
  }

  Widget _metaRow(String label, String value) {
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
      Text(label, style: TextStyle(color: _textSecondary, fontSize: 12)),
      const Spacer(),
      Text(value, style: TextStyle(color: _textPrimary, fontSize: 12, fontWeight: FontWeight.w500)),
    ]));
  }
  // ======== TAB 3: CONTROLS ========
  Widget _buildControlsTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Control Panel', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _textPrimary, letterSpacing: -0.5)),
      const SizedBox(height: 4),
      Text('Manage all connected devices', style: TextStyle(color: _textSecondary, fontSize: 13)),
      const SizedBox(height: 20),
      if (_tankFull) _buildTankFullBanner(),
      // Master Control
      _buildMasterControl(),
      const SizedBox(height: 20),
      Text('Individual Devices', style: TextStyle(color: _textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      // Fan row
      Row(children: [
        Expanded(child: _devCard('FAN 1', fan1On, Icons.air_rounded, Colors.teal, () { if (_tankFull) return; setState(() => fan1On = !fan1On); _sendCommand('FAN1:${fan1On ? 'ON' : 'OFF'}'); })),
        const SizedBox(width: 10),
        Expanded(child: _devCard('FAN 2', fan2On, Icons.air_rounded, Colors.teal, () { if (_tankFull) return; setState(() => fan2On = !fan2On); _sendCommand('FAN2:${fan2On ? 'ON' : 'OFF'}'); })),
        const SizedBox(width: 10),
        Expanded(child: _devCard('FAN 3', fan3On, Icons.air_rounded, Colors.teal, () { if (_tankFull) return; setState(() => fan3On = !fan3On); _sendCommand('FAN3:${fan3On ? 'ON' : 'OFF'}'); })),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _devCard('HEATER', heaterOn, Icons.local_fire_department_rounded, Colors.orange, () { if (_tankFull) return; setState(() => heaterOn = !heaterOn); _sendCommand('HEATER:${heaterOn ? 'ON' : 'OFF'}'); })),
        const SizedBox(width: 10),
        Expanded(child: _devCard('DEHUM', dehumOn, Icons.opacity_rounded, Colors.blue, () { if (_tankFull) return; setState(() => dehumOn = !dehumOn); _sendCommand('DEHUM:${dehumOn ? 'ON' : 'OFF'}'); })),
      ]),
    ]);
  }

  Widget _buildMasterControl() {
    bool locked = _tankFull;
    return GestureDetector(
      onTap: locked ? null : _masterToggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
        decoration: BoxDecoration(
          color: locked ? AppColors.alertRed.withOpacity(0.08) : _masterOn ? AppColors.activeGreen.withOpacity(0.1) : _card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: locked ? AppColors.alertRed.withOpacity(0.3) : _masterOn ? AppColors.activeGreen.withOpacity(0.4) : _accent.withOpacity(0.15), width: 1.5),
        ),
        child: Row(children: [
          Container(width: 56, height: 56,
            decoration: BoxDecoration(
              color: locked ? AppColors.alertRed.withOpacity(0.15) : _masterOn ? AppColors.activeGreen.withOpacity(0.15) : _accent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16)),
            child: Icon(locked ? Icons.lock_rounded : Icons.power_settings_new_rounded,
              color: locked ? AppColors.alertRed : _masterOn ? AppColors.activeGreen : _accent, size: 28)),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Master Control', style: TextStyle(color: _textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(locked ? 'Locked \u2014 Tank full' : _masterOn ? 'All devices ON \u2014 Tap to shut down' : 'All devices OFF \u2014 Tap to start',
              style: TextStyle(color: _textSecondary, fontSize: 12)),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: locked ? AppColors.alertRed.withOpacity(0.2) : _masterOn ? AppColors.activeGreen.withOpacity(0.2) : _accent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20)),
            child: Text(locked ? 'LOCKED' : _masterOn ? 'ON' : 'OFF',
              style: TextStyle(color: locked ? AppColors.alertRed : _masterOn ? AppColors.activeGreen : _accent, fontWeight: FontWeight.w700, fontSize: 12)),
          ),
        ]),
      ),
    );
  }

  Widget _devCard(String name, bool on, IconData icon, Color activeColor, VoidCallback onTap) {
    bool locked = _tankFull;
    return GestureDetector(
      onTap: locked ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: locked ? AppColors.alertRed.withOpacity(0.06) : on ? activeColor.withOpacity(0.08) : _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: locked ? AppColors.alertRed.withOpacity(0.25) : on ? activeColor.withOpacity(0.4) : _accent.withOpacity(0.1)),
        ),
        child: Column(children: [
          Icon(icon, color: locked ? AppColors.alertRed.withOpacity(0.5) : on ? activeColor : _accent, size: 28),
          const SizedBox(height: 10),
          Text(name, style: TextStyle(color: _textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: locked ? AppColors.alertRed.withOpacity(0.15) : on ? activeColor.withOpacity(0.15) : _accent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10)),
            child: Text(locked ? 'LOCKED' : on ? 'ON' : 'OFF',
              style: TextStyle(color: locked ? AppColors.alertRed : on ? activeColor : _accent, fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }
  // ======== TAB 4: LOGS ========
  Widget _buildLogsTab() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0), child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('System Logs', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _textPrimary, letterSpacing: -0.5)),
          const SizedBox(height: 4),
          Text('${_log.length} entries', style: TextStyle(color: _textSecondary, fontSize: 13)),
        ])),
        GestureDetector(
          onTap: () => setState(() => _log.clear()),
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
            child: Text('Clear', style: TextStyle(color: _textSecondary, fontSize: 12, fontWeight: FontWeight.w500))),
        ),
      ])),
      const SizedBox(height: 12),
      Expanded(child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
        child: _log.isEmpty
          ? Center(child: Text('No logs yet', style: TextStyle(color: _textSecondary, fontSize: 13)))
          : ListView.builder(itemCount: _log.length, itemBuilder: (ctx, i) {
              String entry = _log[i];
              Color lc = _textSecondary;
              if (entry.contains('error') || entry.contains('REJECT') || entry.contains('TANK FULL')) lc = AppColors.alertRed.withOpacity(0.8);
              else if (entry.contains('ACK') || entry.contains('OK') || entry.contains('updated') || entry.contains('Connected')) lc = AppColors.activeGreen;
              else if (entry.contains('TX:') || entry.contains('SENT:')) lc = AppColors.amber;
              return Padding(padding: const EdgeInsets.only(bottom: 4),
                child: Text(entry, style: TextStyle(color: lc, fontSize: 11, fontFamily: 'monospace', height: 1.4)));
            }),
      )),
      const SizedBox(height: 12),
    ]);
  }
}