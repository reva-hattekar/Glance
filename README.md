# Glance — Smart Glasses Detection & Safety

> **See Smart. Stay Safe.**

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![TensorFlow Lite](https://img.shields.io/badge/TFLite-MobileNetV2-FF6F00?logo=tensorflow)](https://www.tensorflow.org/lite)
[![ESP32](https://img.shields.io/badge/Hardware-ESP32-E7352C?logo=espressif)](https://www.espressif.com)
[![Sensors](https://img.shields.io/badge/ToF-VL53L4CD-4B0082)](https://www.st.com)
[![BLE](https://img.shields.io/badge/Protocol-BLE_GATT-00758F?logo=bluetooth)](https://www.bluetooth.com)

**Glance** is a multi-modal personal safety and situational awareness system designed to detect potential smart-glasses-based privacy and safety risks. By combining on-device computer vision, physical Bluetooth Low Energy (BLE) scanning, hardware laser distance sensing (Time-of-Flight), and a context-aware risk engine, Glance evaluates encounters holistically rather than relying on a single fallible sensor or classifier.

---

## 1. Problem Statement

With the rapid adoption of wearable smart glasses and covert recording devices, identifying whether someone is actively recording or observing you in close proximity has become challenging:

* **Visual Camouflage**: Modern smart glasses resemble conventional eyewear, making casual visual detection difficult and error-prone.
* **Camera Classifier Limitations**: Vision-only AI models can generate false positives (e.g., misclassifying stylish regular frames) or false negatives (due to lighting, distance, or viewing angles).
* **Missing Physical Evidence**: Visual appearance alone does not confirm whether an active wireless device is present nearby.
* **Lack of Context**: Fleeting or distant glances do not pose the same risk as close-proximity, sustained, direct observations.

Glance solves this by implementing **multi-modal sensor fusion**, validating visual indicators against physical BLE broadcasts and accurate millimeter laser distance measurements.

---

## 2. Solution Overview

Glance links an Android smartphone application with a wearable ESP32 sensor node to form a unified detection and alerting pipeline:

```
Camera Stream
  │
  ├──► Google ML Kit ──────► Face & Person Detection
  │                          Orientation (Euler Y/Z)
  │                          Interaction Duration
  │
  └──► Custom TFLite ──────► Smart-Glasses Visual Probability
       (MobileNetV2)

ESP32 Node
  │
  └──► VL53L4CD Sensor ────► Continuous Laser Distance (ToF)
       (I2C: SDA=21, SCL=22)   (BLE GATT Notifications)
                               │
                               ▼
Smartphone BLE ────────────► BLE Smart Device / Beacon Evidence
Coordinator                  (RSSI Signal Tracking)

                             │
                             ▼
                    ┌─────────────────┐
                    │   RISK ENGINE   │
                    └────────┬────────┘
                             │
            ┌────────────────┼────────────────┐
            ▼                ▼                ▼
        LOW RISK        MEDIUM RISK       HIGH RISK (≥ 75%)
        (< 40%)          (40 - 74%)           │
                                              ▼
                                    Phone Audio & Vibration
                                              +
                                    ESP32 Vibration Motor
                                    (Bidirectional Sync)
```

> **Distance Priority**: The physical VL53L4CD Time-of-Flight sensor is the **primary** distance source. If the ESP32 is offline or out of range, Glance automatically switches to camera face-ratio distance estimation as a seamless **fallback**.

---

## 3. System Architecture

```mermaid
graph TB
    subgraph "Smartphone (Glance App)"
        UI["Flutter UI Layer (Dashboard & Live Overlay)"]
        CV["Camera & ML Kit Pipeline"]
        TFLite["TFLite Classifier (MobileNetV2 224x224)"]
        BLE_Coord["Glance BLE Coordinator"]
        RiskEngine["Context-Aware Multi-Factor Risk Engine"]
        AlarmMgr["Alarm & Audio/Haptic Manager"]
    end

    subgraph "ESP32 Wearable Node"
        GATT["BLE GATT Server (Glance-ESP32)"]
        TOF["VL53L4CD Laser ToF Sensor (I2C)"]
        Motor["2N2222 Driver & Vibration Motor (GPIO 4)"]
    end

    CV -->|"Face Crop & Bounding Box"| TFLite
    TFLite -->|"Visual Prob (0-100%)"| RiskEngine
    CV -->|"Orientation & Duration"| RiskEngine
    CV -->|"Camera Fallback Distance"| RiskEngine

    BLE_Coord -->|"Smart Glasses BLE Beacons"| RiskEngine
    BLE_Coord <==|"GATT Connection / Reconnect"|==> GATT

    TOF -->|"Distance Packets (10Hz)"| GATT
    GATT -->|"Primary Distance Stream"| BLE_Coord
    BLE_Coord -->|"Physical Distance (m)"| RiskEngine

    RiskEngine -->|"Risk Score (0-100%)"| UI
    RiskEngine -->|"High Risk Trigger (≥ 75%)"| AlarmMgr

    AlarmMgr -->|"Local Audio & Vibration"| UI
    AlarmMgr -->|"Write ALARM_ON / ALARM_OFF"| BLE_Coord
    BLE_Coord -->|"Command Char (1c95d5e3...)"| GATT
    GATT -->|"Pulse Pattern (300ms ON / 300ms OFF)"| Motor
```

---

## 4. Key Features

* **Real-Time Camera Monitoring**: Continuous 30 FPS processing using Google ML Kit and camera streams.
* **On-Device Vision AI**: Custom MobileNetV2 classifier running locally via TensorFlow Lite without cloud dependencies.
* **Hardware Time-of-Flight Ranging**: Millimeter-precision distance sensing up to 4.0 meters via STM32 VL53L4CD.
* **Seamless Sensor Fallback**: Automatic failover to camera distance estimation when the physical sensor is disconnected.
* **Bluetooth Smart Glasses Detection**: Background BLE scanning tracking signal strength (RSSI) from wearable device broadcasts.
* **Contextual Risk Engine**: Multi-factor scoring incorporating distance, gaze orientation, interaction duration, visual probability, facial movement, and RF proximity.
* **Bidirectional Alarm Synchronization**: Synchronous smartphone siren/vibration and ESP32 haptic vibration motor feedback.
* **Simulation & Testing Mode**: Isolated parameter sandbox for testing risk thresholds with explicit calculation gating.
* **Modern Adaptive Launcher Branding**: Custom dark-navy and neon-cyan optical aperture iconography across all Android densities.
* **Zero-Cloud Privacy**: 100% on-device processing for video frames, sensor streams, and telemetry.

---

## 5. AI / Machine Learning Model

The visual detection pipeline uses a lightweight convolutional neural network optimized for low-latency mobile inference.

* **Format**: TensorFlow Lite (`assets/smart_glasses_v2.tflite`)
* **Model Size**: **2.58 MB**
* **Input Dimensions**: `224 × 224 × 3` (RGB, Normalized: $\frac{\text{pixel}}{127.5} - 1.0$)
* **Base Architecture**: MobileNetV2 (ImageNet pretrained feature extractor)
* **Classification Head**: `GlobalAveragePooling2D` $\rightarrow$ `Dropout(0.35)` $\rightarrow$ `Dense(64, ReLU)` $\rightarrow$ `Dropout(0.25)` $\rightarrow$ `Dense(1, Sigmoid)`
* **Visual Decision Threshold**: **0.30** ($30\%$)

$$\begin{aligned}
\text{Model Probability} < 0.30 &\longrightarrow \textbf{CLEAR / NOT DETECTED} \\
\text{Model Probability} \ge 0.30 &\longrightarrow \textbf{GLASSES DETECTED}
\end{aligned}$$

> **Important Distinction**: The vision classification threshold ($0.30$) is **not** the alarm trigger threshold. Visual detection contributes at most $20$ points to the risk engine. An emergency alarm requires a cumulative risk score of **$\ge 75\%$**.

---

## 6. Model Evaluation

Evaluated directly on the project's held-out test partition ($N = 61$ images) using the deployed `smart_glasses_v2.tflite` model:

### Dataset Composition
* **Total Valid Samples**: 403 images
  * **Positive Class (Smart Glasses)**: 153 images
  * **Negative Class (Regular / No Glasses)**: 250 images
    * *With Regular Eyeglasses*: 150 images
    * *Without Glasses*: 100 images
* **Split Strategy**: Stratified 70% Train (281), 15% Validation (61), 15% Held-Out Test (61)

### Held-Out Test Performance ($\text{Threshold} = 0.30$)

| Metric | Measured Result |
| :--- | :---: |
| **Accuracy** | **78.69%** |
| **Precision** | **66.67%** |
| **Recall** | **86.96%** |
| **F1 Score** | **75.47%** |
| **ROC-AUC (Threshold Independent)** | **86.96%** |

### Confusion Matrix ($N = 61$)

| | Predicted Negative (Clear) | Predicted Positive (Detected) |
| :--- | :---: | :---: |
| **Actual Negative (Regular / None)** | **$\text{TN} = 28$** | $\text{FP} = 10$ |
| **Actual Positive (Smart Glasses)** | $\text{FN} = 3$ | **$\text{TP} = 20$** |

* **High Safety Recall**: **20 out of 23** smart-glasses test cases correctly detected (missing only 3 edge cases).
* **Engineering Rationale**: In personal safety applications, minimizing False Negatives ($\text{FN}$) is prioritized. False visual predictions are mitigated downstream by requiring multi-modal corroboration.

---

## 7. Multi-Modal Risk Engine

Glance calculates situational risk dynamically ($0 - 100\%$) using 6 independent indicators:

| Factor | Weight | Evaluation Criteria |
| :--- | :---: | :--- |
| **1. Proximity / Distance** | **25 pts** | $\le 2.0\text{ m}$ ($10\text{ pts}$ base $+ 15 \times \frac{2.0 - \text{dist}}{1.5}$). Primary: ESP32 ToF, Fallback: Camera. |
| **2. Interaction Duration** | **15 pts** | Sustained visual engagement $\ge 5.0\text{ seconds}$. |
| **3. Face / Head Orientation** | **15 pts** | Direct gaze alignment with camera ($\text{orientation} \times 0.15$). |
| **4. Visual Glasses Classifier** | **20 pts** | Continuous MobileNetV2 output ($\text{probability} \times 0.20$). |
| **5. Relative Movement** | **10 pts** | Low relative facial translation ($< 8.0\text{ px}$) indicating fixed tracking. |
| **6. RF / BLE Device Signal** | **15 pts** | Nearby smart glasses signal strength ($(\text{RSSI} + 90) / 50 \times 15$, clamped $2.0 - 15.0\text{ pts}$). |

### Risk Tiers
* **LOW RISK ($0 - 39\%$)**: Normal ambient activity.
* **MEDIUM RISK ($40 - 74\%$)**: Elevated proximity or visual similarity without full corroboration.
* **HIGH RISK ($\ge 75\%$)**: Simultaneous close proximity, directed orientation, sustained duration, and RF/visual detection $\longrightarrow$ **Triggers Emergency Alarm**.

---

## 8. Hardware & Wiring

The Glance hardware node uses an ESP32 microcontroller with a Time-of-Flight laser ranging sensor and a transistor-driven vibration motor.

```
       ESP32 DevKit
   ┌──────────────────┐
   │                  │
   │          GPIO 21 ├──────────────► VL53L4CD SDA
   │          GPIO 22 ├──────────────► VL53L4CD SCL
   │             3.3V ├──────────────► VL53L4CD VIN
   │              GND ├──────┬───────► VL53L4CD GND
   │                  │      │
   │           GPIO 4 ├───[ 1kΩ ]───► 2N2222 Base
   │                  │      │
   └──────────────────┘      │
                             │
     VCC (3.3V/5V) ──────────┼────────► Motor (+)
                             │             │
                             │        [ 1N4007 Diode ] (Flyback)
                             │             │
                             ▼             ▼
                      2N2222 Emitter  Motor (-) ──► 2N2222 Collector
                             │
                            GND (Shared)
```

### Components List
* **Microcontroller**: ESP32 DevKit (ESP32-WROOM-32)
* **Ranging Sensor**: STMicroelectronics VL53L4CD Time-of-Flight Module
* **Haptic Actuator**: Coreless Micro Vibration Motor (3V)
* **Driver Transistor**: 2N2222 NPN BJT
* **Flyback Protection**: 1N4001 / 1N4007 Diode (parallel across motor terminals)
* **Base Resistor**: $1\text{ k}\Omega$ (ESP32 GPIO 4 $\rightarrow$ 2N2222 Base)
* **Power**: USB 5V or 3.7V LiPo with 3.3V LDO regulator

---

## 9. ESP32 Firmware & BLE Protocol

The firmware creates a BLE GATT Server advertising as **`Glance-ESP32`**.

### GATT UUID Configuration

| Component | UUID | Properties | Description |
| :--- | :--- | :--- | :--- |
| **Primary Service** | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` | — | Glance Custom Service |
| **Distance Characteristic** | `beb5483e-36e1-4688-b7f5-ea07361b26a8` | Read, Notify | Streams 3-byte distance packets at ~10 Hz |
| **Command Characteristic** | `1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e` | Write, WriteNR | Receives `ALARM_ON`, `ALARM_OFF`, `MOTOR_TEST` |

### Packet Specifications
* **Distance Packet (ESP32 $\rightarrow$ Phone)**:
  * `Byte 0`: Status (`0x00` = Valid, `0x01` = Invalid/Out of range)
  * `Byte 1`: Distance MSB ($\text{mm} \gg 8$)
  * `Byte 2`: Distance LSB ($\text{mm} \ \& \ \text{0xFF}$)
* **Command Strings (Phone $\rightarrow$ ESP32)**:
  * `ALARM_ON`: Starts non-blocking 300 ms ON / 300 ms OFF repeating vibration pulse pattern.
  * `ALARM_OFF`: Immediately clears GPIO 4 to LOW and disarms motor.
  * `MOTOR_TEST`: Pulses motor for 2.0 seconds for diagnostic verification.

---

## 10. Simulation Mode

Glance includes an interactive **Simulation Sandbox** allowing users and evaluators to test risk engine behavior without physical hardware triggers:

* **Interactive Controls**: Distance slider ($0.5 - 5.0\text{ m}$), Smart-Glasses visual slider ($0 - 100\%$), Interaction duration ($0 - 30\text{ s}$), Orientation ($0 - 100\%$), Bluetooth toggle (YES/NO), Movement toggle (LOW/HIGH).
* **Isolated Trigger Gating**: Adjusting inputs updates the simulated parameters **without** computing risk or firing alarms.
* **Explicit Execution**: Risk calculation and alarm conditions are evaluated **only** when the user taps **`CALCULATE`**.

---

## 11. Project Structure

```
Glance/
├── android/                        # Android platform project & manifests
│   └── app/src/main/
│       ├── AndroidManifest.xml     # Permissions, foreground services, Glance label
│       ├── kotlin/.../             # Native camera monitor & background service
│       └── res/                    # Adaptive icons, mipmap densities, colors.xml
├── assets/                         # Runtime mobile assets
│   ├── glance_logo.png             # Master Glance brand logo
│   └── smart_glasses_v2.tflite     # Quantized on-device ML model (2.58 MB)
├── firmware/                       # Microcontroller source code
│   └── safesight_esp32/
│       └── safesight_esp32.ino     # ESP32 firmware (VL53L4CD, BLE GATT, motor)
├── lib/                            # Flutter / Dart application codebase
│   ├── services/
│   │   ├── esp32_sensor_service.dart    # BLE GATT subscriber & alarm manager
│   │   ├── glance_ble_coordinator.dart  # Central BLE permissions & continuous scan
│   │   └── smart_glasses_scanner.dart   # Wearable beacon RF signal processor
│   ├── widgets/
│   │   └── smart_glasses_detector_card.dart # Live RF device list & radar UI
│   └── main.dart                   # Core UI, camera pipeline, ML Kit, risk engine
├── model_training/                 # ML training scripts & artifacts
├── pubspec.yaml                    # Flutter dependencies & asset bindings
└── README.md                       # Project documentation
```

---

## 12. Technology Stack

| Domain | Technology / Library | Purpose |
| :--- | :--- | :--- |
| **Mobile Framework** | Flutter 3.x / Dart SDK ^3.12 | Cross-platform application UI and state management |
| **On-Device Vision** | TensorFlow Lite (`tflite_flutter`) | Low-latency smart-glasses binary classification |
| **Vision Utilities** | Google ML Kit (`google_mlkit_face_detection`) | Face boundary extraction, head Euler angles |
| **Bluetooth LE** | `flutter_blue_plus` | Continuous background BLE scanning & GATT client |
| **Camera Pipeline** | `camera` plugin | NV21 camera frame streaming & YUV image processing |
| **Embedded Hardware** | ESP32 (Tensilica Xtensa Dual-Core) | Hardware edge processing node |
| **ToF Driver** | `STM32duino VL53L4CD` (STMicroelectronics) | Laser Time-of-Flight ranging library |
| **Firmware SDK** | Arduino Core for ESP32 | ESP32 BLE GATT server & GPIO control |

---

## 13. Setup & Installation

### Prerequisites
* **Flutter SDK**: `^3.12.2` or later
* **Android Studio / Android SDK**: API Level 34+ (compileSdk 34, minSdk 21)
* **Arduino IDE**: `2.x+` with ESP32 board package installed
* **Physical Devices**:
  * Android smartphone with BLE support (Android 10+)
  * ESP32 Development Board + VL53L4CD sensor module

---

### Step 1: Clone Repository & Install Dependencies

```bash
git clone https://github.com/reva-hattekar/Glance.git
cd Glance
flutter pub get
```

---

### Step 2: Flash ESP32 Firmware

1. Connect the ESP32 to your computer via USB.
2. Open Arduino IDE and navigate to `firmware/safesight_esp32/safesight_esp32.ino`.
3. In **Library Manager**, install:
   * **`STM32duino VL53L4CD`** by *STMicroelectronics*
4. In **Tools > Board**, select **`ESP32 Dev Module`**.
5. Select the correct **COM Port**.
6. Wire the VL53L4CD sensor:
   * `VIN` $\rightarrow$ `3.3V`
   * `GND` $\rightarrow$ `GND`
   * `SDA` $\rightarrow$ `GPIO 21`
   * `SCL` $\rightarrow$ `GPIO 22`
7. Wire the vibration motor transistor circuit to **`GPIO 4`**.
8. Click **Upload**.
9. Open **Serial Monitor** (`115200 baud`) to verify sensor initialization:

```text
==========================================
         GLANCE ESP32 SENSOR NODE         
==========================================
[GLANCE ESP32] Starting...
[GLANCE MOTOR] Motor pin GPIO 4 configured (LOW)
[GLANCE ESP32] Scanning I2C bus (SDA=21, SCL=22)...
[I2C] Found device at address 0x29 (VL53L4CD default 7-bit address)
[GLANCE ESP32] VL53L4CD FOUND & Initialized successfully (status=0)
[GLANCE ESP32] Advertising as Glance-ESP32
```

---

### Step 3: Run the Flutter Application

```bash
# Verify static analysis
flutter analyze

# Launch on connected Android device
flutter run --release
```

---

## 14. Testing & Verification Checklist

- [x] **Static Analysis**: `flutter analyze` passes with 0 issues.
- [x] **Release Build**: `flutter build apk --release` completes successfully.
- [x] **BLE Auto-Connect**: App automatically discovers `Glance-ESP32` and subscribes to distance notifications.
- [x] **ToF Ranging**: Live laser distance appears in camera overlay as `Distance X.XX m • SENSOR`.
- [x] **Sensor Fallback**: Disconnecting ESP32 seamlessly switches distance label to `• CAMERA`.
- [x] **RF Beacon Scanner**: Nearby BLE wearables appear dynamically in the Smart Glasses Radar card.
- [x] **Gated Simulation**: Changing simulation sliders does not calculate risk until `CALCULATE` is tapped.
- [x] **Alarm Synchronization**: Triggering High Risk or SOS activates phone alarm and ESP32 motor simultaneously.
- [x] **Disarm Protocol**: Tapping `DISARM` cancels phone alarm and sends `ALARM_OFF` to halt ESP32 motor.

---

## 15. Known Limitations & Future Work

### Limitations
* **Dataset Scope**: Visual classification accuracy is tied to the diversity of the training set. Edge cases with tinted or oversized designer eyewear may require multi-modal corroboration.
* **Laser Sensor Field of View**: The VL53L4CD has an approximate $18^\circ$ field of view, requiring the user to orient the sensor generally toward the subject.
* **BLE Ambiguity**: Bluetooth signals confirm proximity to active electronics but cannot conclusively prove an active video stream is recording.

### Future Roadmap
* **Custom Miniaturized PCB**: Design an integrated pendant or clip-on wearable enclosure housing the ESP32, ToF sensor, and LiPo battery.
* **Expanded Dataset**: Incorporate diverse lighting conditions and emerging commercial smart-glasses form factors.
* **Acoustic & Ultrasound Sensing**: Explore ultra-wideband (UWB) or acoustic signature analysis for enhanced proximity verification.

---

## 16. Privacy & Ethical Use

Glance is developed strictly as an assistive situational awareness prototype. All video frames, sensor streams, and RF packets are processed **ephemerally on-device** in local memory. No camera feeds, facial identities, or tracking telemetry are stored or transmitted over external networks.

---

## 17. Acknowledgements

* **Google DeepMind & Flutter Team** for cross-platform app frameworks.
* **Google ML Kit** for on-device computer vision primitives.
* **STMicroelectronics** for the STM32 VL53L4CD Time-of-Flight ranging platform.
* **TensorFlow Lite Team** for on-device deep learning runtime support.

---

## 18. License

No license has currently been specified. All rights reserved by project maintainers.
