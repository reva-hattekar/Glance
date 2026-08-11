import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// A BLE device detected by the scanner that looks like smart glasses.
class SmartGlassDevice {
  const SmartGlassDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.firstSeen,
    required this.lastSeen,
    required this.isGlasses,
  });

  final String id;
  final String name;

  /// Received Signal Strength Indicator in dBm. Higher (closer to 0) = stronger.
  final int rssi;
  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final bool isGlasses;

  /// Rough distance estimate (meters) using the free-space path-loss model.
  double get estimatedDistanceMeters {
    if (rssi > 0) return 0.5;
    const txPower = -59.0; // measured power at 1 meter
    const pathLoss = 2.0; // indoor environment factor
    return (pow(10, (txPower - rssi) / (10 * pathLoss)) as double).clamp(0.1, 50.0);
  }

  String get signalLabel {
    if (rssi >= -50) return 'Excellent';
    if (rssi >= -60) return 'Strong';
    if (rssi >= -70) return 'Good';
    if (rssi >= -80) return 'Weak';
    return 'Very weak';
  }
}

enum ScannerStatus {
  idle,
  starting,
  scanning,
  stopped,
  unsupported,
  permissionDenied,
  bluetoothOff,
  error,
}

/// Scans for nearby smart glasses over Bluetooth Low Energy.
///
/// Only reports devices whose advertised name matches glasses-related
/// keywords, and silently ignores devices already paired/bonded to the phone.
class SmartGlassesScanner {
  SmartGlassesScanner._();
  static final SmartGlassesScanner instance = SmartGlassesScanner._();

  /// Keywords used to decide whether a device name belongs to smart glasses.
  /// Extend this list as new brands appear.
  static const List<String> glassKeywords = [
    'glass',
    'glasses',
    'eyewear',
    'eye wear',
    'spectacles',
    'specs',
    'ray-ban',
    'rayban',
    'meta',
    'viture',
    'rayneo',
    'nreal',
    'xreal',
    'echo frame',
    'echo frames',
    'solos',
    'looktech',
    'zeblaze',
    'envision',
    'focals',
    'bose frame',
    'smart glass',
    'smart-glasses',
  ];

  /// RSSI threshold (dBm) considered "too close" for a detected device.
  static const int closeRssiThreshold = -65;

  final _devicesController = StreamController<List<SmartGlassDevice>>.broadcast();
  final _statusController = StreamController<ScannerStatus>.broadcast();

  /// Emits the list of currently detected smart-glasses devices.
  Stream<List<SmartGlassDevice>> get devicesStream => _devicesController.stream;

  /// Emits the current scanner status.
  Stream<ScannerStatus> get statusStream => _statusController.stream;

  final Map<String, SmartGlassDevice> _devices = {};
  Set<String> _bondedIds = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _running = false;
  bool _scanCycleActive = false;
  ScannerStatus _status = ScannerStatus.idle;
  String? _lastError;
  bool _showAll = false;

  ScannerStatus get status => _status;
  List<SmartGlassDevice> get currentDevices => List.unmodifiable(_devices.values.toList());

  bool get showAll => _showAll;

  void setShowAll(bool value) {
    _showAll = value;
    _devices.clear();
    _emitDevices();
  }

  /// Number of devices paired/bonded to this phone (ignored during scans).
  int get bondedDeviceCount => _bondedIds.length;

  bool get isRunning => _running;
  String? get lastError => _lastError;

  /// The device with the strongest signal, if any.
  SmartGlassDevice? get strongestDevice {
    if (_devices.isEmpty) return null;
    return _devices.values.reduce((a, b) => a.rssi > b.rssi ? a : b);
  }

  void _setStatus(ScannerStatus s) {
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  void _emitDevices() {
    // Drop devices that have not been heard from in a while.
    final cutoff = DateTime.now().subtract(const Duration(seconds: 20));
    _devices.removeWhere((_, d) => d.lastSeen == null || d.lastSeen!.isBefore(cutoff));
    if (!_devicesController.isClosed) _devicesController.add(currentDevices);
  }

  bool _isGlassesLike(String name) {
    final lower = name.toLowerCase();
    return glassKeywords.any(lower.contains);
  }

  static String _bestName(ScanResult r) {
    final adv = r.advertisementData.advName.trim();
    if (adv.isNotEmpty) return adv;
    return r.device.platformName.trim();
  }

  /// Starts continuous scanning. Safe to call multiple times.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _lastError = null;
    _setStatus(ScannerStatus.starting);

    if (kIsWeb) {
      _setStatus(ScannerStatus.unsupported);
      _running = false;
      return;
    }

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        _setStatus(ScannerStatus.unsupported);
        _running = false;
        return;
      }

