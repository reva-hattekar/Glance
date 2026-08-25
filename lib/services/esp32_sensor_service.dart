import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'glance_ble_coordinator.dart';

enum Esp32ConnectionStatus {
  initializing,
  permissionRequired,
  bluetoothOff,
  scanning,
  connecting,
  connected,
  disconnected,
  error,
}

/// Manages the automatic BLE connection between the Glance app and the Glance ESP32 device,
/// streaming continuous VL53L4CD distance readings and synchronizing the alarm state.
class Esp32SensorService {
  Esp32SensorService._();
  static final Esp32SensorService instance = Esp32SensorService._();

  static const String esp32DeviceName = 'Glance-ESP32';
  static const String legacyDeviceName = 'SafeSight-ESP32';
  static const String serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const String charDistanceUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
  static const String charCommandUuid = '1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e';

  final _statusController = StreamController<Esp32ConnectionStatus>.broadcast();
  final _distanceController = StreamController<double?>.broadcast();

  Stream<Esp32ConnectionStatus> get statusStream => _statusController.stream;
  Stream<double?> get distanceStream => _distanceController.stream;

  Esp32ConnectionStatus _status = Esp32ConnectionStatus.initializing;
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _commandChar;
  BluetoothCharacteristic? _distanceChar;
  StreamSubscription<List<int>>? _distanceSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<GlanceBleState>? _bleStateSub;

  double? _lastValidDistanceMeters;
  DateTime? _lastReadingTime;
  bool _isAlarmDesired = false;
  bool _running = false;
  bool _isConnecting = false;

  Esp32ConnectionStatus get status => _status;
  bool get isConnected => _status == Esp32ConnectionStatus.connected;
  String? get connectedDeviceId => _connectedDevice?.remoteId.str;
  bool get isAlarmDesired => _isAlarmDesired;

  /// Returns whether the sensor has a fresh valid reading within the last 2 seconds.
  bool get isReadingFresh {
    if (_lastReadingTime == null) return false;
    return DateTime.now().difference(_lastReadingTime!).inMilliseconds <= 2000;
  }

  /// Returns the current physical distance in meters if connected, fresh, and valid.
  /// Returns null if disconnected, stale, or reporting an invalid measurement.
  double? get currentDistanceMeters {
    if (!isConnected || !isReadingFresh) return null;
    return _lastValidDistanceMeters;
  }

