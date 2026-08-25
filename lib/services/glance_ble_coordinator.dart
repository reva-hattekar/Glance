import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

enum GlanceBleState {
  uninitialized,
  initializing,
  permissionRequired,
  bluetoothOff,
  scanning,
  error,
}

/// Central coordinator for all Bluetooth Low Energy operations in Glance.
/// Owns the single shared FlutterBluePlus scan instance and manages permissions and adapter state.
class GlanceBleCoordinator {
  GlanceBleCoordinator._();
  static final GlanceBleCoordinator instance = GlanceBleCoordinator._();

  final _stateController = StreamController<GlanceBleState>.broadcast();
  Stream<GlanceBleState> get stateStream => _stateController.stream;

  GlanceBleState _state = GlanceBleState.uninitialized;
  GlanceBleState get state => _state;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  bool _isInitializing = false;

  void _setState(GlanceBleState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  /// Starts the unified BLE system: checks permissions, waits for adapter, and starts shared scan.
  Future<bool> initializeAndStartScan({bool userInitiated = false}) async {
    if (kIsWeb) {
      _setState(GlanceBleState.error);
      return false;
    }

    if (_isInitializing) return false;
    _isInitializing = true;

    debugPrint('[GLANCE BLE] Initializing...');
    _setState(GlanceBleState.initializing);

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        debugPrint('[GLANCE BLE] Bluetooth LE is not supported on this device.');
        _setState(GlanceBleState.error);
        _isInitializing = false;
        return false;
      }

      // 1. Permissions Check & Request
      debugPrint('[GLANCE BLE] Checking permissions...');
      bool permissionsOk = await _checkAndRequestPermissions(userInitiated: userInitiated);
      if (!permissionsOk) {
        debugPrint('[GLANCE BLE] Permissions not granted.');
        _setState(GlanceBleState.permissionRequired);
        _isInitializing = false;
        return false;
      }
      debugPrint('[GLANCE BLE] Permissions granted');

      // 2. Adapter State Check
      debugPrint('[GLANCE BLE] Checking adapter...');
      if (Platform.isAndroid) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {}
      }

      final adapterState = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.turningOn)
          .first
          .timeout(const Duration(seconds: 4), onTimeout: () => FlutterBluePlus.adapterStateNow);

      if (adapterState != BluetoothAdapterState.on) {
        debugPrint('[GLANCE BLE] Bluetooth OFF ($adapterState)');
        _setState(GlanceBleState.bluetoothOff);

        // Listen for user turning on Bluetooth later
        _listenToAdapterState();
        _isInitializing = false;
        return false;
      }

      debugPrint('[GLANCE BLE] Bluetooth ON');
      _listenToAdapterState();

      // 3. Start Single Shared Scan
      await _startSharedScan();
      _isInitializing = false;
      return true;
    } catch (e) {
      debugPrint('[GLANCE BLE] Initialization error: $e');
      _setState(GlanceBleState.error);
      _isInitializing = false;
      return false;
    }
  }

  Future<bool> _checkAndRequestPermissions({required bool userInitiated}) async {
    if (!Platform.isAndroid) return true;

    try {
      final scanStatus = await Permission.bluetoothScan.status;
      final connectStatus = await Permission.bluetoothConnect.status;
      final locationStatus = await Permission.location.status;

      debugPrint('[GLANCE BLE] BLUETOOTH_SCAN = ${scanStatus.name}');
      debugPrint('[GLANCE BLE] BLUETOOTH_CONNECT = ${connectStatus.name}');
      debugPrint('[GLANCE BLE] ACCESS_FINE_LOCATION = ${locationStatus.name}');

      // If already granted, proceed immediately
      if ((scanStatus.isGranted && connectStatus.isGranted) || locationStatus.isGranted) {
        return true;
      }

      // Explicitly request permissions
      debugPrint('[GLANCE BLE] Requesting Bluetooth permissions...');
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      final scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final connectGranted = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
      final locGranted = statuses[Permission.location]?.isGranted ?? false;

      debugPrint('[GLANCE BLE] Request result -> scan: $scanGranted, connect: $connectGranted, loc: $locGranted');
      return (scanGranted && connectGranted) || locGranted || scanGranted;
    } catch (e) {
      debugPrint('[GLANCE BLE] Permission request error: $e');
      return false;
    }
  }

  void _listenToAdapterState() {
    _adapterSub?.cancel();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) async {
      debugPrint('[GLANCE BLE] Adapter state changed: $state');
      if (state == BluetoothAdapterState.on) {
        if (_state != GlanceBleState.scanning) {
          debugPrint('[GLANCE BLE] Bluetooth turned ON. Resuming scan...');
          await _startSharedScan();
        }
      } else if (state == BluetoothAdapterState.off) {
        _setState(GlanceBleState.bluetoothOff);
      }
    });
  }

  Future<void> _startSharedScan() async {
    try {
      debugPrint('[GLANCE BLE] Starting shared BLE scan...');
      if (!FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.startScan(
          continuousUpdates: true,
          continuousDivisor: 1,
          androidScanMode: AndroidScanMode.lowLatency,
        );
      }
      _setState(GlanceBleState.scanning);
    } catch (e) {
      debugPrint('[GLANCE BLE] Error starting scan: $e');
      _setState(GlanceBleState.error);
    }
  }

  Future<void> stop() async {
    _adapterSub?.cancel();
    _adapterSub = null;
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {}
    _setState(GlanceBleState.uninitialized);
  }

  void dispose() {
    stop();
    _stateController.close();
  }
}

