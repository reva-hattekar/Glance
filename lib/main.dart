import 'dart:io';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Force portrait orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  
  runApp(const SafeSightApp());
}

class SafeSightApp extends StatelessWidget {
  const SafeSightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeSight Companion',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFAF7F2), // Warm Alabaster/Cream
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFE05A47), // Muted Coral/Terracotta
          secondary: Color(0xFF6E8E7D), // Soft Sage Green
          surface: Colors.white,
          error: Color(0xFFC94A38),
        ),
        textTheme: const TextTheme(
          displayMedium: TextStyle(
            fontFamily: 'serif',
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Color(0xFF332D2B), // Deep Espresso
          ),
          titleLarge: TextStyle(
            fontFamily: 'serif',
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Color(0xFF332D2B),
          ),
          bodyLarge: TextStyle(
            color: Color(0xFF332D2B),
            fontSize: 16,
          ),
          bodyMedium: TextStyle(
            color: Color(0xFF7D726E), // Soft Grey
            fontSize: 14,
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

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  static const platform = MethodChannel('com.safelens/monitor');

  // Modes
  bool _isLiveMode = false; // false = Simulation Mode, true = Live Mode
  
  // App States
  bool _isBackgroundShieldActive = false;
  bool _isAlarmActive = false;
  
  // Camera Variables
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isCameraStarting = false;

  // ===== REAL COMPUTER VISION =====
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

  // Logs & Polling
  List<String> _alertsLog = [];
  Timer? _pendingAlarmPoller;

  // --- Simulation Parameters (Matching Mockup Image) ---
  double _simDistance = 1.5;              // 0.5m to 5.0m
  double _simSmartGlassesProb = 92.0;     // 0% to 100%
  double _simDuration = 7.0;              // 0s to 30s
  double _simOrientation = 75.0;          // 0% to 100%
  bool _simBluetoothEvidence = true;      // YES / NO
  bool _simMovementLow = true;            // LOW / HIGH

  // --- Risk Engine Result ---
  int _riskScore = 0;
  String _riskLevel = "LOW RISK";

  @override
void initState() {
  super.initState();

  _initFaceDetection();
  _initGlassesModel();

  WidgetsBinding.instance.addObserver(this);
    _initializePermissionsAndStatus();
    _loadAlertLogs();
    
    // Periodically poll for background native service alarms
    _pendingAlarmPoller = Timer.periodic(const Duration(seconds: 1), (timer) {
      _checkPendingBackgroundAlarm();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pendingAlarmPoller?.cancel();
    _disposeCamera();
    _faceDetector?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkBackgroundShieldStatus();
      _checkPendingBackgroundAlarm();
    }
  }

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

Future<void> _runGlassesModel(
  CameraImage cameraImage,
  Rect faceBox,
) async {
  if (_glassesInterpreter == null) return;

  try {
    // Convert NV21 camera frame → RGB image
    final rgbImage = _nv21ToRgb(cameraImage);

    if (rgbImage == null) return;

    // Convert ML Kit face coordinates to integers
    int x = faceBox.left.round();
    int y = faceBox.top.round();
    int width = faceBox.width.round();
    int height = faceBox.height.round();

    // Add some padding around the face.
    // This gives the model a little more context around the glasses.
    final paddingX = (width * 0.15).round();
    final paddingY = (height * 0.15).round();

    x -= paddingX;
    y -= paddingY;
    width += paddingX * 2;
    height += paddingY * 2;

    // Keep crop inside image boundaries
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

    // Resize to EXACTLY what the model expects
    final resized = img.copyResize(
      faceCrop,
      width: 224,
      height: 224,
      interpolation: img.Interpolation.linear,
    );

    // Build [1, 224, 224, 3]
    final input = List.generate(
      1,
      (_) => List.generate(
        224,
        (y) => List.generate(
          224,
          (x) {
            final pixel = resized.getPixel(x, y);

            return [
              pixel.r.toDouble(),
              pixel.g.toDouble(),
              pixel.b.toDouble(),
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
      _liveSmartGlassesProb = probability * 100;
    });
  } catch (e, stackTrace) {
    debugPrint("GLASSES MODEL ERROR: $e");
    debugPrint("$stackTrace");
  }
}

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

        final r = (1.164 * (yValue - 16) + 1.596 * (v - 128))
            .round()
            .clamp(0, 255);

        final g = (1.164 * (yValue - 16) -
                0.813 * (v - 128) -
                0.391 * (u - 128))
            .round()
            .clamp(0, 255);

        final b = (1.164 * (yValue - 16) + 2.018 * (u - 128))
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

  // --- Initialization Helper ---
  Future<void> _initializePermissionsAndStatus() async {
    await [
      Permission.camera,
      Permission.notification,
    ].request();

    await _checkBackgroundShieldStatus();
    await _checkPendingBackgroundAlarm();
    
    try {
      _cameras = await availableCameras();
    } catch (e) {
      _logEvent('No camera sensors found: ${e.toString()}');
    }
  }

  Future<void> _loadAlertLogs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _alertsLog = prefs.getStringList('alerts_log') ?? [];
    });
  }

  Future<void> _logEvent(String message) async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = DateTime.now().toLocal().toString().substring(11, 19);
    final logEntry = '[$timestamp] $message';
    
    setState(() {
      _alertsLog.insert(0, logEntry);
      if (_alertsLog.length > 50) {
        _alertsLog.removeLast();
      }
    });
    await prefs.setStringList('alerts_log', _alertsLog);
  }

  Future<void> _clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _alertsLog.clear();
    });
    await prefs.remove('alerts_log');
  }

  // --- Native Service Channel ---
  Future<void> _checkBackgroundShieldStatus() async {
    try {
      final bool isActive = await platform.invokeMethod('isMonitoring');
      setState(() {
        _isBackgroundShieldActive = isActive;
      });
    } on PlatformException catch (e) {
      debugPrint("Failed to get monitoring status: '${e.message}'.");
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
  if (_isProcessingFrame || _faceDetector == null) return;

  _frameCounter++;

  // Process roughly every 5th frame.
  if (_frameCounter % 5 != 0) return;

  _isProcessingFrame = true;

  try {
    final inputImage = _convertCameraImage(image);

    if (inputImage == null) return;

    debugPrint("CV ✓ Sending frame to ML Kit");

final faces =
    await _faceDetector!.processImage(inputImage);

debugPrint("CV ✓ Faces found: ${faces.length}");

    if (!mounted) return;

    // =========================
    // NO PERSON
    // =========================

    if (faces.isEmpty) {
  setState(() {
    _personDetected = false;
    _interactionDetected = false;
    _liveDistance = 0;
    _liveOrientation = 0;
    _liveDuration = 0;
    _liveSmartGlassesProb = 0;
    _movement = 0;
  });

  _interactionStart = null;
  return;
}

    // Pick the largest face
    faces.sort(
      (a, b) =>
          b.boundingBox.width.compareTo(a.boundingBox.width),
    );

    final face = faces.first;
    final box = face.boundingBox;
    await _runGlassesModel(image, box);

    // =========================
    // 1. DISTANCE
    // =========================

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

    // =========================
// 2. INTERACTION
// =========================

const interactionThreshold = 7.0;

final closeEnough = distance <= 2.5;

if (closeEnough) {
  _interactionStart ??= DateTime.now();

  _liveDuration =
      DateTime.now()
              .difference(_interactionStart!)
              .inMilliseconds /
          1000.0;

  // Interaction only becomes TRUE after sustained proximity
  _interactionDetected =
      _liveDuration >= interactionThreshold;
} else {
  _interactionStart = null;
  _interactionDetected = false;
  _liveDuration = 0;
}

    // =========================
    // 3. ORIENTATION
    // =========================

    final yaw = face.headEulerAngleY ?? 90.0;
    final pitch = face.headEulerAngleX ?? 90.0;

    final yawScore =
        (1 - (yaw.abs() / 45.0)).clamp(0.0, 1.0);

    final pitchScore =
        (1 - (pitch.abs() / 30.0)).clamp(0.0, 1.0);

    final orientation =
        ((yawScore * 0.7) + (pitchScore * 0.3)) * 100;

    // =========================
    // 4. MOVEMENT
    // =========================

    final currentX = box.center.dx;

    _movement =
        (_lastFaceX == 0)
            ? 0
            : (currentX - _lastFaceX).abs();

    _lastFaceX = currentX;

    // =========================
    // UPDATE
    // =========================

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
      "Duration: ${_liveDuration.toStringAsFixed(1)}s",
    );

  } catch (e) {
    debugPrint("Face processing error: $e");
  } finally {
    _isProcessingFrame = false;
  }
}

  Future<void> _checkPendingBackgroundAlarm() async {
    try {
      final bool hasPending = await platform.invokeMethod('consumePendingAlarm');
      if (hasPending && !_isAlarmActive) {
        _triggerAlarmLocal("Spyware camera usage detected!");
      }
    } on PlatformException catch (e) {
      debugPrint("Failed to consume pending alarm: '${e.message}'.");
    }
  }

  Future<void> _toggleBackgroundShield(bool enable) async {
    try {
      if (enable) {
        await platform.invokeMethod('startMonitoring');
        await _logEvent('Privacy Radar Background monitoring active');
      } else {
        await platform.invokeMethod('stopMonitoring');
        await _logEvent('Privacy Radar Background monitoring stopped');
      }
      setState(() {
        _isBackgroundShieldActive = enable;
      });
    } on PlatformException catch (e) {
      _logEvent('Shield Service Error: ${e.message}');
    }
  }

  // --- Camera Management ---
  Future<void> _initCamera() async {
    if (_cameras.isEmpty) {
      try {
        _cameras = await availableCameras();
      } catch (e) {
        _logEvent('Camera initialization failed: no camera found.');
        return;
      }
    }

    if (_cameras.isEmpty) return;

    setState(() {
      _isCameraStarting = true;
    });

    // Notify Kotlin side we are using camera to prevent self-trigger
    try {
      await platform.invokeMethod('setAppUsingCamera', {'using': true});
    } catch (_) {}

    _cameraController = CameraController(
  _cameras.first,
  ResolutionPreset.low,
  enableAudio: false,
  imageFormatGroup: ImageFormatGroup.nv21,
);

    try {
      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_processCameraImage);
      if (!mounted) return;
      setState(() {
        _isCameraInitialized = true;
        _isCameraStarting = false;
      });
    } catch (e) {
      _logEvent('Camera init error: ${e.toString()}');
      setState(() {
        _isCameraStarting = false;
      });
      // Reset flag
      try {
        await platform.invokeMethod('setAppUsingCamera', {'using': false});
      } catch (_) {}
    }
  }

  Future<void> _disposeCamera() async {
    setState(() {
      _isCameraInitialized = false;
    });
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }
    try {
      await platform.invokeMethod('setAppUsingCamera', {'using': false});
    } catch (_) {}
  }

  InputImage? _convertCameraImage(CameraImage image) {
  if (!Platform.isAndroid) return null;

  if (_cameraController == null) return null;

  if (image.planes.length != 1) {
    debugPrint(
      "CV ❌ Wrong plane count: ${image.planes.length}",
    );
    return null;
  }
  final camera = _cameras.first;

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

  if (rotationCompensation == null) return null;

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

  // --- Risk Engine Calculation ---
  void _calculateRisk() {
    double score = 0;

    // 1. Distance Flow: Closer is higher risk (max 25 pts)
    if (_simDistance <= 2.0) {
      // Linear scaling: 0.5m = 25 pts, 2.0m = 10 pts
      double distFactor = (2.0 - _simDistance) / 1.5; // 0.0 to 1.0
      score += 10 + (distFactor * 15);
    }

    // 2. Smart Glasses detection prob (max 30 pts)
    score += (_simSmartGlassesProb * 0.3);

    // 3. Interaction Duration: >= 5s adds 15 pts
    if (_simDuration >= 5.0) {
      score += 15;
    }

    // 4. Orientation Alignment (max 15 pts)
    score += (_simOrientation * 0.15);

    // 5. BLE Device scanning (max 15 pts)
    if (_simBluetoothEvidence) {
      score += 15;
    }

    // 6. Movement status (max 10 pts)
    if (_simMovementLow) {
      score += 10; // Stealthy/low movement near target is riskier
    }

    // Clamp score between 0 and 100
    int finalScore = score.round().clamp(0, 100);

    String level = "LOW RISK";
    if (finalScore >= 75) {
      level = "HIGH RISK";
    } else if (finalScore >= 40) {
      level = "MEDIUM RISK";
    }

    setState(() {
      _riskScore = finalScore;
      _riskLevel = level;
    });

    _logEvent('Risk Calculated: $finalScore% - $level');

    // Auto-trigger safety alarm and camera mode if risk is HIGH
    if (level == "HIGH RISK" && !_isAlarmActive) {
      _triggerAlarmLocal("Simulated threat level reached HIGH ($finalScore%)");
    }
  }

  void _calculateLiveRisk() {
  if (!_isLiveMode || !_personDetected) {
    return;
  }

  double score = 0;

  // =========================
  // 1. DISTANCE — 25 points
  // =========================

  if (_liveDistance <= 2.0) {
    final distFactor =
        ((2.0 - _liveDistance) / 1.5).clamp(0.0, 1.0);

    score += 10 + (distFactor * 15);
  }

  // =========================
  // 2. INTERACTION — 15 points
  // =========================

  if (_interactionDetected) {
    score += 15;
  }

  // =========================
  // 3. ORIENTATION — 15 points
  // =========================

  score += _liveOrientation * 0.15;

  // =========================
  // 4. SMART GLASSES — 20 points
  // =========================

  score += _liveSmartGlassesProb * 0.20;

  // =========================
  // 5. MOVEMENT — 10 points
  // =========================

  // Low movement = more suspicious.
  final movementLow = _movement < 8.0;

  if (movementLow) {
    score += 10;
  }

  // =========================
  // 6. BLE — 15 points
  // =========================

  // Temporary until live BLE scanning is connected.
  // Simulation BLE remains separate.
  final liveBluetoothEvidence = false;

  if (liveBluetoothEvidence) {
    score += 15;
  }

  // =========================
  // FINAL SCORE
  // =========================

  final finalScore = score.round().clamp(0, 100);

  String level;

  if (finalScore >= 75) {
    level = "HIGH RISK";
  } else if (finalScore >= 40) {
    level = "MEDIUM RISK";
  } else {
    level = "LOW RISK";
  }

  final previousLevel = _riskLevel;

  setState(() {
    _riskScore = finalScore;
    _riskLevel = level;
  });

  // Only log when risk level changes.
  // DO NOT write to logs on every camera frame.
  if (previousLevel != level) {
    _logEvent(
      'Live Risk: $finalScore% - $level',
    );
  }

  // HIGH RISK automatically triggers the
  // exact same alarm used by SOS.
  if (level == "HIGH RISK" && !_isAlarmActive) {
    _triggerAlarmLocal(
      "Live threat signature detected ($finalScore%)",
    );
  }
}

  // --- Local Alarm Trigger ---
  Future<void> _triggerAlarmLocal(String cause) async {
    if (_isAlarmActive) return;

    setState(() {
      _isAlarmActive = true;
    });

    await _logEvent('🚨 SAFETY ALARM: $cause');
    await WakelockPlus.enable();

    // Auto-initialize camera if not done yet
    if (!_isCameraInitialized && !_isCameraStarting) {
      _initCamera();
    }

    // Start pulsing vibration pattern
    _startVibrationLoop();
  }

  void _startVibrationLoop() async {
    bool hasVibrator = await Vibration.hasVibrator();
    if (!hasVibrator) return;

    Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
      if (!_isAlarmActive) {
        timer.cancel();
        return;
      }
      Vibration.vibrate(pattern: [0, 500, 250, 500], repeat: -1);
    });
  }

  Future<void> _disarmAlarm() async {
    setState(() {
      _isAlarmActive = false;
      // Reset risk score if in simulation
      if (!_isLiveMode) {
        _riskScore = 0;
        _riskLevel = "LOW RISK";
      }
    });

    await WakelockPlus.disable();
    await Vibration.cancel();
    
    // Stop native service alarm components
    try {
      await platform.invokeMethod('stopAlarm');
    } catch (_) {}

    await _disposeCamera();
    await _logEvent('Safety Companion Disarmed');
  }

  // Manual SOS Alarm
  void _triggerManualSOS() {
    _triggerAlarmLocal("Manual Panic SOS Triggered");
    try {
      platform.invokeMethod('sos');
    } catch (_) {}
  }

  // --- UI Card Builders ---
  
  Widget _buildPinterestCard({
    required Widget child,
    Color? color,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF332D2B).withValues(alpha: 0.04),
            blurRadius: 24,
            offset: const Offset(0, 10),
          )
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: child,
      ),
    );
  }

  // Sliders helper
  Widget _buildSliderRow({
    required String title,
    required String valueDisplay,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF332D2B)),
            ),
            Text(
              '[ $valueDisplay ]',
              style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFE05A47)),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFFE05A47),
            inactiveTrackColor: const Color(0xFFECE5DD),
            thumbColor: const Color(0xFFE05A47),
            overlayColor: const Color(0xFFE05A47).withValues(alpha: 0.12),
            valueIndicatorColor: const Color(0xFFE05A47),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Main Scrollable Pinterest Board
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "SafeSight",
                            style: Theme.of(context).textTheme.displayMedium,
                          ),
                          const Text(
                            "Your Personal Safety Shield",
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF7D726E),
                            ),
                          ),
                        ],
                      ),
                      // Cozy Icon Badge
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isAlarmActive 
                              ? const Color(0xFFFBEAEA) 
                              : const Color(0xFFE8F1EC),
                        ),
                        child: Icon(
                          _isAlarmActive 
                              ? Icons.security_update_warning_rounded 
                              : Icons.gpp_good_outlined,
                          color: _isAlarmActive 
                              ? const Color(0xFFE05A47) 
                              : const Color(0xFF6E8E7D),
                          size: 26,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),

                  // 1. PRIVACY RADAR Selector Card
                  _buildPinterestCard(
                    child: Padding(
                      padding: const EdgeInsets.all(22.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "PRIVACY RADAR",
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                  color: Color(0xFF332D2B),
                                ),
                              ),
                              Icon(Icons.radar_rounded, color: Color(0xFF7D726E), size: 20),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      _isLiveMode = true;
                                    });
                                    _initCamera();
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    decoration: BoxDecoration(
                                      color: _isLiveMode 
                                          ? const Color(0xFFE05A47) 
                                          : const Color(0xFFFAF7F2),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      "[ LIVE MODE ]",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: _isLiveMode ? Colors.white : const Color(0xFF7D726E),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      _isLiveMode = false;
                                    });
                                    _disarmAlarm();
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    decoration: BoxDecoration(
                                      color: !_isLiveMode 
                                          ? const Color(0xFFE05A47) 
                                          : const Color(0xFFFAF7F2),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      "[ SIMULATION MODE ]",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: !_isLiveMode ? Colors.white : const Color(0xFF7D726E),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 2. LIVE CAMERA CARD (Shown when Live Mode or alarm is active)
                  if (_isLiveMode || _isAlarmActive)
                    _buildPinterestCard(
                      child: Container(
                        height: 300,
                        color: Colors.black,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_isCameraInitialized && _cameraController != null)
                              CameraPreview(_cameraController!)
                            else
                              const Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircularProgressIndicator(color: Colors.white),
                                    SizedBox(height: 16),
                                    Text(
                                      "Initializing Safety Lens Feed...",
                                      style: TextStyle(color: Colors.white70, fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            Positioned(
                              top: 14,
                              left: 14,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFC94A38).withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    const Text(
                                      "MONITORING ACTIVE",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              bottom: 14,
                              left: 14,
                              right: 14,
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.72),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _personDetected
                                          ? "🟢 PERSON DETECTED"
                                          : "🔴 NO PERSON",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),

                                    const SizedBox(height: 8),

                                    Text(
                                      "Distance     ${_liveDistance.toStringAsFixed(1)} m",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                      ),
                                    ),

                                    Text(
                                      "Orientation  ${_liveOrientation.toStringAsFixed(0)}%",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                      ),
                                    ),

                                    Text(
                                      "Interaction  ${_interactionDetected ? "YES" : "NO"}",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                      ),
                                    ),

                                    Text(
                                      "Duration     ${_liveDuration.toStringAsFixed(1)} s",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                      ),
                                    ),

                                    Text(
                                      "Glasses      ${_liveSmartGlassesProb.toStringAsFixed(0)}%",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                      ),
                                    ),

                                    Text(
                                      "Movement     ${_movement < 8 ? "LOW" : "HIGH"}",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                      ),
                                    ),

                                    const SizedBox(height: 8),

                                    Text(
                                      "RISK  $_riskScore%  •  $_riskLevel",
                                      style: TextStyle(
                                        color: _riskLevel == "HIGH RISK"
                                            ? const Color(0xFFFF6B57)
                                            : Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 3. SIMULATION MODE SETTINGS (Matching Mockup design)
                  if (!_isLiveMode) ...[
                    Text(
                      "Simulation Mode",
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Give yourselves sliders/buttons:",
                      style: TextStyle(fontSize: 13, color: Color(0xFF7D726E)),
                    ),
                    const SizedBox(height: 12),
                    _buildPinterestCard(
                      child: Padding(
                        padding: const EdgeInsets.all(22.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Distance Slider
                            _buildSliderRow(
                              title: "Distance",
                              valueDisplay: "${_simDistance.toStringAsFixed(1)} m",
                              value: _simDistance,
                              min: 0.5,
                              max: 5.0,
                              onChanged: (val) {
                                setState(() {
                                  _simDistance = val;
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                            // Smart Glasses Detection Slider
                            _buildSliderRow(
                              title: "Smart glasses",
                              valueDisplay: "${_simSmartGlassesProb.round()}%",
                              value: _simSmartGlassesProb,
                              min: 0,
                              max: 100,
                              onChanged: (val) {
                                setState(() {
                                  _simSmartGlassesProb = val;
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                            // Interaction Duration Slider
                            _buildSliderRow(
                              title: "Interaction duration",
                              valueDisplay: "${_simDuration.round()} sec",
                              value: _simDuration,
                              min: 0,
                              max: 30,
                              onChanged: (val) {
                                setState(() {
                                  _simDuration = val;
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                            // Orientation Slider
                            _buildSliderRow(
                              title: "Orientation",
                              valueDisplay: "${_simOrientation.round()}%",
                              value: _simOrientation,
                              min: 0,
                              max: 100,
                              onChanged: (val) {
                                setState(() {
                                  _simOrientation = val;
                                });
                              },
                            ),
                            const SizedBox(height: 18),
                            // Bluetooth Evidence Toggle
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  "Bluetooth evidence",
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF332D2B)),
                                ),
                                InkWell(
                                  onTap: () {
                                    setState(() {
                                      _simBluetoothEvidence = !_simBluetoothEvidence;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFAF7F2),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: const Color(0xFFECE5DD)),
                                    ),
                                    child: Text(
                                      "[ ${_simBluetoothEvidence ? "YES" : "NO"} ]",
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFFE05A47),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            // Movement Status Toggle
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  "Movement",
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF332D2B)),
                                ),
                                InkWell(
                                  onTap: () {
                                    setState(() {
                                      _simMovementLow = !_simMovementLow;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFAF7F2),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: const Color(0xFFECE5DD)),
                                    ),
                                    child: Text(
                                      "[ ${_simMovementLow ? "LOW" : "HIGH"} ]",
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFFE05A47),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            // CALCULATE button
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: ElevatedButton(
                                onPressed: _calculateRisk,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF332D2B),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: const Text(
                                  "[ CALCULATE ]",
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    
                    // Risk Engine Output Card
                    const Text(
                      "Then:",
                      style: TextStyle(fontSize: 13, color: Color(0xFF7D726E)),
                    ),
                    const SizedBox(height: 8),
                    _buildPinterestCard(
                      child: Padding(
                        padding: const EdgeInsets.all(22.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "RISK SCORE: $_riskScore",
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF332D2B),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _riskLevel,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                fontWeight: FontWeight.w900,
                                color: _riskLevel == "HIGH RISK" 
                                    ? const Color(0xFFE05A47) 
                                    : (_riskLevel == "MEDIUM RISK" ? Colors.amber[800] : const Color(0xFF6E8E7D)),
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: OutlinedButton(
                                onPressed: _triggerManualSOS,
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Color(0xFFE05A47), width: 1.5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.vibration, color: Color(0xFFE05A47), size: 18),
                                    SizedBox(width: 8),
                                    Text(
                                      "ALERT",
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFFE05A47),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // 4. Background Spyware Protection Toggle Card
                  _buildPinterestCard(
                    child: Padding(
                      padding: const EdgeInsets.all(22.0),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _isBackgroundShieldActive
                                  ? const Color(0xFFE8F1EC)
                                  : const Color(0xFFFAF7F2),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.security_sharp,
                              color: _isBackgroundShieldActive
                                  ? const Color(0xFF6E8E7D)
                                  : const Color(0xFF7D726E),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Spyware Protection",
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF332D2B)),
                                ),
                                Text(
                                  _isBackgroundShieldActive 
                                      ? "Background monitor shield is active" 
                                      : "Turn on background protection",
                                  style: const TextStyle(fontSize: 12, color: Color(0xFF7D726E)),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _isBackgroundShieldActive,
                            onChanged: _toggleBackgroundShield,
                            activeThumbColor: const Color(0xFF6E8E7D),
                            activeTrackColor: const Color(0xFFE8F1EC),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 5. MANUAL SOS TRIGGERS
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _triggerManualSOS,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE05A47),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        elevation: 4,
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.white, size: 24),
                          SizedBox(width: 10),
                          Text(
                            "PANIC SOS TRIGGER",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 6. Security Incident Logs
                  _buildPinterestCard(
                    child: Padding(
                      padding: const EdgeInsets.all(22.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Safety Event Logs",
                                style: TextStyle(
                                  fontFamily: 'serif',
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF332D2B),
                                ),
                              ),
                              if (_alertsLog.isNotEmpty)
                                TextButton(
                                  onPressed: _clearLogs,
                                  child: const Text(
                                    "Clear",
                                    style: TextStyle(color: Color(0xFF7D726E), fontSize: 12),
                                  ),
                                ),
                            ],
                          ),
                          const Divider(color: Color(0xFFECE5DD)),
                          if (_alertsLog.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24.0),
                              child: Center(
                                child: Text(
                                  "No incidents logged. System safe.",
                                  style: TextStyle(color: Color(0xFF7D726E), fontSize: 13),
                                ),
                              ),
                            )
                          else
                            ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _alertsLog.length > 5 ? 5 : _alertsLog.length,
                              separatorBuilder: (_, _) => const Divider(color: Color(0xFFFAF7F2)),
                              itemBuilder: (context, index) {
                                final log = _alertsLog[index];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                                  child: Text(
                                    log,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      color: Color(0xFF7D726E),
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  
                  const Center(
                    child: Text(
                      "SafeSight Shield v1.1.0 • Designed for Personal Care",
                      style: TextStyle(color: Color(0xFF7D726E), fontSize: 10),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),

          // EMERGENCY ALARM RED OVERLAY SCREEN
          if (_isAlarmActive)
            Positioned.fill(
              child: Container(
                color: const Color(0xFFFAF7F2), // Keep Pinterest light color background
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const SizedBox(height: 20),
                        
                        // Alarm Signal Icons
                        Column(
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFFBEAEA),
                              ),
                              child: const Icon(
                                Icons.report_problem_rounded,
                                size: 50,
                                color: Color(0xFFE05A47),
                              ),
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              "EMERGENCY ACTIVE",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: 'serif',
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFE05A47),
                                letterSpacing: 1,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              "A high-threat signature has triggered on-device security measures. The camera sensor is open and vibration feedback is running.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF7D726E),
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),

                        // Alarm Source Details
                        if (!_isLiveMode)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF332D2B).withValues(alpha: 0.04),
                                  blurRadius: 16,
                                )
                              ],
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.security_sharp, color: Color(0xFFE05A47), size: 24),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "THREAT ENGINE TRIGGER",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFFE05A47),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        "Calculated risk level was $_riskScore% (HIGH)",
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF7D726E),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // Disarm Button (Hold/Tap to disarm)
                        Column(
                          children: [
                            SizedBox(
                              width: double.infinity,
                              height: 64,
                              child: ElevatedButton(
                                onPressed: _disarmAlarm,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF6E8E7D),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  elevation: 2,
                                ),
                                child: const Text(
                                  "DISARM COMPANION",
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              "TAP TO RESET SECURITY SHIELD",
                              style: TextStyle(
                                color: Color(0xFF7D726E),
                                fontSize: 11,
                                letterSpacing: 1,
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