  void _setStatus(Esp32ConnectionStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  void _emitDistance(double? d) {
    if (!_distanceController.isClosed) _distanceController.add(d);
  }

  /// Starts the auto-discovery and connection manager for Glance ESP32.
  Future<void> start() async {
    if (_running || kIsWeb) return;
    _running = true;
    _isAlarmDesired = false;
    _lastValidDistanceMeters = null;
    _lastReadingTime = null;

    _setStatus(Esp32ConnectionStatus.initializing);

    // Listen to the central BLE coordinator state transitions
    _bleStateSub?.cancel();
    _bleStateSub = GlanceBleCoordinator.instance.stateStream.listen((state) {
      if (isConnected) return;

      switch (state) {
        case GlanceBleState.initializing:
          _setStatus(Esp32ConnectionStatus.initializing);
          break;
        case GlanceBleState.permissionRequired:
          _setStatus(Esp32ConnectionStatus.permissionRequired);
          break;
        case GlanceBleState.bluetoothOff:
          _setStatus(Esp32ConnectionStatus.bluetoothOff);
          break;
        case GlanceBleState.scanning:
          if (!isConnected && !_isConnecting) {
            _setStatus(Esp32ConnectionStatus.scanning);
            _checkAlreadyConnectedDevices();
          }
          break;
        case GlanceBleState.error:
          _setStatus(Esp32ConnectionStatus.error);
          break;
        case GlanceBleState.uninitialized:
          break;
      }
    });

    // Listen to shared scan results on every incoming packet batch
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen(_handleScanResults);

    // Initialize BLE if not already started
    if (GlanceBleCoordinator.instance.state == GlanceBleState.uninitialized ||
        GlanceBleCoordinator.instance.state == GlanceBleState.permissionRequired) {
      await GlanceBleCoordinator.instance.initializeAndStartScan();
    } else if (GlanceBleCoordinator.instance.state == GlanceBleState.scanning) {
      _setStatus(Esp32ConnectionStatus.scanning);
      _checkAlreadyConnectedDevices();
    }
  }

  void _checkAlreadyConnectedDevices() {
    try {
      final connectedDevices = FlutterBluePlus.connectedDevices;
      for (final dev in connectedDevices) {
        final name = dev.platformName.isNotEmpty ? dev.platformName : dev.advName;
        debugPrint('[GLANCE ESP32] Checking connected device: "$name" (${dev.remoteId.str})');
        if (name.toLowerCase().contains('glance') || name.toLowerCase().contains('safesight')) {
          debugPrint('[GLANCE ESP32] MATCHED ALREADY-CONNECTED DEVICE: $name (${dev.remoteId.str})');
          connectToDevice(dev);
          return;
        }
      }
    } catch (e) {
      debugPrint('[GLANCE ESP32] Error checking connected devices: $e');
    }
  }

  bool _isGlanceEsp32(ScanResult r) {
    final advName = r.advertisementData.advName.trim();
    final platName = r.device.platformName.trim();
    final devAdvName = r.device.advName.trim();

    // 1. Primary check: Dedicated 128-bit Service UUID
    final matchesServiceUuid = r.advertisementData.serviceUuids.any((u) {
      final clean = u.toString().replaceAll('-', '').toLowerCase();
      return clean.contains('4fafc2011fb5459e8fccc5c9c331914b') || clean.contains('4fafc201');
    });

    if (matchesServiceUuid) return true;

    // 2. Secondary check: Name matching
    final namesToCheck = [advName, platName, devAdvName];
    for (final n in namesToCheck) {
      if (n.isNotEmpty) {
        final lower = n.toLowerCase();
        if (lower == 'glance-esp32' ||
            lower == 'safesight-esp32' ||
            lower.contains('glance-esp') ||
            lower.contains('glance_esp') ||
            lower.contains('safesight-esp') ||
            lower == 'glance') {
          return true;
        }
      }
    }

    return false;
  }

  void _handleScanResults(List<ScanResult> results) {
    if (!_running || isConnected || _isConnecting) return;

    for (final r in results) {
      final isMatch = _isGlanceEsp32(r);
      final advName = r.advertisementData.advName;
      final platName = r.device.platformName;
      final uuids = r.advertisementData.serviceUuids.map((u) => u.toString()).toList();

      debugPrint('[GLANCE BLE] Scan result: id=${r.device.remoteId.str} | platName="$platName" | advName="$advName" | services=$uuids | match=$isMatch');

      if (isMatch) {
        debugPrint('[GLANCE ESP32] MATCHED DEVICE: platName="$platName" advName="$advName" (${r.device.remoteId.str})');
        connectToDevice(r.device);
        break;
      }
    }
  }

  /// Explicitly connects to a detected or targeted BluetoothDevice with direct autoConnect: false.
  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_isConnecting || isConnected) {
      debugPrint('[GLANCE ESP32] Connect skipped (isConnecting=$_isConnecting, isConnected=$isConnected)');
      return;
    }
    _isConnecting = true;
    _connectedDevice = device;
    _setStatus(Esp32ConnectionStatus.connecting);

    debugPrint('[GLANCE ESP32] Starting connection to ${device.remoteId.str} (autoConnect: false)...');

    try {
      // Connect directly without OS autoConnect delay
      await device.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );

      debugPrint('[GLANCE ESP32] CONNECTED');
      debugPrint('[GLANCE ESP32] Discovering services...');

      // Listen for connection state changes (disconnection / reconnect)
      await _connStateSub?.cancel();
      _connStateSub = device.connectionState.listen((state) {
        debugPrint('[GLANCE ESP32] Connection state: $state');
        if (state == BluetoothConnectionState.connected) {
          _setStatus(Esp32ConnectionStatus.connected);
          if (_isAlarmDesired) {
            sendAlarmOn();
          }
        } else if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      final services = await device.discoverServices();
      debugPrint('[GLANCE ESP32] Services discovered: ${services.length}');

      BluetoothService? targetService;

      for (final s in services) {
        final cleanUuid = s.uuid.toString().replaceAll('-', '').toLowerCase();
        debugPrint('[GLANCE ESP32]   Service: ${s.uuid}');
        for (final c in s.characteristics) {
          debugPrint('[GLANCE ESP32]     Char: ${c.uuid} (read=${c.properties.read}, write=${c.properties.write}, notify=${c.properties.notify})');
        }

        if (cleanUuid.contains('4fafc2011fb5459e8fccc5c9c331914b') || cleanUuid.contains('4fafc201')) {
          targetService = s;
        }
      }

      if (targetService == null) {
        debugPrint('[GLANCE ESP32] Warning: Glance custom service (4fafc201...) not found on device.');
        // Fallback: search all characteristics across all services
        for (final s in services) {
          for (final c in s.characteristics) {
            final charUuid = c.uuid.toString().replaceAll('-', '').toLowerCase();
            if (charUuid.contains('beb5483e')) {
              _distanceChar = c;
              debugPrint('[GLANCE ESP32] Distance characteristic found in fallback service: ${s.uuid}');
            } else if (charUuid.contains('1c95d5e3')) {
              _commandChar = c;
              debugPrint('[GLANCE ESP32] Command characteristic found in fallback service: ${s.uuid}');
            }
          }
        }
      } else {
        for (final c in targetService.characteristics) {
          final charUuid = c.uuid.toString().replaceAll('-', '').toLowerCase();
          if (charUuid.contains('beb5483e')) {
            _distanceChar = c;
            debugPrint('[GLANCE ESP32] Distance characteristic found');
          } else if (charUuid.contains('1c95d5e3')) {
            _commandChar = c;
            debugPrint('[GLANCE ESP32] Command characteristic found');
          }
        }
      }

      if (_distanceChar != null) {
        await _distanceChar!.setNotifyValue(true);
        await _distanceSub?.cancel();
        _distanceSub = _distanceChar!.lastValueStream.listen(_handleDistancePacket);
        debugPrint('[GLANCE ESP32] Notifications enabled on distance characteristic');
      } else {
        debugPrint('[GLANCE ESP32] Warning: Distance characteristic beb5483e... not found!');
      }

      _setStatus(Esp32ConnectionStatus.connected);
      debugPrint('[GLANCE ESP32] READY');

      if (_isAlarmDesired) {
        await sendAlarmOn();
      }
    } catch (e, stack) {
      debugPrint('[GLANCE ESP32] CONNECTION ERROR: $e');
      debugPrint('[GLANCE ESP32] Stack trace: $stack');
      _onDisconnected();
    } finally {
      _isConnecting = false;
    }
  }

