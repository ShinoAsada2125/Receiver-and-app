import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';

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
  late StreamSubscription<DiscoveredDevice> _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

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

  @override
  void initState() {
    super.initState();
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
    _logAdd('Scanning for $bleDeviceName...');
    _scanSub = _ble.scanForDevices(withServices: [serviceUuid]).listen((device) {
      if ((device.name == bleDeviceName || device.name.contains('LoRaReceiver')) && _deviceId == null) {
        _logAdd('Found ${device.name} (${device.id})');
        _scanSub.cancel();
        _deviceId = device.id;
        _connectToDevice(device.id);
      }
    }, onError: (e) {
      _logAdd('Scan error: $e');
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
        // restart scanning
        Future.delayed(const Duration(seconds: 1), () => _startScan());
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
      _logAdd('RX: $s');
      _handleIncoming(s);
    }, onError: (e) {
      _logAdd('Notify error: $e');
    });
  }

  void _handleIncoming(String s) {
    s = s.trim();
    try {
      if (s.startsWith('{')) {
        final m = jsonDecode(s);
        // assume it's the sensor JSON from receiver
        setState(() {
          for (var k in m.keys) {
                    if (sensor.containsKey(k)) {
                      sensor[k] = m[k];
                    } else {
                      // some fields like rssi/sn may be inside
                      sensor[k] = m[k];
                    }
          }
        });
      } else if (s.startsWith('WT1')) {
        // CSV from transmitter (fallback)
        List<String> parts = s.split(',');
        if (parts.length >= 10) {
          setState(() {
            sensor['temp1'] = double.tryParse(parts[1]) ?? sensor['temp1'];
            sensor['humid1'] = double.tryParse(parts[2]) ?? sensor['humid1'];
            sensor['temp2'] = double.tryParse(parts[3]) ?? sensor['temp2'];
            sensor['humid2'] = double.tryParse(parts[4]) ?? sensor['humid2'];
            sensor['water_level'] = double.tryParse(parts[5]) ?? sensor['water_level'];
            sensor['volume'] = double.tryParse(parts[6]) ?? sensor['volume'];
            sensor['percent'] = double.tryParse(parts[7]) ?? sensor['percent'];
            sensor['packet'] = int.tryParse(parts[8]) ?? sensor['packet'];
            sensor['tank_full'] = parts[9] == '1';
            sensor['timestamp'] = DateTime.now().toIso8601String();
          });
        }
      } else if (s.startsWith('REJECT:')) {
        // REJECT:<command>:<REASON>
        var parts = s.split(':');
        String cmd = parts.length > 1 ? parts[1] : '';
        String reason = parts.length > 2 ? parts.sublist(2).join(':') : '';
        _logAdd('Command rejected: $cmd ($reason)');
        // You could surface this in UI
      } else if (s.startsWith('ACKCMD:') || s.startsWith('ACK:')) {
        _logAdd('ACK: $s');
      } else {
        _logAdd('Unhandled message: $s');
      }
    } catch (e) {
      _logAdd('Parse error: $e');
    }
  }

  void _sendCommand(String cmd) async {
    if (!_connected || _deviceId == null) {
      _logAdd('Not connected');
      return;
    }
    _logAdd('TX: $cmd');
    try {
      await _ble.writeCharacteristicWithResponse(QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: rxChar, deviceId: _deviceId!), value: utf8.encode(cmd));
    } catch (e) {
      _logAdd('Write error: $e');
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
    _scanSub.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
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
                  _connSub?.cancel();
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
                _sensorTile('Water Level (cm)', 'water_level'),
                _sensorTile('Volume (L)', 'volume'),
                _sensorTile('Percent (%)', 'percent'),
                _sensorTile('Packet #', 'packet'),
                _sensorTile('Tank Full', 'tank_full'),
                _sensorTile('RSSI', 'rssi'),
                _sensorTile('SNR', 'snr'),
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
                            String cmd = 'DEV:HEATER=${heaterOn ? '1' : '0'}';
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
                            String cmd = 'DEV:DEHUM=${dehumOn ? '1' : '0'}';
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
