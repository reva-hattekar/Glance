import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'services/smart_glasses_scanner.dart';
import 'widgets/smart_glasses_detector_card.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Force portrait orientation
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
        scaffoldBackgroundColor: const Color(0xFFFAF7F2), // Warm Alabaster/Cream base
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFD65345), // Elegant Terracotta/Coral
          secondary: Color(0xFF6E8E7D), // Sage Green
          surface: Colors.white,
          error: Color(0xFFC94A38),
        ),
        textTheme: const TextTheme(
          displayMedium: TextStyle(
            fontFamily: 'serif',
            fontSize: 27,
            fontWeight: FontWeight.bold,
            color: Color(0xFF332D2B), // Deep Espresso
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
            color: Color(0xFF7E726D), // Soft Warm Clay Grey
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

class _DashboardScreenState extends State<DashboardScreen> {
  // Modes
  bool _isLiveMode = false; // false = Simulation Mode, true = Live Mode
  
  // App States
  bool _isAlarmActive = false;
  
  // Camera Variables
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isCameraStarting = false;
  int _selectedCameraIndex = 0;

  // Logs
  List<String> _alertsLog = [];

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

  // --- BLE Smart Glasses Detection ---
  List<SmartGlassDevice> _detectedGlasses = [];
  StreamSubscription<List<SmartGlassDevice>>? _glassesSub;

  @override
  void initState() {
    super.initState();
    _initializePermissionsAndStatus();
    _loadAlertLogs();
    _startGlassesScanner();
  }

  @override
  void dispose() {
    _glassesSub?.cancel();
    _disposeCamera(silent: true);
    super.dispose();
  }

  // --- Smart Glasses BLE Scanner ---
  void _startGlassesScanner() {
    _glassesSub = SmartGlassesScanner.instance.devicesStream.listen(_onGlassesChanged);
    SmartGlassesScanner.instance.start();
  }

  void _onGlassesChanged(List<SmartGlassDevice> devices) {
    _detectedGlasses = devices;
    if (!_isLiveMode || _isAlarmActive || devices.isEmpty) return;

    final glasses = devices.where((d) => d.isGlasses).toList();
    if (glasses.isEmpty) return;

    final best = glasses.reduce((a, b) => a.rssi > b.rssi ? a : b);
    if (best.rssi >= SmartGlassesScanner.closeRssiThreshold) {
      _triggerAlarmLocal(
        'Smart glasses detected nearby: ${best.name} (${best.rssi} dBm)',
      );
    }
  }

  // --- Initialization Helper ---
  Future<void> _initializePermissionsAndStatus() async {
    await [
      Permission.camera,
      Permission.notification,
    ].request();

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

    // Using ResolutionPreset.high for crystal clear preview
    _cameraController = CameraController(
      _cameras[_selectedCameraIndex],
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await _cameraController!.initialize();
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
    }
  }

  Future<void> _disposeCamera({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isCameraInitialized = false;
      });
    }
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }
  }

  Future<void> _toggleCameraLens() async {
    if (_cameras.length < 2) return;
    int nextIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _disposeCamera();
    setState(() {
      _selectedCameraIndex = nextIndex;
    });
    await _initCamera();
    _logEvent('Switched camera lens');
  }

  // --- Risk Engine Calculation ---
  void _calculateRisk() {
    double score = 0;

    // 1. Distance Flow: Closer is higher risk (max 25 pts)
    if (_simDistance <= 2.0) {
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
    if (_isLiveMode) {
      // Use real BLE signal strength: stronger = higher score.
      final best = _detectedGlasses.isEmpty
          ? null
          : _detectedGlasses.reduce((a, b) => a.rssi > b.rssi ? a : b);
      if (best != null) {
        score += ((best.rssi + 90) / 50 * 15).clamp(2.0, 15.0);
      }
    } else if (_simBluetoothEvidence) {
      score += 15;
    }

    // 6. Movement status (max 10 pts)
    if (_simMovementLow) {
      score += 10;
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
    await _disposeCamera();
    await _logEvent('Glance Companion Disarmed');
  }

  // Simulated Alert Action
  void _triggerSimulatedAlert() {
    _triggerAlarmLocal("Simulated Alert Triggered");
  }

  // --- UI Widget Helpers ---

  // Refined organic card container with soft drop shadows and thin warm borders
  Widget _buildPinterestCard({
    required Widget child,
    Color? color,
    EdgeInsetsGeometry? padding,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: const Color(0xFFEFEBE4), // Soft warm card outline
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5D534A).withOpacity(0.045), // Soft elegant drop shadow
            blurRadius: 24,
            offset: const Offset(0, 10),
          )
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: padding ?? const EdgeInsets.all(22.0),
          child: child,
        ),
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
              valueDisplay,
              style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFD65345)),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFFD65345),
            inactiveTrackColor: const Color(0xFFECE5DD),
            thumbColor: const Color(0xFFD65345),
            overlayColor: const Color(0xFFD65345).withOpacity(0.12),
            valueIndicatorColor: const Color(0xFFD65345),
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
          // Background Gradient (Warm Ivory to Champagne Cream)
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFFFAF7F2),
                  Color(0xFFF4ECE4),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),

          // Main Scrollable Pinterest Board
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Chic Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Glance",
                            style: Theme.of(context).textTheme.displayMedium,
                          ),
                          const Text(
                            "Your Personal Safety Companion",
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF7E726D),
                            ),
                          ),
                        ],
                      ),
                      // Rounded premium badge
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isAlarmActive 
                              ? const Color(0xFFFDF0ED) 
                              : const Color(0xFFE8F1EC),
                          border: Border.all(
                            color: _isAlarmActive 
                                ? const Color(0xFFF5D6D1) 
                                : const Color(0xFFD3E5DC),
                          ),
                        ),
                        child: Icon(
                          _isAlarmActive 
                              ? Icons.security_update_warning_rounded 
                              : Icons.gpp_good_outlined,
                          color: _isAlarmActive 
                              ? const Color(0xFFD65345) 
                              : const Color(0xFF6E8E7D),
                          size: 26,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),

                  // 1. PRIVACY RADAR Mode Selector Card (Enhanced iOS-style bracketless segmented control)
                  _buildPinterestCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "PRIVACY RADAR",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5,
                                color: Color(0xFF332D2B),
                              ),
                            ),
                            Icon(Icons.radar_rounded, color: Color(0xFF7E726D), size: 18),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Container(
                          height: 54,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEDE7DD), // Soft clay/grey selector background
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              // Segment: LIVE MODE
                              Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _isLiveMode = true;
                                    });
                                    _initCamera();
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: _isLiveMode ? Colors.white : Colors.transparent,
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: _isLiveMode
                                          ? [
                                              BoxShadow(
                                                color: const Color(0xFF5D534A).withOpacity(0.08),
                                                blurRadius: 8,
                                                offset: const Offset(0, 2),
                                              )
                                            ]
                                          : [],
                                    ),
                                    child: Text(
                                      "LIVE MODE",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                        color: _isLiveMode ? const Color(0xFF332D2B) : const Color(0xFF8C7E77),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Segment: SIMULATION MODE
                              Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _isLiveMode = false;
                                    });
                                    _disarmAlarm();
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: !_isLiveMode ? Colors.white : Colors.transparent,
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: !_isLiveMode
                                          ? [
                                              BoxShadow(
                                                color: const Color(0xFF5D534A).withOpacity(0.08),
                                                blurRadius: 8,
                                                offset: const Offset(0, 2),
                                              )
                                            ]
                                          : [],
                                    ),
                                    child: Text(
                                      "SIMULATION MODE",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                        color: !_isLiveMode ? const Color(0xFF332D2B) : const Color(0xFF8C7E77),
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

                  // 1.5. SMART GLASSES BLE DETECTOR CARD
                  const SmartGlassesDetectorCard(),

                  // 2. LIVE CAMERA CARD (Fitted aspect ratio cover crop)
                  if (_isLiveMode || _isAlarmActive)
                    _buildPinterestCard(
                      padding: EdgeInsets.zero,
                      child: Container(
                        height: 310,
                        color: Colors.black,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_isCameraInitialized && _cameraController != null)
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  return SizedBox(
                                    width: constraints.maxWidth,
                                    height: constraints.maxHeight,
                                    child: FittedBox(
                                      fit: BoxFit.cover,
                                      child: SizedBox(
                                        width: _cameraController!.value.previewSize!.height,
                                        height: _cameraController!.value.previewSize!.width,
                                        child: CameraPreview(_cameraController!),
                                      ),
                                    ),
                                  );
                                },
                              )
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
                                  color: const Color(0xFFC94A38).withOpacity(0.9),
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
                            if (_isCameraInitialized && _cameraController != null && _cameras.length > 1)
                              Positioned(
                                bottom: 14,
                                right: 14,
                                child: GestureDetector(
                                  onTap: _toggleCameraLens,
                                  child: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.5),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white24),
                                    ),
                                    child: const Icon(
                                      Icons.flip_camera_ios_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                  // 3. SIMULATION MODE SETTINGS (Beautified controls & enhanced calculate button)
                  if (!_isLiveMode) ...[
                    Text(
                      "Simulation Mode",
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Give yourselves sliders/buttons:",
                      style: TextStyle(fontSize: 13, color: Color(0xFF7E726D)),
                    ),
                    const SizedBox(height: 12),
                    _buildPinterestCard(
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
                          // Smart Glasses Slider
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
                          // Orientation Alignment Slider
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
                                    border: Border.all(color: const Color(0xFFEFEBE4)),
                                  ),
                                  child: Text(
                                    _simBluetoothEvidence ? "YES" : "NO",
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFD65345),
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
                                    border: Border.all(color: const Color(0xFFEFEBE4)),
                                  ),
                                  child: Text(
                                    _simMovementLow ? "LOW" : "HIGH",
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFD65345),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          // Enhanced Terracotta Pill CALCULATE Button (No brackets)
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(30),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFFD65345).withOpacity(0.22),
                                    blurRadius: 16,
                                    offset: const Offset(0, 6),
                                  )
                                ],
                              ),
                              child: ElevatedButton(
                                onPressed: _calculateRisk,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFD65345),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(30),
                                  ),
                                  elevation: 0,
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.analytics_rounded, size: 20),
                                    SizedBox(width: 8),
                                    Text(
                                      "CALCULATE",
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.0,
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
                    
                    // Risk Engine Output Card (Then:)
                    const Text(
                      "Then:",
                      style: TextStyle(fontSize: 13, color: Color(0xFF7E726D)),
                    ),
                    const SizedBox(height: 8),
                    _buildPinterestCard(
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
                                  ? const Color(0xFFD65345) 
                                  : (_riskLevel == "MEDIUM RISK" ? Colors.amber[800] : const Color(0xFF6E8E7D)),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Alert Button (No brackets)
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: OutlinedButton(
                              onPressed: _triggerSimulatedAlert,
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Color(0xFFD65345), width: 1.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.vibration, color: Color(0xFFD65345), size: 18),
                                  SizedBox(width: 8),
                                  Text(
                                    "ALERT",
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFD65345),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // 4. Security Incident Logs
                  _buildPinterestCard(
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
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF332D2B),
                              ),
                            ),
                            if (_alertsLog.isNotEmpty)
                              TextButton(
                                onPressed: _clearLogs,
                                child: const Text(
                                  "Clear",
                                  style: TextStyle(color: Color(0xFF7E726D), fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                        const Divider(color: Color(0xFFFAF2EC)),
                        if (_alertsLog.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20.0),
                            child: Center(
                              child: Text(
                                "No incidents logged. System safe.",
                                style: TextStyle(color: Color(0xFF7E726D), fontSize: 12),
                              ),
                            ),
                          )
                        else
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _alertsLog.length > 5 ? 5 : _alertsLog.length,
                            separatorBuilder: (_, __) => const Divider(color: Color(0xFFFAF2EC)),
                            itemBuilder: (context, index) {
                              final log = _alertsLog[index];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4.0),
                                child: Text(
                                  log,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: Color(0xFF7E726D),
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                  
                  const Center(
                    child: Text(
                      "Glance Safety Shield v1.6.0 • BLE Smart Glasses Detection",
                      style: TextStyle(color: Color(0xFF7E726D), fontSize: 10),
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
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFFFDF0ED),
                                border: Border.all(color: const Color(0xFFF5D6D1)),
                              ),
                              child: const Icon(
                                Icons.report_problem_rounded,
                                size: 50,
                                color: Color(0xFFD65345),
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
                                color: Color(0xFFD65345),
                                letterSpacing: 1,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              "A high-threat signature has triggered on-device security measures. The camera sensor is open and vibration feedback is running.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF7E726D),
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),

                        // Alarm Source Details
                        if (!_isLiveMode)
                          _buildPinterestCard(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                const Icon(Icons.security_sharp, color: Color(0xFFD65345), size: 24),
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
                                          color: Color(0xFFD65345),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        "Calculated risk level was $_riskScore% (HIGH)",
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF7E726D),
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
                              height: 56,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(30),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF6E8E7D).withOpacity(0.20),
                                      blurRadius: 16,
                                      offset: const Offset(0, 6),
                                    )
                                  ],
                                ),
                                child: ElevatedButton(
                                  onPressed: _disarmAlarm,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF6E8E7D),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: const Text(
                                    "DISARM COMPANION",
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              "TAP TO RESET SECURITY SHIELD",
                              style: TextStyle(
                                color: Color(0xFF7E726D),
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