  /// Manual trigger to search all visible devices and connect directly to Glance-ESP32.
  Future<bool> manualConnectDebug() async {
    debugPrint('[GLANCE ESP32 DEBUG] Manual connect requested...');
    try {
      final lastResults = FlutterBluePlus.lastScanResults;
      debugPrint('[GLANCE ESP32 DEBUG] Total scan results in memory: ${lastResults.length}');

      for (final r in lastResults) {
        final isMatch = _isGlanceEsp32(r);
        debugPrint('[GLANCE ESP32 DEBUG] Device: "${r.device.platformName}" / "${r.advertisementData.advName}" (${r.device.remoteId.str}) -> Match: $isMatch');
        if (isMatch) {
          debugPrint('[GLANCE ESP32 DEBUG] Found match! Initiating direct connection...');
          await connectToDevice(r.device);
          return true;
        }
      }

      // Check connected devices by OS
      final connected = FlutterBluePlus.connectedDevices;
      debugPrint('[GLANCE ESP32 DEBUG] Total connected devices by OS: ${connected.length}');
      for (final dev in connected) {
        final name = dev.platformName.isNotEmpty ? dev.platformName : dev.advName;
        debugPrint('[GLANCE ESP32 DEBUG] Connected OS Device: "$name" (${dev.remoteId.str})');
        if (name.toLowerCase().contains('glance') || name.toLowerCase().contains('safesight')) {
          debugPrint('[GLANCE ESP32 DEBUG] Found match in OS connected devices! Connecting...');
          await connectToDevice(dev);
          return true;
        }
      }

      debugPrint('[GLANCE ESP32 DEBUG] No matching Glance ESP32 found in recent scan results.');
      return false;
    } catch (e) {
      debugPrint('[GLANCE ESP32 DEBUG] Error during manual connect: $e');
      return false;
    }
  }

  void _handleDistancePacket(List<int> bytes) {
    if (bytes.isEmpty) return;

    try {
      bool isValid = false;
      int distanceMm = 0;

      if (bytes.length >= 3) {
        final statusByte = bytes[0];
        distanceMm = (bytes[1] << 8) | bytes[2];
        isValid = (statusByte == 0x00) && (distanceMm > 10 && distanceMm <= 4000);
      } else if (bytes.length == 2) {
        distanceMm = (bytes[0] << 8) | bytes[1];
        isValid = distanceMm > 10 && distanceMm <= 4000;
      } else {
        final str = utf8.decode(bytes).trim();
        final parsed = int.tryParse(str);
        if (parsed != null && parsed > 10 && parsed <= 4000) {
          distanceMm = parsed;
          isValid = true;
        }
      }

      if (isValid) {
        final distanceMeters = distanceMm / 1000.0;
        _lastValidDistanceMeters = distanceMeters;
        _lastReadingTime = DateTime.now();
        _emitDistance(distanceMeters);
      } else {
        _lastValidDistanceMeters = null;
        _emitDistance(null);
      }
    } catch (e) {
      debugPrint('[GLANCE ESP32] Error parsing distance packet: $e');
    }
  }

