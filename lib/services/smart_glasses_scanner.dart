import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'glance_ble_coordinator.dart';

/// A BLE device detected by the scanner that looks like smart glasses.
class SmartGlassDevice {
  const SmartGlassDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.firstSeen,
    required this.lastSeen,
    required this.isGlasses,
    this.isBonded = false,
  });

  final String id;
  final String name;

  /// Received Signal Strength Indicator in dBm. Higher (closer to 0) = stronger.
  final int rssi;
  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final bool isGlasses;
  final bool isBonded;

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
class SmartGlassesScanner {
  SmartGlassesScanner._();
  static final SmartGlassesScanner instance = SmartGlassesScanner._();

  /// Keywords used to decide whether a device name belongs to smart glasses.
  static const List<String> glassKeywords = [
    'glass',
    'glasses',
    'smart glass',
    'smart-glasses',
    'smartglass',
    'smartglasses',
    'sunglass',
    'sunglasses',
    'eyewear',
    'eye wear',
    'spectacle',
    'spectacles',
    'specs',
    'shades',
    'frame',
    'frames',
    'echo frame',
    'echo frames',
    'amazon frame',
    'bose frame',
    'bose frames',
    'frames tenor',
    'frames alto',
    'frames soprano',
    'frames rondo',
    'ray-ban',
    'rayban',
    'meta',
    'stories',
    'rw4002',
    'rw4004',
    'rw4006',
    'rw4008',
    'viture',
    'rayneo',
    'nreal',
    'xreal',
    'solos',
    'airgo',
    'looktech',
    'zeblaze',
    'envision',
    'focals',
    'even realities',
    'even g1',
    'g1',
    'rokid',
    'lucyd',
    'anzu',
    'huawei eyewear',
    'gentle monster',
    'lawk',
    'optics',
    'optic',
    'goggle',
    'goggles',
    'lens',
    'lenses',
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

  /// Number of devices paired/bonded to this phone.
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
    // Drop devices that have not been heard from in a while (35 seconds).
    final cutoff = DateTime.now().subtract(const Duration(seconds: 35));
    _devices.removeWhere((_, d) => d.lastSeen == null || d.lastSeen!.isBefore(cutoff));
    if (!_devicesController.isClosed) _devicesController.add(currentDevices);
  }