      final permissionOk = await _ensurePermissions();
      if (!permissionOk) {
        _setStatus(ScannerStatus.permissionDenied);
        _running = false;
        return;
      }

      if (!kIsWeb && Platform.isAndroid) {
        await FlutterBluePlus.turnOn();
      }

      final state = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.turningOn)
          .first
          .timeout(const Duration(seconds: 10));

      if (state != BluetoothAdapterState.on) {
        _setStatus(ScannerStatus.bluetoothOff);
        _running = false;
        return;
      }

      await _loadBondedDevices();

      _devices.clear();

      _scanSub = FlutterBluePlus.scanResults.listen(
        _handleScanResults,
        onError: (Object e) {
          _lastError = e.toString();
          _setStatus(ScannerStatus.error);
        },
      );

      _setStatus(ScannerStatus.scanning);
      _runScanLoop();
    } catch (e) {
      _lastError = e.toString();
      _setStatus(ScannerStatus.error);
      _running = false;
    }
  }

  Future<bool> _ensurePermissions() async {
    if (kIsWeb || !Platform.isAndroid) return true;

    int sdkVersion = 0;
    try {
      final versionString = Platform.operatingSystemVersion;
      final match = RegExp(r'(?:SDK|API)\s+(\d+)', caseSensitive: false).firstMatch(versionString);
      if (match != null) {
        sdkVersion = int.tryParse(match.group(1) ?? '') ?? 0;
      } else {
        final digits = RegExp(r'\d+').allMatches(versionString).map((m) => int.tryParse(m.group(0) ?? '') ?? 0).toList();
        if (digits.isNotEmpty) {
          for (final d in digits) {
            if (d >= 12) {
              sdkVersion = d;
              break;
            }
          }
          if (sdkVersion == 0) {
            sdkVersion = digits.last;
          }
        }
      }
    } catch (_) {}

    final isAndroid12OrAbove = sdkVersion >= 31 || (sdkVersion >= 12 && sdkVersion < 31);
    _lastError = 'OS: ${Platform.operatingSystemVersion} | SDK: $sdkVersion';

    if (isAndroid12OrAbove) {
      final results = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
      final scanGranted = results[Permission.bluetoothScan]?.isGranted ?? false;
      final connectGranted = results[Permission.bluetoothConnect]?.isGranted ?? false;
      
      if (!scanGranted || !connectGranted) {
        _lastError = 'Scan: ${results[Permission.bluetoothScan]?.name}, Connect: ${results[Permission.bluetoothConnect]?.name}';
        return false;
      }
      return true;
    } else {
      final locationStatus = await Permission.location.request();
      if (!locationStatus.isGranted) {
        _lastError = 'Location: ${locationStatus.name}';
        return false;
      }
      return true;
    }
  }

  Future<void> _loadBondedDevices() async {
    try {
      final bonded = await FlutterBluePlus.bondedDevices;
      _bondedIds = bonded.map((d) => d.remoteId.str).toSet();
    } catch (_) {
      _bondedIds = {};
    }
  }

  void _handleScanResults(List<ScanResult> results) {
    final now = DateTime.now();
    for (final r in results) {
      final id = r.device.remoteId.str;

      // Skip devices already paired/bonded to this phone.
      if (_bondedIds.contains(id)) continue;

      final name = _bestName(r);
      if (name.isEmpty) continue;

      final isGlasses = _isGlassesLike(name);
      if (!_showAll && !isGlasses) continue;

      final prev = _devices[id];
      _devices[id] = SmartGlassDevice(
        id: id,
        name: name,
        rssi: r.rssi,
        firstSeen: prev?.firstSeen ?? now,
        lastSeen: now,
        isGlasses: isGlasses,
      );
    }
    _emitDevices();
  }

  Future<void> _runScanLoop() async {
    while (_running) {
      if (_scanCycleActive) return;
      _scanCycleActive = true;
      try {
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 8),
          continuousUpdates: true,
          continuousDivisor: 3,
          removeIfGone: const Duration(seconds: 20),
          androidUsesFineLocation: false,
        );
        await FlutterBluePlus.isScanning
            .where((v) => v == false)
            .first
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        _lastError = e.toString();
        _setStatus(ScannerStatus.error);
        if (!_running) break;
        await Future.delayed(const Duration(seconds: 3));
      } finally {
        _scanCycleActive = false;
      }
    }
  }

  /// Stops scanning and clears detected devices.
  Future<void> stop() async {
    _running = false;
    _scanCycleActive = false;
    await _scanSub?.cancel();
    _scanSub = null;
    if (!kIsWeb) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
    _devices.clear();
    _emitDevices();
    _setStatus(ScannerStatus.stopped);
  }

  void dispose() {
    stop();
    _devicesController.close();
    _statusController.close();
  }
}
