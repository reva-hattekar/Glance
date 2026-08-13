import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'services/smart_glasses_scanner.dart';
import 'widgets/smart_glasses_detector_card.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const GlanceApp());
}

class GlanceApp extends StatelessWidget {
  const GlanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Glance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFAF7F2),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFD65345),
          secondary: Color(0xFF6E8E7D),
          surface: Colors.white,
          error: Color(0xFFC94A38),
        ),
        textTheme: const TextTheme(
          displayMedium: TextStyle(
            fontFamily: 'serif',
            fontSize: 27,
            fontWeight: FontWeight.bold,
            color: Color(0xFF332D2B),
          ),
          titleLarge: TextStyle(
            fontFamily: 'serif',
            fontSize: 19,
            fontWeight: FontWeight.w600,
            color: Color(0xFF332D2B),
          ),
          bodyLarge: TextStyle(
            color: Color(0xFF332D2B),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          bodyMedium: TextStyle(
            color: Color(0xFF7E726D),
            fontSize: 13,
          ),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  // ============================================================
  // NATIVE ANDROID CHANNEL
  // ============================================================

  static const platform = MethodChannel('com.safelens/monitor');

  // ============================================================
  // MODES / APP STATE
  // ============================================================

  bool _isLiveMode = false;

  bool _isAlarmActive = false;

  // ============================================================
  // CAMERA
  // ============================================================

  CameraController? _cameraController;

  List<CameraDescription> _cameras = [];

  bool _isCameraInitialized = false;
  bool _isCameraStarting = false;

  int _selectedCameraIndex = 0;

  // ============================================================
  // BLE SMART GLASSES
  // ============================================================

  List<SmartGlassDevice> _detectedGlasses = [];

  StreamSubscription<List<SmartGlassDevice>>? _glassesSub;

  // ============================================================
  // REAL COMPUTER VISION
  // ============================================================

  FaceDetector? _faceDetector;
  Interpreter? _glassesInterpreter;

  bool _isProcessingFrame = false;
  int _frameCounter = 0;

  bool _personDetected = false;
  bool _interactionDetected = false;

  double _liveDistance = 0.0;
  double _liveOrientation = 0.0;
  double _liveDuration = 0.0;
  double _liveSmartGlassesProb = 0.0;

  DateTime? _interactionStart;

  double _lastFaceX = 0.0;
  double _movement = 0.0;

  // ============================================================
  // LOGS / BACKGROUND POLLING
  // ============================================================

  List<String> _alertsLog = [];

  Timer? _pendingAlarmPoller;
  Timer? _vibrationTimer;

  // ============================================================
  // SIMULATION PARAMETERS
  // ============================================================

  double _simDistance = 1.5;
  double _simSmartGlassesProb = 92.0;
  double _simDuration = 7.0;
  double _simOrientation = 75.0;

  bool _simBluetoothEvidence = true;
  bool _simMovementLow = true;

  // ============================================================
  // RISK ENGINE
  // ============================================================

  int _riskScore = 0;
  String _riskLevel = "LOW RISK";

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _initFaceDetection();
    _initGlassesModel();

    _startGlassesScanner();

    _initializePermissionsAndStatus();
    _loadAlertLogs();
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _vibrationTimer?.cancel();

    _disposeCamera();

    _faceDetector?.close();

    _glassesSub?.cancel();
    SmartGlassesScanner.instance.stop();

    super.dispose();
  }

  // ============================================================
  // APP LIFECYCLE
  // ============================================================

  @override
void didChangeAppLifecycleState(AppLifecycleState state) {
  // No background spyware monitoring.
}

  // ============================================================
  // FACE DETECTION
  // ============================================================

  Future<void> _initFaceDetection() async {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableTracking: true,
        enableLandmarks: false,
        enableContours: false,
        enableClassification: false,
      ),
    );

    debugPrint("FACE DETECTOR READY");
  }

  // ============================================================
  // TFLITE MODEL
  // ============================================================

  Future<void> _initGlassesModel() async {
    debugPrint("GLASSES MODEL FUNCTION CALLED");

    try {
      _glassesInterpreter = await Interpreter.fromAsset(
        'assets/smart_glasses.tflite',
      );

      final input = _glassesInterpreter!.getInputTensor(0);
      final output = _glassesInterpreter!.getOutputTensor(0);

      debugPrint('===== GLASSES MODEL =====');
      debugPrint('Input shape: ${input.shape}');
      debugPrint('Input type: ${input.type}');
      debugPrint('Output shape: ${output.shape}');
      debugPrint('Output type: ${output.type}');
      debugPrint('=========================');
    } catch (e) {
      debugPrint('GLASSES MODEL ERROR: $e');
    }
  }

  // ============================================================
  // RUN TFLITE GLASSES MODEL
  // ============================================================

  Future<void> _runGlassesModel(
    CameraImage cameraImage,
    Rect faceBox,
  ) async {
    if (_glassesInterpreter == null) return;

    try {
      final rgbImage = _nv21ToRgb(cameraImage);

      if (rgbImage == null) return;

      int x = faceBox.left.round();
      int y = faceBox.top.round();

      int width = faceBox.width.round();
      int height = faceBox.height.round();

      final paddingX = (width * 0.15).round();
      final paddingY = (height * 0.15).round();

      x -= paddingX;
      y -= paddingY;

      width += paddingX * 2;
      height += paddingY * 2;

      x = x.clamp(0, rgbImage.width - 1);
      y = y.clamp(0, rgbImage.height - 1);

      width = width.clamp(1, rgbImage.width - x);
      height = height.clamp(1, rgbImage.height - y);

      final faceCrop = img.copyCrop(
        rgbImage,
        x: x,
        y: y,
        width: width,
        height: height,
      );

      final resized = img.copyResize(
        faceCrop,
        width: 224,
        height: 224,
        interpolation: img.Interpolation.linear,
      );

      final input = List.generate(
        1,
        (_) => List.generate(
          224,
          (y) => List.generate(
            224,
            (x) {
              final pixel = resized.getPixel(x, y);

              return [
                (pixel.r.toDouble() / 127.5) - 1.0,
                (pixel.g.toDouble() / 127.5) - 1.0,
                (pixel.b.toDouble() / 127.5) - 1.0,
              ];
            },
          ),
        ),
      );

      final output = [
        [0.0]
      ];

      _glassesInterpreter!.run(input, output);

      final probability = output[0][0].toDouble();

      debugPrint(
        "👓 GLASSES MODEL → "
        "${(probability * 100).toStringAsFixed(1)}%",
      );

      if (!mounted) return;

      setState(() {
        _liveSmartGlassesProb =
            (probability * 100).clamp(0.0, 100.0);
      });
    } catch (e, stackTrace) {
      debugPrint("GLASSES MODEL ERROR: $e");
      debugPrint("$stackTrace");
    }
  }

  // ============================================================
  // BLE SCANNER
  // ============================================================

  void _startGlassesScanner() {
    _glassesSub = SmartGlassesScanner
        .instance
        .devicesStream
        .listen(_onGlassesChanged);

    SmartGlassesScanner.instance.start();
  }

  void _onGlassesChanged(List<SmartGlassDevice> devices) {
    if (!mounted) return;

    setState(() {
      _detectedGlasses = devices;
    });

    // Update live risk whenever BLE changes.
    _calculateLiveRisk();

    // Only automatic BLE alarm in LIVE MODE.
    if (!_isLiveMode || _isAlarmActive || devices.isEmpty) {
      return;
    }

    final glasses = devices.where((d) => d.isGlasses).toList();

    if (glasses.isEmpty) return;

    final best = glasses.reduce(
      (a, b) => a.rssi > b.rssi ? a : b,
    );

    if (best.rssi >= SmartGlassesScanner.closeRssiThreshold) {
      _triggerAlarmLocal(
        'Smart glasses detected nearby: '
        '${best.name} (${best.rssi} dBm)',
      );
    }
  }

  // ============================================================
  // NV21 -> RGB
  // ============================================================

  img.Image? _nv21ToRgb(CameraImage image) {
    try {
      final width = image.width;
      final height = image.height;

      final bytes = image.planes.first.bytes;

      final rgb = img.Image(
        width: width,
        height: height,
      );

      final frameSize = width * height;

      for (int y = 0; y < height; y++) {
        final uvRow = frameSize + (y >> 1) * width;

        for (int x = 0; x < width; x++) {
          final yIndex = y * width + x;

          int yValue = bytes[yIndex] & 0xff;

          final uvIndex = uvRow + (x & ~1);

          int v = bytes[uvIndex] & 0xff;
          int u = bytes[uvIndex + 1] & 0xff;

          yValue = yValue < 16 ? 16 : yValue;

          final r = (1.164 * (yValue - 16) +
                  1.596 * (v - 128))
              .round()
              .clamp(0, 255);

          final g = (1.164 * (yValue - 16) -
                  0.813 * (v - 128) -
                  0.391 * (u - 128))
              .round()
              .clamp(0, 255);

          final b = (1.164 * (yValue - 16) +
                  2.018 * (u - 128))
              .round()
              .clamp(0, 255);

          rgb.setPixelRgb(x, y, r, g, b);
        }
      }

      return rgb;
    } catch (e) {
      debugPrint("NV21 → RGB ERROR: $e");
      return null;
    }
  }

  // ============================================================
  // CAMERA IMAGE PROCESSING
  // ============================================================

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingFrame || _faceDetector == null) {
      return;
    }

    _frameCounter++;

    // Process every 5th frame.
    if (_frameCounter % 5 != 0) {
      return;
    }

    _isProcessingFrame = true;

    try {
      final inputImage = _convertCameraImage(image);

      if (inputImage == null) {
        return;
      }

      debugPrint("CV ✓ Sending frame to ML Kit");

      final faces = await _faceDetector!.processImage(inputImage);

      debugPrint("CV ✓ Faces found: ${faces.length}");

      if (!mounted) return;

      // ========================================================
      // NO PERSON
      // ========================================================

      if (faces.isEmpty) {
        setState(() {
          _personDetected = false;
          _interactionDetected = false;

          _liveDistance = 0;
          _liveOrientation = 0;
          _liveDuration = 0;
          _liveSmartGlassesProb = 0;

          _movement = 0;
          _lastFaceX = 0;
        });

        _interactionStart = null;

        _calculateLiveRisk();

        return;
      }

      // ========================================================
      // LARGEST FACE
      // ========================================================

      faces.sort(
        (a, b) =>
            b.boundingBox.width.compareTo(
          a.boundingBox.width,
        ),
      );

      final face = faces.first;
      final box = face.boundingBox;

      // ========================================================
      // SMART GLASSES MODEL
      // ========================================================

      await _runGlassesModel(image, box);

      // ========================================================
      // 1. DISTANCE
      // ========================================================

      final imageWidth = image.width.toDouble();

      final faceRatio = box.width / imageWidth;

      double distance;

      if (faceRatio > 0.65) {
        distance = 0.5;
      } else if (faceRatio > 0.50) {
        distance = 0.8;
      } else if (faceRatio > 0.35) {
        distance = 1.2;
      } else if (faceRatio > 0.25) {
        distance = 1.8;
      } else if (faceRatio > 0.18) {
        distance = 2.5;
      } else {
        distance = 3.5;
      }

      // ========================================================
      // 2. INTERACTION
      // ========================================================

      final closeEnough = distance <= 2.5;

      if (closeEnough) {
        _interactionStart ??= DateTime.now();

        _liveDuration =
            DateTime.now()
                    .difference(_interactionStart!)
                    .inMilliseconds /
                1000.0;

        // Interaction counts after 7 seconds.
        _interactionDetected =
            _liveDuration >= 7.0;
      } else {
        _interactionStart = null;
        _interactionDetected = false;
        _liveDuration = 0;
      }

      // ========================================================
      // 3. ORIENTATION
      // ========================================================

      final yaw = face.headEulerAngleY ?? 90.0;
      final pitch = face.headEulerAngleX ?? 90.0;

      final yawScore =
          (1 - (yaw.abs() / 45.0))
              .clamp(0.0, 1.0);

      final pitchScore =
          (1 - (pitch.abs() / 30.0))
              .clamp(0.0, 1.0);

      final orientation =
          ((yawScore * 0.7) +
                  (pitchScore * 0.3)) *
              100;

      // ========================================================
      // 4. MOVEMENT
      // ========================================================

      final currentX = box.center.dx;

      _movement = _lastFaceX == 0
          ? 0
          : (currentX - _lastFaceX).abs();

      _lastFaceX = currentX;

      // ========================================================
      // UPDATE UI
      // ========================================================

      setState(() {
        _personDetected = true;

        _liveDistance = distance;
        _liveOrientation = orientation;
      });

      _calculateLiveRisk();

      debugPrint(
        "FACE ✓ | "
        "Distance: ${distance.toStringAsFixed(1)}m | "
        "Orientation: ${orientation.toStringAsFixed(0)} | "
        "Duration: ${_liveDuration.toStringAsFixed(1)}s | "
        "Glasses: ${_liveSmartGlassesProb.toStringAsFixed(1)}%",
      );
    } catch (e) {
      debugPrint("Face processing error: $e");
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ============================================================
  // ML KIT INPUT IMAGE CONVERSION
  // ============================================================

  InputImage? _convertCameraImage(CameraImage image) {
    if (!Platform.isAndroid) return null;

    if (_cameraController == null) return null;

    if (image.planes.length != 1) {
      debugPrint(
        "CV ❌ Wrong plane count: ${image.planes.length}",
      );
      return null;
    }

    if (_cameras.isEmpty) return null;

    final camera = _cameras[_selectedCameraIndex];

    final rotationMap = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };

    var rotationCompensation =
        rotationMap[
          _cameraController!.value.deviceOrientation
        ];

    if (rotationCompensation == null) {
      return null;
    }

    if (camera.lensDirection ==
        CameraLensDirection.front) {
      rotationCompensation =
          (camera.sensorOrientation +
                  rotationCompensation) %
              360;
    } else {
      rotationCompensation =
          (camera.sensorOrientation -
                  rotationCompensation +
                  360) %
              360;
    }

    final rotation =
        InputImageRotationValue.fromRawValue(
      rotationCompensation,
    );

    if (rotation == null) return null;

    final format =
        InputImageFormatValue.fromRawValue(
      image.format.raw,
    );

    if (format == null) return null;

    if (format != InputImageFormat.nv21) {
      debugPrint(
        "CV ❌ Wrong image format: ${image.format.raw}",
      );
      return null;
    }

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(
          image.width.toDouble(),
          image.height.toDouble(),
        ),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // ============================================================
  // INITIALIZATION
  // ============================================================

  Future<void> _initializePermissionsAndStatus() async {
  await [
    Permission.camera,
    Permission.notification,
  ].request();

  try {
    _cameras = await availableCameras();
  } catch (e) {
    _logEvent(
      'No camera sensors found: ${e.toString()}',
    );
  }
}

  // ============================================================
  // LOGS
  // ============================================================

  Future<void> _loadAlertLogs() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;

    setState(() {
      _alertsLog =
          prefs.getStringList('alerts_log') ?? [];
    });
  }

  Future<void> _logEvent(String message) async {
    final prefs = await SharedPreferences.getInstance();

    final timestamp =
        DateTime.now()
            .toLocal()
            .toString()
            .substring(11, 19);

    final logEntry =
        '[$timestamp] $message';

    if (mounted) {
      setState(() {
        _alertsLog.insert(0, logEntry);

        if (_alertsLog.length > 50) {
          _alertsLog.removeLast();
        }
      });
    }

    await prefs.setStringList(
      'alerts_log',
      _alertsLog,
    );
  }

  Future<void> _clearLogs() async {
    final prefs = await SharedPreferences.getInstance();

    if (mounted) {
      setState(() {
        _alertsLog.clear();
      });
    }

    await prefs.remove('alerts_log');
  }

  // ============================================================
  // CAMERA MANAGEMENT
  // ============================================================

  Future<void> _initCamera() async {
    if (_isCameraStarting ||
        _isCameraInitialized) {
      return;
    }

    if (_cameras.isEmpty) {
      try {
        _cameras = await availableCameras();
      } catch (e) {
        await _logEvent(
          'Camera initialization failed: no camera found.',
        );
        return;
      }
    }

    if (_cameras.isEmpty) return;

    if (_selectedCameraIndex >=
        _cameras.length) {
      _selectedCameraIndex = 0;
    }

    if (!mounted) return;

    setState(() {
      _isCameraStarting = true;
    });

    final controller = CameraController(
      _cameras[_selectedCameraIndex],
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    _cameraController = controller;

    try {
      await controller.initialize();

      await controller.startImageStream(
        _processCameraImage,
      );

      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
        _isCameraStarting = false;
      });
    } catch (e) {
      await _logEvent(
        'Camera init error: $e',
      );

      if (mounted) {
        setState(() {
          _isCameraStarting = false;
          _isCameraInitialized = false;
        });
      }
    }
  }

  Future<void> _disposeCamera({
    bool silent = false,
  }) async {
    if (mounted && !silent) {
      setState(() {
        _isCameraInitialized = false;
      });
    }

    final controller = _cameraController;

    _cameraController = null;

    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (_) {}

      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  // ============================================================
  // CAMERA FLIP
  // ============================================================

  Future<void> _toggleCameraLens() async {
    if (_cameras.length < 2) return;

    final nextIndex =
        (_selectedCameraIndex + 1) %
            _cameras.length;

    await _disposeCamera();

    if (!mounted) return;

    setState(() {
      _selectedCameraIndex = nextIndex;
    });

    await _initCamera();

    await _logEvent(
      'Switched camera lens',
    );
  }

  // ============================================================
  // SIMULATION RISK
  // ============================================================

  void _calculateRisk() {
    double score = 0;

    // ----------------------------------------------------------
    // 1. DISTANCE — 25 POINTS
    // ----------------------------------------------------------

    if (_simDistance <= 2.0) {
      final distFactor =
          ((2.0 - _simDistance) / 1.5)
              .clamp(0.0, 1.0);

      score +=
          10 + (distFactor * 15);
    }

    // ----------------------------------------------------------
    // 2. SMART GLASSES — 30 POINTS
    // ----------------------------------------------------------

    score +=
        _simSmartGlassesProb * 0.30;

    // ----------------------------------------------------------
    // 3. INTERACTION — 15 POINTS
    // ----------------------------------------------------------

    if (_simDuration >= 5.0) {
      score += 15;
    }

    // ----------------------------------------------------------
    // 4. ORIENTATION — 15 POINTS
    // ----------------------------------------------------------

    score +=
        _simOrientation * 0.15;

    // ----------------------------------------------------------
    // 5. BLUETOOTH — 15 POINTS
    // ----------------------------------------------------------

    if (_simBluetoothEvidence) {
      score += 15;
    }

    // ----------------------------------------------------------
    // 6. MOVEMENT — 10 POINTS
    // ----------------------------------------------------------

    if (_simMovementLow) {
      score += 10;
    }

    // ----------------------------------------------------------
    // FINAL
    // ----------------------------------------------------------

    final finalScore =
        score.round().clamp(0, 100);

    String level = "LOW RISK";

    if (finalScore >= 75) {
      level = "HIGH RISK";
    } else if (finalScore >= 40) {
      level = "MEDIUM RISK";
    }

    if (!mounted) return;

    setState(() {
      _riskScore = finalScore;
      _riskLevel = level;
    });

    _logEvent(
      'Risk Calculated: $finalScore% - $level',
    );

    if (level == "HIGH RISK" &&
        !_isAlarmActive) {
      _triggerAlarmLocal(
        "Simulated threat level reached HIGH ($finalScore%)",
      );
    }
  }

  // ============================================================
  // LIVE RISK
  // ============================================================

  void _calculateLiveRisk() {
    if (!_isLiveMode ||
        !_personDetected) {
      return;
    }

    double score = 0;

    // ----------------------------------------------------------
    // 1. DISTANCE — 25 POINTS
    // ----------------------------------------------------------

    if (_liveDistance <= 2.0) {
      final distFactor =
          ((2.0 - _liveDistance) / 1.5)
              .clamp(0.0, 1.0);

      score +=
          10 + (distFactor * 15);
    }

    // ----------------------------------------------------------
    // 2. INTERACTION — 15 POINTS
    // ----------------------------------------------------------

    if (_interactionDetected) {
      score += 15;
    }

    // ----------------------------------------------------------
    // 3. ORIENTATION — 15 POINTS
    // ----------------------------------------------------------

    score +=
        _liveOrientation * 0.15;

    // ----------------------------------------------------------
    // 4. SMART GLASSES — 20 POINTS
    // ----------------------------------------------------------

    score +=
        _liveSmartGlassesProb * 0.20;

    // ----------------------------------------------------------
    // 5. MOVEMENT — 10 POINTS
    // ----------------------------------------------------------

    final movementLow =
        _movement < 8.0;

    if (movementLow) {
      score += 10;
    }

    // ----------------------------------------------------------
    // 6. REAL BLE — 15 POINTS
    // ----------------------------------------------------------

    final glasses =
        _detectedGlasses
            .where((d) => d.isGlasses)
            .toList();

    if (glasses.isNotEmpty) {
      final best = glasses.reduce(
        (a, b) => a.rssi > b.rssi ? a : b,
      );

      final bleScore =
          ((best.rssi + 90) / 50 * 15)
              .clamp(2.0, 15.0);

      score += bleScore;
    }

    // ----------------------------------------------------------
    // FINAL SCORE
    // ----------------------------------------------------------

    final finalScore =
        score.round().clamp(0, 100);

    String level;

    if (finalScore >= 75) {
      level = "HIGH RISK";
    } else if (finalScore >= 40) {
      level = "MEDIUM RISK";
    } else {
      level = "LOW RISK";
    }

    final previousLevel = _riskLevel;

    if (!mounted) return;

    setState(() {
      _riskScore = finalScore;
      _riskLevel = level;
    });

    // Only log risk-level changes.
    if (previousLevel != level) {
      _logEvent(
        'Live Risk: $finalScore% - $level',
      );
    }

    // Automatic high-risk alarm.
    if (level == "HIGH RISK" &&
        !_isAlarmActive) {
      _triggerAlarmLocal(
        "Live threat signature detected ($finalScore%)",
      );
    }
  }

  // ============================================================
  // ALARM
  // ============================================================

  Future<void> _triggerAlarmLocal(
    String cause,
  ) async {
    if (_isAlarmActive) return;

    if (mounted) {
      setState(() {
        _isAlarmActive = true;
      });
    }

    await _logEvent(
      '🚨 SAFETY ALARM: $cause',
    );

    await WakelockPlus.enable();

    // Automatically open camera if necessary.
    if (!_isCameraInitialized &&
        !_isCameraStarting) {
      _initCamera();
    }

    _startVibrationLoop();
  }

  // ============================================================
  // VIBRATION
  // ============================================================

  Future<void> _startVibrationLoop() async {
    final hasVibrator =
        await Vibration.hasVibrator();

    if (!hasVibrator) return;

    _vibrationTimer?.cancel();

    _vibrationTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (timer) async {
        if (!_isAlarmActive) {
          timer.cancel();
          return;
        }

        await Vibration.vibrate(
          pattern: [0, 500, 250, 500],
        );
      },
    );
  }

  // ============================================================
  // DISARM
  // ============================================================

  Future<void> _disarmAlarm() async {
    if (mounted) {
      setState(() {
        _isAlarmActive = false;

        if (!_isLiveMode) {
          _riskScore = 0;
          _riskLevel = "LOW RISK";
        }
      });
    }

    _vibrationTimer?.cancel();
    _vibrationTimer = null;

    await WakelockPlus.disable();
    await Vibration.cancel();

    // Stop native alarm.
    try {
      await platform.invokeMethod(
        'stopAlarm',
      );
    } catch (_) {}

    await _disposeCamera();

    await _logEvent(
      'Glance Companion Disarmed',
    );
  }

  // ============================================================
  // UI CARD
  // ============================================================

  Widget _buildPinterestCard({
    required Widget child,
    Color? color,
    EdgeInsetsGeometry? padding,
  }) {
    return Container(
      margin: const EdgeInsets.only(
        bottom: 20,
      ),
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        borderRadius:
            BorderRadius.circular(28),
        border: Border.all(
          color: const Color(0xFFEFEBE4),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5D534A)
                .withOpacity(0.045),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius:
            BorderRadius.circular(28),
        child: Padding(
          padding:
              padding ??
              const EdgeInsets.all(22),
          child: child,
        ),
      ),
    );
  }

  // ============================================================
  // SLIDER
  // ============================================================

  Widget _buildSliderRow({
    required String title,
    required String valueDisplay,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment:
              MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Color(0xFF332D2B),
              ),
            ),
            Text(
              valueDisplay,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Color(0xFFD65345),
              ),
            ),
          ],
        ),
        SliderTheme(
          data:
              SliderTheme.of(context)
                  .copyWith(
            activeTrackColor:
                const Color(0xFFD65345),
            inactiveTrackColor:
                const Color(0xFFECE5DD),
            thumbColor:
                const Color(0xFFD65345),
            overlayColor:
                const Color(0xFFD65345)
                    .withOpacity(0.12),
            valueIndicatorColor:
                const Color(0xFFD65345),
            trackHeight: 3.5,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ======================================================
          // BACKGROUND
          // ======================================================

          Container(
            decoration:
                const BoxDecoration(
              gradient:
                  LinearGradient(
                colors: [
                  Color(0xFFFAF7F2),
                  Color(0xFFF4ECE4),
                ],
                begin:
                    Alignment.topCenter,
                end:
                    Alignment.bottomCenter,
              ),
            ),
          ),

          // ======================================================
          // MAIN SCROLL
          // ======================================================

          SafeArea(
            child:
                SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 16,
              ),
              physics:
                  const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  // ==================================================
                  // HEADER
                  // ==================================================

                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children: [
                          Text(
                            "Glance",
                            style:
                                Theme.of(
                                  context,
                                )
                                    .textTheme
                                    .displayMedium,
                          ),
                          const Text(
                            "Your Personal Safety Companion",
                            style:
                                TextStyle(
                              fontSize: 14,
                              fontWeight:
                                  FontWeight
                                      .w500,
                              color:
                                  Color(
                                0xFF7E726D,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Container(
                        width: 50,
                        height: 50,
                        decoration:
                            BoxDecoration(
                          shape:
                              BoxShape.circle,
                          color:
                              _isAlarmActive
                                  ? const Color(
                                      0xFFFDF0ED,
                                    )
                                  : const Color(
                                      0xFFE8F1EC,
                                    ),
                          border:
                              Border.all(
                            color:
                                _isAlarmActive
                                    ? const Color(
                                        0xFFF5D6D1,
                                      )
                                    : const Color(
                                        0xFFD3E5DC,
                                      ),
                          ),
                        ),
                        child: Icon(
                          _isAlarmActive
                              ? Icons
                                  .security_update_warning_rounded
                              : Icons
                                  .gpp_good_outlined,
                          color:
                              _isAlarmActive
                                  ? const Color(
                                      0xFFD65345,
                                    )
                                  : const Color(
                                      0xFF6E8E7D,
                                    ),
                          size: 26,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 28),

                  // ==================================================
                  // PRIVACY RADAR
                  // ==================================================

                  _buildPinterestCard(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        const Row(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .spaceBetween,
                          children: [
                            Text(
                              "PRIVACY RADAR",
                              style:
                                  TextStyle(
                                fontSize: 13,
                                fontWeight:
                                    FontWeight
                                        .bold,
                                letterSpacing:
                                    1.5,
                                color:
                                    Color(
                                  0xFF332D2B,
                                ),
                              ),
                            ),
                            Icon(
                              Icons
                                  .radar_rounded,
                              color:
                                  Color(
                                0xFF7E726D,
                              ),
                              size: 18,
                            ),
                          ],
                        ),

                        const SizedBox(
                          height: 16,
                        ),

                        Container(
                          height: 54,
                          padding:
                              const EdgeInsets
                                  .all(4),
                          decoration:
                              BoxDecoration(
                            color:
                                const Color(
                              0xFFEDE7DD,
                            ),
                            borderRadius:
                                BorderRadius
                                    .circular(
                              20,
                            ),
                          ),
                          child: Row(
                            children: [
                              // LIVE
                              Expanded(
                                child:
                                    GestureDetector(
                                  onTap: () {
                                    setState(
                                      () {
                                        _isLiveMode =
                                            true;
                                      },
                                    );

                                    _initCamera();
                                  },
                                  child:
                                      AnimatedContainer(
                                    duration:
                                        const Duration(
                                      milliseconds:
                                          200,
                                    ),
                                    alignment:
                                        Alignment
                                            .center,
                                    decoration:
                                        BoxDecoration(
                                      color:
                                          _isLiveMode
                                              ? Colors
                                                  .white
                                              : Colors
                                                  .transparent,
                                      borderRadius:
                                          BorderRadius
                                              .circular(
                                        16,
                                      ),
                                      boxShadow:
                                          _isLiveMode
                                              ? [
                                                  BoxShadow(
                                                    color:
                                                        const Color(
                                                      0xFF5D534A,
                                                    ).withOpacity(
                                                      0.08,
                                                    ),
                                                    blurRadius:
                                                        8,
                                                    offset:
                                                        const Offset(
                                                      0,
                                                      2,
                                                    ),
                                                  ),
                                                ]
                                              : [],
                                    ),
                                    child:
                                        Text(
                                      "LIVE MODE",
                                      style:
                                          TextStyle(
                                        fontSize:
                                            12,
                                        fontWeight:
                                            FontWeight
                                                .bold,
                                        letterSpacing:
                                            0.5,
                                        color:
                                            _isLiveMode
                                                ? const Color(
                                                    0xFF332D2B,
                                                  )
                                                : const Color(
                                                    0xFF8C7E77,
                                                  ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              // SIMULATION
                              Expanded(
                                child:
                                    GestureDetector(
                                  onTap: () {
                                    setState(
                                      () {
                                        _isLiveMode =
                                            false;
                                      },
                                    );

                                    _disarmAlarm();
                                  },
                                  child:
                                      AnimatedContainer(
                                    duration:
                                        const Duration(
                                      milliseconds:
                                          200,
                                    ),
                                    alignment:
                                        Alignment
                                            .center,
                                    decoration:
                                        BoxDecoration(
                                      color:
                                          !_isLiveMode
                                              ? Colors
                                                  .white
                                              : Colors
                                                  .transparent,
                                      borderRadius:
                                          BorderRadius
                                              .circular(
                                        16,
                                      ),
                                      boxShadow:
                                          !_isLiveMode
                                              ? [
                                                  BoxShadow(
                                                    color:
                                                        const Color(
                                                      0xFF5D534A,
                                                    ).withOpacity(
                                                      0.08,
                                                    ),
                                                    blurRadius:
                                                        8,
                                                    offset:
                                                        const Offset(
                                                      0,
                                                      2,
                                                    ),
                                                  ),
                                                ]
                                              : [],
                                    ),
                                    child:
                                        Text(
                                      "SIMULATION MODE",
                                      style:
                                          TextStyle(
                                        fontSize:
                                            12,
                                        fontWeight:
                                            FontWeight
                                                .bold,
                                        letterSpacing:
                                            0.5,
                                        color:
                                            !_isLiveMode
                                                ? const Color(
                                                    0xFF332D2B,
                                                  )
                                                : const Color(
                                                    0xFF8C7E77,
                                                  ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ==================================================
                  // BLE CARD
                  // ==================================================

                  const SmartGlassesDetectorCard(),

                  // ==================================================
                  // CAMERA
                  // ==================================================

                  if (_isLiveMode ||
                      _isAlarmActive)
                    _buildPinterestCard(
                      padding:
                          EdgeInsets.zero,
                      child:
                          Container(
                        height: 310,
                        color: Colors.black,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_isCameraInitialized &&
                                _cameraController !=
                                    null)
                              LayoutBuilder(
                                builder:
                                    (
                                  context,
                                  constraints,
                                ) {
                                  return SizedBox(
                                    width:
                                        constraints
                                            .maxWidth,
                                    height:
                                        constraints
                                            .maxHeight,
                                    child:
                                        FittedBox(
                                      fit: BoxFit
                                          .cover,
                                      child:
                                          SizedBox(
                                        width:
                                            _cameraController!
                                                .value
                                                .previewSize!
                                                .height,
                                        height:
                                            _cameraController!
                                                .value
                                                .previewSize!
                                                .width,
                                        child:
                                            CameraPreview(
                                          _cameraController!,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              )
                            else
                              const Center(
                                child:
                                    Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment
                                          .center,
                                  children: [
                                    CircularProgressIndicator(
                                      color:
                                          Colors
                                              .white,
                                    ),
                                    SizedBox(
                                      height:
                                          16,
                                    ),
                                    Text(
                                      "Initializing Safety Lens Feed...",
                                      style:
                                          TextStyle(
                                        color:
                                            Colors
                                                .white70,
                                        fontSize:
                                            13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                            // MONITORING ACTIVE
                            Positioned(
                              top: 14,
                              left: 14,
                              child:
                                  Container(
                                padding:
                                    const EdgeInsets
                                        .symmetric(
                                  horizontal:
                                      10,
                                  vertical: 6,
                                ),
                                decoration:
                                    BoxDecoration(
                                  color:
                                      const Color(
                                    0xFFC94A38,
                                  ).withOpacity(
                                    0.9,
                                  ),
                                  borderRadius:
                                      BorderRadius
                                          .circular(
                                    10,
                                  ),
                                ),
                                child:
                                    const Row(
                                  mainAxisSize:
                                      MainAxisSize
                                          .min,
                                  children: [
                                    SizedBox(
                                      width: 8,
                                      height: 8,
                                      child:
                                          DecoratedBox(
                                        decoration:
                                            BoxDecoration(
                                          shape:
                                              BoxShape
                                                  .circle,
                                          color:
                                              Colors
                                                  .white,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 6,
                                    ),
                                    Text(
                                      "MONITORING ACTIVE",
                                      style:
                                          TextStyle(
                                        color:
                                            Colors
                                                .white,
                                        fontWeight:
                                            FontWeight
                                                .bold,
                                        fontSize:
                                            10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // LIVE CV INFORMATION
                            if (_isLiveMode)
                              Positioned(
                                bottom: 14,
                                left: 14,
                                right: 14,
                                child:
                                    Container(
                                  padding:
                                      const EdgeInsets
                                          .all(
                                    14,
                                  ),
                                  decoration:
                                      BoxDecoration(
                                    color:
                                        Colors
                                            .black
                                            .withOpacity(
                                      0.72,
                                    ),
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      16,
                                    ),
                                  ),
                                  child:
                                      Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment
                                            .start,
                                    children: [
                                      Text(
                                        _personDetected
                                            ? "🟢 PERSON DETECTED"
                                            : "🔴 NO PERSON",
                                        style:
                                            const TextStyle(
                                          color:
                                              Colors
                                                  .white,
                                          fontWeight:
                                              FontWeight
                                                  .bold,
                                          fontSize:
                                              12,
                                        ),
                                      ),

                                      const SizedBox(
                                        height: 8,
                                      ),

                                      Text(
                                        "RISK  $_riskScore%  •  $_riskLevel",
                                        style:
                                            TextStyle(
                                          color:
                                              _riskLevel ==
                                                      "HIGH RISK"
                                                  ? const Color(
                                                      0xFFFF6B57,
                                                    )
                                                  : Colors
                                                      .white,
                                          fontWeight:
                                              FontWeight
                                                  .bold,
                                          fontSize:
                                              13,
                                        ),
                                      ),

                                      const SizedBox(
                                        height: 8,
                                      ),

                                      Text(
                                        "Distance: ${_liveDistance.toStringAsFixed(1)}m",
                                        style:
                                            const TextStyle(
                                          color:
                                              Colors
                                                  .white70,
                                          fontSize:
                                              11,
                                        ),
                                      ),

                                      Text(
                                        "Orientation: ${_liveOrientation.toStringAsFixed(0)}%",
                                        style:
                                            const TextStyle(
                                          color:
                                              Colors
                                                  .white70,
                                          fontSize:
                                              11,
                                        ),
                                      ),

                                      Text(
                                        "Interaction: ${_liveDuration.toStringAsFixed(1)}s",
                                        style:
                                            const TextStyle(
                                          color:
                                              Colors
                                                  .white70,
                                          fontSize:
                                              11,
                                        ),
                                      ),

                                      Text(
                                        "Glasses probability: ${_liveSmartGlassesProb.toStringAsFixed(0)}%",
                                        style:
                                            const TextStyle(
                                          color:
                                              Colors
                                                  .white70,
                                          fontSize:
                                              11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                            // CAMERA FLIP
                            if (_isCameraInitialized &&
                                _cameraController !=
                                    null &&
                                _cameras.length >
                                    1)
                              Positioned(
                                bottom: 14,
                                right: 14,
                                child:
                                    GestureDetector(
                                  onTap:
                                      _toggleCameraLens,
                                  child:
                                      Container(
                                    padding:
                                        const EdgeInsets
                                            .all(
                                      10,
                                    ),
                                    decoration:
                                        BoxDecoration(
                                      color: Colors
                                          .black
                                          .withOpacity(
                                        0.5,
                                      ),
                                      shape:
                                          BoxShape
                                              .circle,
                                      border:
                                          Border.all(
                                        color:
                                            Colors
                                                .white24,
                                      ),
                                    ),
                                    child:
                                        const Icon(
                                      Icons
                                          .flip_camera_ios_rounded,
                                      color:
                                          Colors
                                              .white,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                  // ==================================================
                  // SIMULATION
                  // ==================================================

                  if (!_isLiveMode) ...[
                    Text(
                      "Simulation Mode",
                      style:
                          Theme.of(context)
                              .textTheme
                              .titleLarge,
                    ),

                    const SizedBox(
                      height: 4,
                    ),

                    const Text(
                      "Give yourselves sliders/buttons:",
                      style:
                          TextStyle(
                        fontSize: 13,
                        color:
                            Color(
                          0xFF7E726D,
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 12,
                    ),

                    _buildPinterestCard(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children: [
                          _buildSliderRow(
                            title:
                                "Distance",
                            valueDisplay:
                                "${_simDistance.toStringAsFixed(1)} m",
                            value:
                                _simDistance,
                            min: 0.5,
                            max: 5.0,
                            onChanged:
                                (val) {
                              setState(() {
                                _simDistance =
                                    val;
                              });
                            },
                          ),

                          const SizedBox(
                            height: 12,
                          ),

                          _buildSliderRow(
                            title:
                                "Smart glasses",
                            valueDisplay:
                                "${_simSmartGlassesProb.round()}%",
                            value:
                                _simSmartGlassesProb,
                            min: 0,
                            max: 100,
                            onChanged:
                                (val) {
                              setState(() {
                                _simSmartGlassesProb =
                                    val;
                              });
                            },
                          ),

                          const SizedBox(
                            height: 12,
                          ),

                          _buildSliderRow(
                            title:
                                "Interaction duration",
                            valueDisplay:
                                "${_simDuration.round()} sec",
                            value:
                                _simDuration,
                            min: 0,
                            max: 30,
                            onChanged:
                                (val) {
                              setState(() {
                                _simDuration =
                                    val;
                              });
                            },
                          ),

                          const SizedBox(
                            height: 12,
                          ),

                          _buildSliderRow(
                            title:
                                "Orientation",
                            valueDisplay:
                                "${_simOrientation.round()}%",
                            value:
                                _simOrientation,
                            min: 0,
                            max: 100,
                            onChanged:
                                (val) {
                              setState(() {
                                _simOrientation =
                                    val;
                              });
                            },
                          ),

                          const SizedBox(
                            height: 18,
                          ),

                          // BLUETOOTH
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .spaceBetween,
                            children: [
                              const Text(
                                "Bluetooth evidence",
                                style:
                                    TextStyle(
                                  fontWeight:
                                      FontWeight
                                          .bold,
                                  fontSize:
                                      13,
                                  color:
                                      Color(
                                    0xFF332D2B,
                                  ),
                                ),
                              ),

                              InkWell(
                                onTap: () {
                                  setState(
                                    () {
                                      _simBluetoothEvidence =
                                          !_simBluetoothEvidence;
                                    },
                                  );
                                },
                                child:
                                    Container(
                                  padding:
                                      const EdgeInsets
                                          .symmetric(
                                    horizontal:
                                        16,
                                    vertical:
                                        8,
                                  ),
                                  decoration:
                                      BoxDecoration(
                                    color:
                                        const Color(
                                      0xFFFAF7F2,
                                    ),
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      12,
                                    ),
                                    border:
                                        Border.all(
                                      color:
                                          const Color(
                                        0xFFEFEBE4,
                                      ),
                                    ),
                                  ),
                                  child:
                                      Text(
                                    _simBluetoothEvidence
                                        ? "YES"
                                        : "NO",
                                    style:
                                        const TextStyle(
                                      fontFamily:
                                          'monospace',
                                      fontSize:
                                          12,
                                      fontWeight:
                                          FontWeight
                                              .bold,
                                      color:
                                          Color(
                                        0xFFD65345,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(
                            height: 14,
                          ),

                          // MOVEMENT
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .spaceBetween,
                            children: [
                              const Text(
                                "Movement",
                                style:
                                    TextStyle(
                                  fontWeight:
                                      FontWeight
                                          .bold,
                                  fontSize:
                                      13,
                                  color:
                                      Color(
                                    0xFF332D2B,
                                  ),
                                ),
                              ),

                              InkWell(
                                onTap: () {
                                  setState(
                                    () {
                                      _simMovementLow =
                                          !_simMovementLow;
                                    },
                                  );
                                },
                                child:
                                    Container(
                                  padding:
                                      const EdgeInsets
                                          .symmetric(
                                    horizontal:
                                        16,
                                    vertical:
                                        8,
                                  ),
                                  decoration:
                                      BoxDecoration(
                                    color:
                                        const Color(
                                      0xFFFAF7F2,
                                    ),
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      12,
                                    ),
                                    border:
                                        Border.all(
                                      color:
                                          const Color(
                                        0xFFEFEBE4,
                                      ),
                                    ),
                                  ),
                                  child:
                                      Text(
                                    _simMovementLow
                                        ? "LOW"
                                        : "HIGH",
                                    style:
                                        const TextStyle(
                                      fontFamily:
                                          'monospace',
                                      fontSize:
                                          12,
                                      fontWeight:
                                          FontWeight
                                              .bold,
                                      color:
                                          Color(
                                        0xFFD65345,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(
                            height: 24,
                          ),

                          // CALCULATE
                          SizedBox(
                            width:
                                double.infinity,
                            height: 52,
                            child:
                                DecoratedBox(
                              decoration:
                                  BoxDecoration(
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                  30,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color:
                                        const Color(
                                      0xFFD65345,
                                    ).withOpacity(
                                      0.22,
                                    ),
                                    blurRadius:
                                        16,
                                    offset:
                                        const Offset(
                                      0,
                                      6,
                                    ),
                                  ),
                                ],
                              ),
                              child:
                                  ElevatedButton(
                                onPressed:
                                    _calculateRisk,
                                style:
                                    ElevatedButton
                                        .styleFrom(
                                  backgroundColor:
                                      const Color(
                                    0xFFD65345,
                                  ),
                                  foregroundColor:
                                      Colors
                                          .white,
                                  shape:
                                      RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      30,
                                    ),
                                  ),
                                  elevation:
                                      0,
                                ),
                                child:
                                    const Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment
                                          .center,
                                  children: [
                                    Icon(
                                      Icons
                                          .analytics_rounded,
                                      size:
                                          20,
                                    ),
                                    SizedBox(
                                      width:
                                          8,
                                    ),
                                    Text(
                                      "CALCULATE",
                                      style:
                                          TextStyle(
                                        fontSize:
                                            14,
                                        fontWeight:
                                            FontWeight
                                                .bold,
                                        letterSpacing:
                                            1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Text(
                      "Then:",
                      style:
                          TextStyle(
                        fontSize: 13,
                        color:
                            Color(
                          0xFF7E726D,
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 8,
                    ),

                    // RISK OUTPUT
                    _buildPinterestCard(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children: [
                          Text(
                            "RISK SCORE: $_riskScore",
                            style:
                                const TextStyle(
                              fontFamily:
                                  'monospace',
                              fontSize: 15,
                              fontWeight:
                                  FontWeight
                                      .bold,
                              color:
                                  Color(
                                0xFF332D2B,
                              ),
                            ),
                          ),

                          const SizedBox(
                            height: 4,
                          ),

                          Text(
                            _riskLevel,
                            style:
                                TextStyle(
                              fontFamily:
                                  'monospace',
                              fontSize: 13,
                              fontWeight:
                                  FontWeight
                                      .w900,
                              color:
                                  _riskLevel ==
                                          "HIGH RISK"
                                      ? const Color(
                                          0xFFD65345,
                                        )
                                      : (_riskLevel ==
                                              "MEDIUM RISK"
                                          ? Colors
                                              .amber[800]
                                          : const Color(
                                              0xFF6E8E7D,
                                            )),
                            ),
                          ),

                          const SizedBox(
                            height: 16,
                          ),
                        ],
                      ),
                    ),
                  ],

                  // ==================================================
                  // LOGS
                  // ==================================================

                  _buildPinterestCard(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .spaceBetween,
                          children: [
                            const Text(
                              "Safety Event Logs",
                              style:
                                  TextStyle(
                                fontFamily:
                                    'serif',
                                fontSize:
                                    15,
                                fontWeight:
                                    FontWeight
                                        .bold,
                                color:
                                    Color(
                                  0xFF332D2B,
                                ),
                              ),
                            ),

                            if (_alertsLog
                                .isNotEmpty)
                              TextButton(
                                onPressed:
                                    _clearLogs,
                                child:
                                    const Text(
                                  "Clear",
                                  style:
                                      TextStyle(
                                    color:
                                        Color(
                                      0xFF7E726D,
                                    ),
                                    fontSize:
                                        12,
                                  ),
                                ),
                              ),
                          ],
                        ),

                        const Divider(
                          color:
                              Color(
                            0xFFFAF2EC,
                          ),
                        ),

                        if (_alertsLog
                            .isEmpty)
                          const Padding(
                            padding:
                                EdgeInsets
                                    .symmetric(
                              vertical: 20,
                            ),
                            child:
                                Center(
                              child:
                                  Text(
                                "No incidents logged. System safe.",
                                style:
                                    TextStyle(
                                  color:
                                      Color(
                                    0xFF7E726D,
                                  ),
                                  fontSize:
                                      12,
                                ),
                              ),
                            ),
                          )
                        else
                          ListView
                              .separated(
                            shrinkWrap:
                                true,
                            physics:
                                const NeverScrollableScrollPhysics(),
                            itemCount:
                                _alertsLog
                                            .length >
                                        5
                                    ? 5
                                    : _alertsLog
                                        .length,
                            separatorBuilder:
                                (
                              _,
                              __,
                            ) =>
                                    const Divider(
                              color:
                                  Color(
                                0xFFFAF2EC,
                              ),
                            ),
                            itemBuilder:
                                (
                              context,
                              index,
                            ) {
                              final log =
                                  _alertsLog[
                                      index];

                              return Padding(
                                padding:
                                    const EdgeInsets
                                        .symmetric(
                                  vertical:
                                      4,
                                ),
                                child:
                                    Text(
                                  log,
                                  style:
                                      const TextStyle(
                                    fontSize:
                                        12,
                                    fontFamily:
                                        'monospace',
                                    color:
                                        Color(
                                      0xFF7E726D,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),

                  // ==================================================
                  // FOOTER
                  // ==================================================

                  const Center(
                    child: Text(
                      "Glance Safety Shield v1.6.0 • BLE Smart Glasses Detection",
                      style:
                          TextStyle(
                        color:
                            Color(
                          0xFF7E726D,
                        ),
                        fontSize: 10,
                      ),
                    ),
                  ),

                  const SizedBox(
                    height: 20,
                  ),
                ],
              ),
            ),
          ),

          // ========================================================
          // EMERGENCY OVERLAY
          // ========================================================

          if (_isAlarmActive)
            Positioned.fill(
              child:
                  Container(
                color:
                    const Color(
                  0xFFFAF7F2,
                ),
                child:
                    SafeArea(
                  child:
                      Padding(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      horizontal: 24,
                      vertical: 32,
                    ),
                    child:
                        Column(
                      mainAxisAlignment:
                          MainAxisAlignment
                              .spaceBetween,
                      children: [
                        const SizedBox(
                          height: 20,
                        ),

                        // ALARM HEADER
                        Column(
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              decoration:
                                  BoxDecoration(
                                shape:
                                    BoxShape
                                        .circle,
                                color:
                                    const Color(
                                  0xFFFDF0ED,
                                ),
                                border:
                                    Border.all(
                                  color:
                                      const Color(
                                    0xFFF5D6D1,
                                  ),
                                ),
                              ),
                              child:
                                  const Icon(
                                Icons
                                    .report_problem_rounded,
                                size: 50,
                                color:
                                    Color(
                                  0xFFD65345,
                                ),
                              ),
                            ),

                            const SizedBox(
                              height: 24,
                            ),

                            const Text(
                              "EMERGENCY ACTIVE",
                              textAlign:
                                  TextAlign
                                      .center,
                              style:
                                  TextStyle(
                                fontFamily:
                                    'serif',
                                fontSize:
                                    26,
                                fontWeight:
                                    FontWeight
                                        .bold,
                                color:
                                    Color(
                                  0xFFD65345,
                                ),
                                letterSpacing:
                                    1,
                              ),
                            ),

                            const SizedBox(
                              height: 16,
                            ),

                            const Text(
                              "A high-threat signature has triggered on-device security measures. The camera sensor is open and vibration feedback is running.",
                              textAlign:
                                  TextAlign
                                      .center,
                              style:
                                  TextStyle(
                                fontSize:
                                    14,
                                color:
                                    Color(
                                  0xFF7E726D,
                                ),
                                height:
                                    1.5,
                              ),
                            ),
                          ],
                        ),

                        // THREAT DETAILS
                        if (!_isLiveMode)
                          _buildPinterestCard(
                            padding:
                                const EdgeInsets
                                    .all(
                              20,
                            ),
                            child:
                                Row(
                              children: [
                                const Icon(
                                  Icons
                                      .security_sharp,
                                  color:
                                      Color(
                                    0xFFD65345,
                                  ),
                                  size:
                                      24,
                                ),
                                const SizedBox(
                                  width: 14,
                                ),
                                Expanded(
                                  child:
                                      Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment
                                            .start,
                                    children: [
                                      const Text(
                                        "THREAT ENGINE TRIGGER",
                                        style:
                                            TextStyle(
                                          fontSize:
                                              12,
                                          fontWeight:
                                              FontWeight
                                                  .bold,
                                          color:
                                              Color(
                                            0xFFD65345,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(
                                        height:
                                            2,
                                      ),
                                      Text(
                                        "Calculated risk level was $_riskScore% (HIGH)",
                                        style:
                                            const TextStyle(
                                          fontSize:
                                              12,
                                          color:
                                              Color(
                                            0xFF7E726D,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // DISARM
                        Column(
                          children: [
                            SizedBox(
                              width:
                                  double.infinity,
                              height: 56,
                              child:
                                  DecoratedBox(
                                decoration:
                                    BoxDecoration(
                                  borderRadius:
                                      BorderRadius
                                          .circular(
                                    30,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          const Color(
                                        0xFF6E8E7D,
                                      ).withOpacity(
                                        0.20,
                                      ),
                                      blurRadius:
                                          16,
                                      offset:
                                          const Offset(
                                        0,
                                        6,
                                      ),
                                    ),
                                  ],
                                ),
                                child:
                                    ElevatedButton(
                                  onPressed:
                                      _disarmAlarm,
                                  style:
                                      ElevatedButton
                                          .styleFrom(
                                    backgroundColor:
                                        const Color(
                                      0xFF6E8E7D,
                                    ),
                                    foregroundColor:
                                        Colors
                                            .white,
                                    shape:
                                        RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius
                                              .circular(
                                        30,
                                      ),
                                    ),
                                    elevation:
                                        0,
                                  ),
                                  child:
                                      const Text(
                                    "DISARM COMPANION",
                                    style:
                                        TextStyle(
                                      fontSize:
                                          15,
                                      fontWeight:
                                          FontWeight
                                              .bold,
                                      letterSpacing:
                                          1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(
                              height: 12,
                            ),

                            const Text(
                              "TAP TO RESET SECURITY SHIELD",
                              style:
                                  TextStyle(
                                color:
                                    Color(
                                  0xFF7E726D,
                                ),
                                fontSize:
                                    11,
                                letterSpacing:
                                    1,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}