  bool _isGlassesLike(String rawName) {
    if (rawName.isEmpty) return false;
    final clean = rawName
        .toLowerCase()
        .replaceAll(RegExp(r"['`’._\-\/\\]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    for (final kw in glassKeywords) {
      if (clean.contains(kw)) return true;
    }

    final tokens = clean.split(' ');
    for (final token in tokens) {
      if (token.contains('glass') ||
          token.contains('spectacle') ||
          token.contains('eyewear') ||
          token.contains('optic') ||
          token.contains('frame') ||
          token.contains('shade') ||
          token.contains('lens') ||
          token.contains('goggle') ||
          token.contains('specs')) {
        return true;
      }
    }
    return false;
  }

  static String _bestName(ScanResult r, [String? previousName]) {
    var adv = r.advertisementData.advName.trim();
    var plat = r.device.platformName.trim();

    adv = adv.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    plat = plat.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();

    if (adv.isNotEmpty) return adv;
    if (plat.isNotEmpty) return plat;
    if (previousName != null &&
        previousName.isNotEmpty &&
        !previousName.startsWith('BLE Device')) {
      return previousName;
    }
    return '';
  }

  StreamSubscription<GlanceBleState>? _coordSub;

  /// Starts continuous scanning. Safe to call multiple times.
  Future<void> start({bool userInitiated = false}) async {
    _running = true;
    _lastError = null;
    _setStatus(ScannerStatus.starting);

    if (kIsWeb) {
      _setStatus(ScannerStatus.unsupported);
      _running = false;
      return;
    }

    // Listen to central coordinator state transitions
    _coordSub?.cancel();
    _coordSub = GlanceBleCoordinator.instance.stateStream.listen((state) {
      switch (state) {
        case GlanceBleState.initializing:
          _setStatus(ScannerStatus.starting);
          break;
        case GlanceBleState.permissionRequired:
          _setStatus(ScannerStatus.permissionDenied);
          break;
        case GlanceBleState.bluetoothOff:
          _setStatus(ScannerStatus.bluetoothOff);
          break;
        case GlanceBleState.scanning:
          _setStatus(ScannerStatus.scanning);
          break;
        case GlanceBleState.error:
          _setStatus(ScannerStatus.error);
          break;
        case GlanceBleState.uninitialized:
          break;
      }
    });

    await _loadBondedDevices();
    _devices.clear();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen(
      _handleScanResults,
      onError: (Object e) {
        _lastError = e.toString();
        _setStatus(ScannerStatus.error);
      },
    );

    final ok = await GlanceBleCoordinator.instance.initializeAndStartScan(userInitiated: userInitiated);
    if (ok) {
      _setStatus(ScannerStatus.scanning);
    } else {
      if (GlanceBleCoordinator.instance.state == GlanceBleState.permissionRequired) {
        _setStatus(ScannerStatus.permissionDenied);
      } else if (GlanceBleCoordinator.instance.state == GlanceBleState.bluetoothOff) {
        _setStatus(ScannerStatus.bluetoothOff);
      } else {
        _setStatus(ScannerStatus.error);
      }
    }
  }

  Future<void> _loadBondedDevices() async {
    try {
      final bonded = await FlutterBluePlus.bondedDevices;
      _bondedIds = bonded.map((d) => d.remoteId.str).toSet();
      debugPrint('[BLE BONDED] ${_bondedIds.length} bonded devices loaded');
    } catch (_) {
      _bondedIds = {};
    }
  }

  void _handleScanResults(List<ScanResult> results) {
    final now = DateTime.now();
    for (final r in results) {
      final id = r.device.remoteId.str;
      final prev = _devices[id];
      var name = _bestName(r, prev?.name);

      // Exclude Glance / SafeSight ESP32 sensor from smart-glasses detection
      final lowerName = name.toLowerCase();
      final lowerAdv = r.advertisementData.advName.toLowerCase();
      final lowerPlat = r.device.platformName.toLowerCase();

      if (lowerName.contains('glance-esp') ||
          lowerName.contains('glance_esp') ||
          lowerName.contains('safesight') ||
          lowerAdv.contains('glance-esp') ||
          lowerAdv.contains('safesight') ||
          lowerPlat.contains('glance-esp') ||
          lowerPlat.contains('safesight') ||
          r.advertisementData.serviceUuids.any((u) => u.toString().toLowerCase().contains('4fafc201'))) {
        continue;
      }

      final isGlasses = name.isNotEmpty && _isGlassesLike(name);

      debugPrint('[BLE DISCOVERED] id: $id | advName: "${r.advertisementData.advName}" | platName: "${r.device.platformName}" | resolved: "$name" | rssi: ${r.rssi} | isGlasses: $isGlasses');

      if (!_showAll && !isGlasses) continue;

      if (name.isEmpty) {
        final shortId = id.length > 5 ? id.substring(0, 5) : id;
        name = 'BLE Device ($shortId)';
      }

      final isBonded = _bondedIds.contains(id);
      final displayName = (isBonded && !name.contains('(Paired)')) ? '$name (Paired)' : name;

      _devices[id] = SmartGlassDevice(
        id: id,
        name: displayName,
        rssi: r.rssi,
        firstSeen: prev?.firstSeen ?? now,
        lastSeen: now,
        isGlasses: isGlasses,
        isBonded: isBonded,
      );
    }
    _emitDevices();
  }

  /// Stops scanning and clears detected devices.
  Future<void> stop() async {
    _running = false;
    await _scanSub?.cancel();
    _scanSub = null;
    await _coordSub?.cancel();
    _coordSub = null;
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
