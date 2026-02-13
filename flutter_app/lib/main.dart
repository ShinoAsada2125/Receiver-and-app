import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';
import 'dart:math'; 

// Ignore some info-level analyzer suggestions in this file
// (prefer_const_constructors and sized_box_for_whitespace are informational)
// ignore_for_file: prefer_const_constructors, sized_box_for_whitespace

void main() => runApp(const MyApp());

const String bleDeviceName = 'LoRaReceiver';
final Uuid serviceUuid = Uuid.parse('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
final Uuid txChar = Uuid.parse('6E400003-B5A3-F393-E0A9-E50E24DCCA9E'); // notify -> app
final Uuid rxChar = Uuid.parse('6E400002-B5A3-F393-E0A9-E50E24DCCA9E'); // write <- app

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoRa Receiver Dashboard',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const Dashboard(),
    );
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({Key? key}) : super(key: key);

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BleStatus>? _bleStatusSub;


  String? _deviceId;
  bool _connected = false;
  String _status = 'Idle';

  Map<String, dynamic> sensor = {
    'temp1': null,
    'humid1': null,
    'temp2': null,
    'humid2': null,
    'water_level': null,
    'volume': null,
    'percent': null,
    'packet': null,
    'tank_full': null,
    'rssi': null,
    'snr': null,
    'timestamp': null,
  };

  final List<String> _log = [];
  final TextEditingController _cmdController = TextEditingController();
  bool heaterOn = false;
  bool dehumOn = false;
  
  // Message buffering for incomplete JSON (BLE fragmentation)
  String _messageBuffer = '';

  @override
  void initState() {
    super.initState();
    // Watch BLE adapter state so UI can show why scans fail
    _bleStatusSub = _ble.statusStream.listen((status) {
      String s;
      switch (status) {
        case BleStatus.ready:
          s = _connected ? 'Connected' : 'Idle';
          break;
        case BleStatus.poweredOff:
          s = 'Bluetooth disabled';
          break;
        case BleStatus.unauthorized:
          s = 'Bluetooth unauthorized';
          break;
        case BleStatus.unsupported:
          s = 'Bluetooth unsupported';
          break;
        case BleStatus.locationServicesDisabled:
          s = 'Location services disabled';
          break;
        default:
          s = 'BLE: $status';
      }
      setState(() {
        _status = s;
      });
      _logAdd('BLE adapter: $status');
    });

    _ensurePermissionsAndStart();
  }

  Future<void> _ensurePermissionsAndStart() async {
    bool granted = true;
    try {
      if (Platform.isAndroid) {
        // Android 12+ specific Bluetooth permissions
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetooth,
          Permission.locationWhenInUse,
        ].request();
        granted = statuses.values.every((s) => s.isGranted);
      } else if (Platform.isIOS) {
        final status = await Permission.bluetooth.request();
        granted = status.isGranted;
      }
    } catch (e) {
      _logAdd('Permission request error: $e');
      granted = false;
    }

    if (granted) {
      _startScan();
    } else {
      setState(() {
        _status = 'Permissions required';
      });
      _logAdd('Required permissions not granted. Open app settings to grant.');
    }
  }

 void _startScan() {
  _ble.scanForDevices(withServices: [serviceUuid]); // ← UUID filter REQUIRED
  // Cancel any existing scan first
  _scanSub?.cancel();
  _scanSub = null;
  
  // Wait for BLE adapter to be fully ready (critical after power cycle)
  _ble.statusStream.firstWhere((status) => status == BleStatus.ready).then((_) {
    _logAdd('🔍 Starting UUID-filtered scan for LoRaReceiver...');
    
    // ===== PHASE 1: FILTERED SCAN (Primary method - avoids random devices) =====
    _scanSub = _ble.scanForDevices(
      withServices: [serviceUuid], // ONLY scan devices with OUR service UUID
      scanMode: ScanMode.lowLatency,
    ).listen((device) {
      String name = device.name.isNotEmpty ? device.name : 'N/A';
      
      // Double-verify: name MUST match AND have our service
      if ((_deviceId == null) && name == bleDeviceName) {
        _logAdd('✓ Target found via UUID filter: $name (${device.id}) RSSI:${device.rssi}');
        _scanSub?.cancel();
        _scanSub = null;
        _deviceId = device.id;
        _connectToDevice(device.id);
      }
    }, onError: (e) {
      _logAdd('Filtered scan error: $e');
    });
    
    // ===== FALLBACK: If no device found after 5s, try unfiltered scan =====
    Future.delayed(const Duration(seconds: 5), () {
      if (_deviceId == null && _scanSub != null) {
        _scanSub?.cancel();
        _scanSub = null;
        _logAdd('⚠️ UUID scan timeout - trying name-based fallback...');
        
        // Unfiltered scan but filter by NAME in callback
        _scanSub = _ble.scanForDevices(withServices: []).listen((device) {
          if ((_deviceId == null) && device.name == bleDeviceName) {
            _logAdd('✓ Found via name fallback: ${device.name} (${device.id})');
            _scanSub?.cancel();
            _scanSub = null;
            _deviceId = device.id;
            _connectToDevice(device.id);
          }
        }, onError: (e) => _logAdd('Fallback scan error: $e'));
        
        // Final timeout: stop scan after 10s total to save battery
        Future.delayed(const Duration(seconds: 10), () {
          if (_scanSub != null && _deviceId == null) {
            _scanSub?.cancel();
            _scanSub = null;
            _logAdd('⏱️ Scan failed after 15s total - retrying...');
            Future.delayed(const Duration(seconds: 2), () {
              if (!_connected) _startScan(); // Auto-retry
            });
          }
        });
      }
    });
  }).catchError((e) {
    _logAdd('BLE not ready: $e');
    Future.delayed(const Duration(seconds: 2), () {
      if (!_connected) _startScan();
    });
  });
}

  void _connectToDevice(String id) {
    setState(() {
      _status = 'Connecting...';
    });
    _connSub = _ble.connectToDevice(id: id, connectionTimeout: const Duration(seconds: 10)).listen((event) {
      if (event.connectionState == DeviceConnectionState.connected) {
        _logAdd('Connected to device');
        setState(() {
          _connected = true;
          _status = 'Connected';
        });
        _startNotify(id);
      } else if (event.connectionState == DeviceConnectionState.disconnected) {
        _logAdd('Disconnected');
        setState(() {
          _connected = false;
          _status = 'Disconnected';
        });
        _deviceId = null;
        _notifySub?.cancel();
        // NOTE: Auto-rescanning disabled - user must click Scan to reconnect
      }
    }, onError: (e) {
      _logAdd('Connection error: $e');
      setState(() {
        _status = 'Connection error';
      });
    });
  }

  void _startNotify(String id) {
    _notifySub = _ble
      .subscribeToCharacteristic(QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: txChar, deviceId: id))
        .listen((data) {
      String s = utf8.decode(data);
      String display = s.length > 60 ? s.substring(0, 60) + '...' : s;
      _logAdd('📨 RX (${data.length}B): $display');
      _handleIncoming(s);
    }, onError: (e) {
      _logAdd('❌ Notify error: $e');
    });
  }

 void _handleIncoming(String s) {
  // CRITICAL: BLE fragments use NEWLINE as packet boundary (ESP32 MUST send '\n')
  _messageBuffer += s;
  
  // Process ALL complete messages (handles back-to-back transmissions)
  while (_messageBuffer.contains('\n')) {
    int newlineIndex = _messageBuffer.indexOf('\n');
    String completeMsg = _messageBuffer.substring(0, newlineIndex).trim();
    _messageBuffer = _messageBuffer.substring(newlineIndex + 1);
    
    if (completeMsg.isEmpty) continue;
    
    // DEBUG: Log complete message size
    _logAdd('📦 Complete (${completeMsg.length}B): ${completeMsg.substring(0, min(completeMsg.length, 40))}...');
    
    // JSON sensor data
    if (completeMsg.startsWith('{') && completeMsg.endsWith('}')) {
      try {
        final m = jsonDecode(completeMsg);
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
          sensor['rssi'] = (m['rssi'] as num?)?.toDouble() ?? sensor['rssi'] ?? 0.0;
          sensor['snr'] = (m['snr'] as num?)?.toDouble() ?? sensor['snr'] ?? 0.0;
          sensor['timestamp'] = DateTime.now().toIso8601String();
        });
        _logAdd('✅ UI updated');
      } catch (e) {
        _logAdd('❌ JSON error: $e | Data: ${completeMsg.substring(0, min(completeMsg.length, 100))}');
      }
    } 
    // Command responses
    else if (completeMsg.startsWith('ACKCMD:') || completeMsg.startsWith('REJECT:')) {
      _logAdd('📨 ${completeMsg.startsWith('REJECT:') ? '❌' : '✓'} $completeMsg');
    }
    // Simplified CSV fallback (6 fields: T1,H1,T2,H2,VOL,TANK)
    else if (RegExp(r'^[\d.-]+,[\d.-]+,[\d.-]+,[\d.-]+,[\d.-]+,[01]$').hasMatch(completeMsg)) {
      _logAdd('📊 CSV (simplified): $completeMsg');
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
        _logAdd('✓ CSV parsed: T1=${sensor['temp1']}°C, Vol=${sensor['volume']}L');
      }
    }
  }
  
  // Safety: Prevent buffer overflow
  if (_messageBuffer.length > 500) {
    _logAdd('⚠️ Buffer overflow - cleared ${_messageBuffer.length} chars');
    _messageBuffer = '';
  }
}

  void _sendCommand(String cmd) async {
    if (!_connected || _deviceId == null) {
      _logAdd('❌ Not connected to device');
      return;
    }
    if (cmd.isEmpty) {
      _logAdd('❌ Empty command');
      return;
    }
    _logAdd('📤 TX: $cmd');
    try {
      await _ble.writeCharacteristicWithResponse(
        QualifiedCharacteristic(
          serviceId: serviceUuid,
          characteristicId: rxChar,
          deviceId: _deviceId!
        ),
        value: utf8.encode(cmd)
      );
      _logAdd('✓ Command sent');
    } catch (e) {
      _logAdd('❌ Write error: $e');
    }
  }

  void _logAdd(String s) {
    setState(() {
      _log.insert(0, '[${DateTime.now().toIso8601String()}] $s');
      if (_log.length > 200) _log.removeLast();
    });
  }

  


  @override
  void dispose() {
    _scanSub?.cancel();
    _scanSub = null;
    _connSub?.cancel();
    _connSub = null;
    _notifySub?.cancel();
    _notifySub = null;
    _bleStatusSub?.cancel();
    _bleStatusSub = null;
    _cmdController.dispose();
    super.dispose();
  }

  Widget _sensorTile(String label, String key) {
    return ListTile(
      title: Text(label),
      trailing: Text(sensor[key]?.toString() ?? '-'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LoRa Receiver Dashboard')),
      body: Column(
        children: [
          ListTile(
            title: const Text('Status'),
            subtitle: Text(_status),
            trailing: ElevatedButton(
  child: Text(_connected ? 'Disconnect' : 'Scan'),
  onPressed: () {
  if (_connected && _deviceId != null) {
    _logAdd('📴 Disconnecting...');
    
    // 1. Cancel characteristic notification subscription FIRST
    _notifySub?.cancel();
    _notifySub = null;
    
    // 2. Cancel connection subscription (this triggers actual BLE disconnect)
    _connSub?.cancel();
    _connSub = null;
    
    // 3. Update UI state after short delay (allows OS to process disconnect)
    Future.delayed(const Duration(milliseconds: 500), () {
      setState(() {
        _connected = false;
        _status = 'Disconnected';
        _deviceId = null;
      });
      _logAdd('✓ Disconnected');
      // NOTE: Auto-rescanning disabled - user must click Scan to reconnect
    });
  } else {
    _startScan();
  }
},
),
          ),
          Expanded(
            child: ListView(
              children: [
                _sensorTile('Temp1 (°C)', 'temp1'),
                _sensorTile('Humid1 (%)', 'humid1'),
                _sensorTile('Temp2 (°C)', 'temp2'),
                _sensorTile('Humid2 (%)', 'humid2'),
                _sensorTile('Volume (L)', 'volume'),
                _sensorTile('Tank Full', 'tank_full'),
                _sensorTile('RSSI (dBm)', 'rssi'),
                _sensorTile('SNR (dB)', 'snr'),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          child: Text(heaterOn ? 'HEATER OFF' : 'HEATER ON'),
                          onPressed: () {
                            heaterOn = !heaterOn;
                            String cmd = 'HEATER:${heaterOn ? 'ON' : 'OFF'}';
                            _sendCommand(cmd);
                            setState(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          child: Text(dehumOn ? 'DEHUM OFF' : 'DEHUM ON'),
                          onPressed: () {
                            dehumOn = !dehumOn;
                            String cmd = 'DEHUM:${dehumOn ? 'ON' : 'OFF'}';
                            _sendCommand(cmd);
                            setState(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _cmdController,
                          decoration: InputDecoration(border: OutlineInputBorder(), hintText: 'Custom command (e.g. GPIO12=1)'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        child: const Text('Send'),
                        onPressed: () {
                          String c = _cmdController.text.trim();
                          if (c.isNotEmpty) {
                            _sendCommand(c);
                            _cmdController.clear();
                          }
                        },
                      )
                    ],
                  ),
                ),
                const Divider(),
                const SizedBox(height: 8),
                const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
                Container(
                  height: 200,
                  child: ListView.builder(
                    itemCount: _log.length,
                    itemBuilder: (c, i) => Text(_log[i], style: const TextStyle(fontSize: 12)),
                  ),
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}
