import 'package:flutter/material.dart';

import '../services/smart_glasses_scanner.dart';

/// Pinterest-style card that live-shows nearby smart glasses detected over BLE,
/// including signal strength (RSSI) and estimated distance.
class SmartGlassesDetectorCard extends StatefulWidget {
  const SmartGlassesDetectorCard({super.key});

  @override
  State<SmartGlassesDetectorCard> createState() => _SmartGlassesDetectorCardState();
}

class _SmartGlassesDetectorCardState extends State<SmartGlassesDetectorCard> {
  static const _ink = Color(0xFF332D2B);
  static const _muted = Color(0xFF7E726D);
  static const _terracotta = Color(0xFFD65345);
  static const _sage = Color(0xFF6E8E7D);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ScannerStatus>(
      stream: SmartGlassesScanner.instance.statusStream,
      initialData: SmartGlassesScanner.instance.status,
      builder: (context, statusSnap) {
        final status = statusSnap.data ?? SmartGlassesScanner.instance.status;
        return StreamBuilder<List<SmartGlassDevice>>(
          stream: SmartGlassesScanner.instance.devicesStream,
          initialData: SmartGlassesScanner.instance.currentDevices,
          builder: (context, devSnap) {
            final devices = devSnap.data ?? const <SmartGlassDevice>[];
            return _buildCard(status, devices);
          },
        );
      },
    );
  }

  Widget _buildCard(ScannerStatus status, List<SmartGlassDevice> devices) {
    final scanning = status == ScannerStatus.scanning || status == ScannerStatus.starting;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFEFEBE4), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5D534A).withValues(alpha: 0.045),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.all(22.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "SMART GLASSES DETECTOR",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: _ink,
                    ),
                  ),
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scanning ? const Color(0xFFE8F1EC) : const Color(0xFFFAF7F2),
                      border: Border.all(
                        color: scanning ? const Color(0xFFD3E5DC) : const Color(0xFFEFEBE4),
                      ),
                    ),
                    child: const Icon(Icons.visibility_rounded, color: _sage, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _statusPill(status),
                  const Spacer(),
                  if (scanning && devices.isNotEmpty) ...[
                    Text(
                      "${devices.length} found",
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _terracotta,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  const Text(
                    "SHOW ALL",
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      color: _muted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        SmartGlassesScanner.instance.setShowAll(!SmartGlassesScanner.instance.showAll);
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 36,
                      height: 20,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: SmartGlassesScanner.instance.showAll ? _terracotta : const Color(0xFFEDE7DD),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: AnimatedAlign(
                        duration: const Duration(milliseconds: 200),
                        alignment: SmartGlassesScanner.instance.showAll ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildContent(status, devices),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    if (SmartGlassesScanner.instance.isRunning) {
                      await SmartGlassesScanner.instance.stop();
                    } else {
                      await SmartGlassesScanner.instance.start(userInitiated: true);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: scanning ? _sage : _terracotta,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    elevation: 0,
                  ),
                  icon: Icon(
                    scanning ? Icons.stop_circle_outlined : Icons.radar_rounded,
                    size: 18,
                  ),
                  label: Text(
                    scanning ? "STOP SCANNING" : "START SCANNING",
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusPill(ScannerStatus status) {
    final (label, color, bg, border) = switch (status) {
      ScannerStatus.scanning => ('SCANNING', _sage, const Color(0xFFE8F1EC), const Color(0xFFD3E5DC)),
      ScannerStatus.starting => ('STARTING...', _sage, const Color(0xFFE8F1EC), const Color(0xFFD3E5DC)),
      ScannerStatus.stopped => ('PAUSED', _muted, const Color(0xFFFAF7F2), const Color(0xFFEFEBE4)),
      ScannerStatus.idle => ('IDLE', _muted, const Color(0xFFFAF7F2), const Color(0xFFEFEBE4)),
      ScannerStatus.permissionDenied => ('PERMISSION REQUIRED', _terracotta, const Color(0xFFFDF0ED), const Color(0xFFF5D6D1)),
      ScannerStatus.bluetoothOff => ('BLUETOOTH OFF', _terracotta, const Color(0xFFFDF0ED), const Color(0xFFF5D6D1)),
      ScannerStatus.unsupported => ('NOT SUPPORTED', _terracotta, const Color(0xFFFDF0ED), const Color(0xFFF5D6D1)),
      ScannerStatus.error => ('SCAN ERROR', _terracotta, const Color(0xFFFDF0ED), const Color(0xFFF5D6D1)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
          color: color,
        ),
      ),
    );
  }

  Widget _buildContent(ScannerStatus status, List<SmartGlassDevice> devices) {
    switch (status) {
      case ScannerStatus.unsupported:
        return _message("Bluetooth LE is not supported on this device.");
      case ScannerStatus.permissionDenied:
        final err = SmartGlassesScanner.instance.lastError;
        return _message(
          err != null
              ? "Bluetooth permission was denied ($err). Grant Bluetooth access in Settings, then tap START SCANNING."
              : "Bluetooth permission was denied. Grant Bluetooth access in Settings, then tap START SCANNING.",
        );
      case ScannerStatus.bluetoothOff:
        return _message("Bluetooth is turned off. Enable Bluetooth, then tap START SCANNING.");
      case ScannerStatus.error:
        return _message(
          "Scan error: ${SmartGlassesScanner.instance.lastError ?? 'unknown'}",
        );
      case ScannerStatus.starting:
        return const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: _sage),
            ),
            SizedBox(width: 12),
            Text(
              "Preparing Bluetooth scanner...",
              style: TextStyle(fontSize: 13, color: _muted),
            ),
          ],
        );
      case ScannerStatus.scanning:
        if (devices.isEmpty) {
          return const _Pulse(
            child: Text(
              "Scanning for smart glasses nearby...",
              style: TextStyle(fontSize: 13, color: _muted),
            ),
          );
        }
        return Column(
          children: [
            for (final device in devices) _deviceRow(device),
          ],
        );
      case ScannerStatus.stopped:
      case ScannerStatus.idle:
        return _message("Scanning is paused. Tap START SCANNING to detect smart glasses nearby.");
    }
  }

  Widget _message(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(Icons.info_outline_rounded, color: _muted, size: 16),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: _muted, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _deviceRow(SmartGlassDevice device) {
    final percent = ((device.rssi + 100) / 50).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFFAF7F2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFEFEBE4)),
            ),
            child: Icon(
              device.isGlasses ? Icons.visibility_rounded : Icons.bluetooth_rounded,
              color: device.isGlasses ? _terracotta : _muted,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  "${device.rssi} dBm · ${device.estimatedDistanceMeters.toStringAsFixed(1)} m away",
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                device.signalLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: device.rssi >= -60 ? _sage : _terracotta,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 48,
                height: 6,
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF7F2),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: percent,
                  child: Container(
                    decoration: BoxDecoration(
                      color: device.rssi >= -60 ? _sage : _terracotta,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Softly fades a child in/out to signal an ongoing action.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(_controller),
      child: widget.child,
    );
  }
}