  void _onDisconnected() {
    debugPrint('[GLANCE ESP32] DISCONNECTED');
    _setStatus(Esp32ConnectionStatus.disconnected);
    _lastValidDistanceMeters = null;
    _emitDistance(null);
    _distanceSub?.cancel();
    _distanceSub = null;
    _isConnecting = false;

    if (_running) {
      debugPrint('[GLANCE ESP32] Retrying discovery in 2s...');
      Future.delayed(const Duration(seconds: 2), () {
        if (_running && !isConnected && !_isConnecting) {
          _setStatus(Esp32ConnectionStatus.scanning);
          _checkAlreadyConnectedDevices();
        }
      });
    }
  }

  /// Sends ALARM_ON command to the ESP32 to activate the vibration motor.
  Future<void> sendAlarmOn() async {
    _isAlarmDesired = true;
    debugPrint('[GLANCE ALARM] Sending ALARM_ON to ESP32');

    if (_commandChar != null && isConnected) {
      try {
        await _commandChar!.write(utf8.encode('ALARM_ON'), withoutResponse: false);
        debugPrint('[GLANCE ALARM] ALARM_ON WRITE SUCCESS');
      } catch (e) {
        debugPrint('[GLANCE ALARM] ALARM_ON WRITE FAILED: $e');
        try {
          await _commandChar!.write(utf8.encode('ALARM_ON'), withoutResponse: true);
          debugPrint('[GLANCE ALARM] ALARM_ON WRITE (withoutResponse) SUCCESS');
        } catch (e2) {
          debugPrint('[GLANCE ALARM] ALARM_ON WRITE (withoutResponse) FAILED: $e2');
        }
      }
    } else {
      debugPrint('[GLANCE ALARM] ESP32 not connected; will send ALARM_ON upon reconnect.');
    }
  }

  /// Sends ALARM_OFF command to the ESP32 to stop the vibration motor.
  Future<void> sendAlarmOff() async {
    _isAlarmDesired = false;
    debugPrint('[GLANCE ALARM] Sending ALARM_OFF');

    if (_commandChar != null && isConnected) {
      try {
        await _commandChar!.write(utf8.encode('ALARM_OFF'), withoutResponse: false);
        debugPrint('[GLANCE ALARM] ALARM_OFF WRITE SUCCESS');
      } catch (e) {
        debugPrint('[GLANCE ALARM] ALARM_OFF WRITE FAILED: $e');
        try {
          await _commandChar!.write(utf8.encode('ALARM_OFF'), withoutResponse: true);
          debugPrint('[GLANCE ALARM] ALARM_OFF WRITE (withoutResponse) SUCCESS');
        } catch (e2) {
          debugPrint('[GLANCE ALARM] ALARM_OFF WRITE (withoutResponse) FAILED: $e2');
        }
      }
    }
  }

  /// Sends MOTOR_TEST command to test the ESP32 physical vibration circuit.
  Future<bool> sendMotorTest() async {
    debugPrint('[GLANCE ALARM] Sending MOTOR_TEST to ESP32');

    if (_commandChar != null && isConnected) {
      try {
        await _commandChar!.write(utf8.encode('MOTOR_TEST'), withoutResponse: false);
        debugPrint('[GLANCE ALARM] MOTOR_TEST WRITE SUCCESS');
        return true;
      } catch (e) {
        debugPrint('[GLANCE ALARM] MOTOR_TEST WRITE FAILED: $e');
        try {
          await _commandChar!.write(utf8.encode('MOTOR_TEST'), withoutResponse: true);
          debugPrint('[GLANCE ALARM] MOTOR_TEST WRITE (withoutResponse) SUCCESS');
          return true;
        } catch (e2) {
          debugPrint('[GLANCE ALARM] MOTOR_TEST WRITE (withoutResponse) FAILED: $e2');
          return false;
        }
      }
    } else {
      debugPrint('[GLANCE ALARM] Cannot send MOTOR_TEST (ESP32 is not connected)');
      return false;
    }
  }

  /// Cleanly stops the service.
  Future<void> stop() async {
    _running = false;
    _isAlarmDesired = false;
    _isConnecting = false;
    await sendAlarmOff();
    await _distanceSub?.cancel();
    _distanceSub = null;
    await _connStateSub?.cancel();
    _connStateSub = null;
    await _scanSub?.cancel();
    _scanSub = null;
    await _bleStateSub?.cancel();
    _bleStateSub = null;

    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (_) {}
      _connectedDevice = null;
    }

    _setStatus(Esp32ConnectionStatus.disconnected);
    _lastValidDistanceMeters = null;
    _emitDistance(null);
  }

  void dispose() {
    stop();
    _statusController.close();
    _distanceController.close();
  }
}
