/**
 * Glance ESP32 Firmware - VL53L4CD Time-of-Flight, BLE & Motor Driver
 * 
 * Hardware:
 *   - Microcontroller: ESP32 (ESP32-WROOM-32 / DevKit)
 *   - Distance Sensor: SmartElex / ST VL53L4CD Time-of-Flight Sensor (I2C)
 *   - Vibration Motor: 2N2222 Transistor circuit on GPIO 4 with Flyback Diode
 * 
 * Wiring:
 *   - VL53L4CD VIN/VCC <--> 3.3V (or 5V if module has onboard regulator)
 *   - VL53L4CD GND     <--> ESP32 GND
 *   - VL53L4CD SDA     <--> ESP32 GPIO 21
 *   - VL53L4CD SCL     <--> ESP32 GPIO 22
 *   - Motor Base/Gate  <--> ESP32 GPIO 4 (via base resistor to 2N2222)
 *   - Transistor/Motor <--> Shared GND with ESP32
 * 
 * Required Arduino Library:
 *   - "STM32duino VL53L4CD" by STMicroelectronics (installed via Arduino Library Manager)
 */

#include <Arduino.h>
#include <Wire.h>
#include <vl53l4cd_class.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ============================================================================
// CONFIGURATION & HARDWARE PINS
// ============================================================================
#define MOTOR_DEBUG_TEST    false   // Set true to test physical motor for 1s on boot

#define PIN_SDA             21
#define PIN_SCL             22
#define PIN_MOTOR           4
#define PIN_XSHUT           -1

// ============================================================================
// BLE UUID DEFINITIONS
// ============================================================================
#define BLE_DEVICE_NAME             "Glance-ESP32"
#define SERVICE_UUID                "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_DISTANCE_UUID          "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CHAR_COMMAND_UUID           "1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e"

// ============================================================================
// GLOBAL OBJECTS & STATE
// ============================================================================
VL53L4CD sensor_vl53l4cd(&Wire, PIN_XSHUT);

BLEServer* pServer = nullptr;
BLECharacteristic* pDistanceChar = nullptr;
BLECharacteristic* pCommandChar = nullptr;

bool deviceConnected = false;
bool oldDeviceConnected = false;
bool sensorInitialized = false;

// Motor state & timing
bool alarmActive = false;
bool motorState = false;
unsigned long lastMotorToggleTime = 0;
const unsigned long MOTOR_PULSE_ON_MS  = 300;
const unsigned long MOTOR_PULSE_OFF_MS = 300;

// Dedicated test timer
bool testMotorActive = false;
unsigned long testMotorEndTime = 0;

// Sensor reading timing (~10 Hz)
unsigned long lastReadTime = 0;
const unsigned long READ_INTERVAL_MS = 100;

// ============================================================================
// MOTOR HELPER
// ============================================================================
void setMotor(bool on) {
    if (motorState == on) return;
    digitalWrite(PIN_MOTOR, on ? HIGH : LOW);
    motorState = on;
    Serial.printf("[GLANCE MOTOR] GPIO4 = %s\n", on ? "HIGH" : "LOW");
}

// ============================================================================
// I2C BUS SCANNER
// ============================================================================
bool scanI2CBus() {
    Serial.println("\n[GLANCE ESP32] Scanning I2C bus (SDA=21, SCL=22)...");
    byte count = 0;
    bool foundVl53 = false;

    for (byte address = 1; address < 127; address++) {
        Wire.beginTransmission(address);
        byte error = Wire.endTransmission();

        if (error == 0) {
            Serial.printf("[I2C] Found device at address 0x%02X", address);
            if (address == 0x29) {
                Serial.print(" (VL53L4CD default 7-bit address)");
                foundVl53 = true;
            }
            Serial.println();
            count++;
        }
    }

    if (count == 0) {
        Serial.println("[I2C] No I2C devices found! Check wiring: SDA=21, SCL=22, VIN=3.3V, GND=GND");
    } else {
        Serial.printf("[I2C] Scan complete: %d device(s) found.\n", count);
    }

    return foundVl53;
}

// ============================================================================
// BLE SERVER CALLBACKS
// ============================================================================
class GlanceServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
        deviceConnected = true;
        Serial.println("[BLE] Phone connected to Glance-ESP32");
    }

    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        Serial.println("[BLE] Phone disconnected. Advertising restarted...");
    }
};

// ============================================================================
// BLE COMMAND CALLBACKS (PHONE -> ESP32)
// ============================================================================
class GlanceCommandCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        String value = pCharacteristic->getValue().c_str();
        value.trim();
        
        if (value.length() > 0) {
            Serial.printf("[GLANCE COMMAND] Received: %s\n", value.c_str());
            
            if (value == "ALARM_ON") {
                alarmActive = true;
                testMotorActive = false;
                Serial.println("[GLANCE MOTOR] ALARM STARTED");
                setMotor(true);
                lastMotorToggleTime = millis();
            } else if (value == "ALARM_OFF") {
                alarmActive = false;
                testMotorActive = false;
                Serial.println("[GLANCE MOTOR] ALARM STOPPED");
                setMotor(false);
            } else if (value == "MOTOR_TEST") {
                Serial.println("[GLANCE MOTOR] TEST START");
                setMotor(true);
                testMotorActive = true;
                testMotorEndTime = millis() + 2000;
            }
        }
    }
};

// ============================================================================
// INITIALIZATION
// ============================================================================
void setup() {
    Serial.begin(115200);
    delay(1000); // Allow USB serial to stabilize

    Serial.println("\n==========================================");
    Serial.println("         GLANCE ESP32 SENSOR NODE         ");
    Serial.println("==========================================");
    Serial.println("[GLANCE ESP32] Starting...");

    // 1. Configure Motor GPIO
    pinMode(PIN_MOTOR, OUTPUT);
    digitalWrite(PIN_MOTOR, LOW);
    motorState = false;
    Serial.println("[GLANCE MOTOR] Motor pin GPIO 4 configured (LOW)");

    // Boot Diagnostic Motor Test (if enabled)
    #if MOTOR_DEBUG_TEST
        Serial.println("[GLANCE MOTOR] Running Boot Test (1 sec vibration)...");
        setMotor(true);
        delay(1000);
        setMotor(false);
        Serial.println("[GLANCE MOTOR] Boot Test Complete.");
    #endif

    // 2. Initialize I2C Bus
    Wire.begin(PIN_SDA, PIN_SCL);
    Wire.setClock(400000); // 400 kHz Fast-Mode

    // 3. Scan I2C
    scanI2CBus();

    // 4. Initialize VL53L4CD Sensor
    Serial.println("[GLANCE ESP32] Initializing VL53L4CD...");
    sensor_vl53l4cd.begin();

    uint8_t initStatus = sensor_vl53l4cd.InitSensor();
    if (initStatus != 0) {
        Serial.printf("[GLANCE ESP32] VL53L4CD InitSensor failed with error code: %d\n", initStatus);
        sensorInitialized = false;
    } else {
        sensorInitialized = true;
        Serial.println("[GLANCE ESP32] VL53L4CD FOUND & Initialized successfully (status=0)");

        // 50 ms budget, continuous mode
        sensor_vl53l4cd.VL53L4CD_SetRangeTiming(50, 0);
        sensor_vl53l4cd.VL53L4CD_StartRanging();
        Serial.println("[GLANCE ESP32] VL53L4CD Ranging started (50ms budget, ~10-20 Hz)");
    }

    // 5. Initialize BLE GATT Server
    Serial.println("[GLANCE ESP32] Starting BLE...");
    BLEDevice::init(BLE_DEVICE_NAME);
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new GlanceServerCallbacks());

    BLEService *pService = pServer->createService(SERVICE_UUID);

    // Distance Notification Characteristic (ESP32 -> Phone)
    pDistanceChar = pService->createCharacteristic(
        CHAR_DISTANCE_UUID,
        BLECharacteristic::PROPERTY_READ |
        BLECharacteristic::PROPERTY_NOTIFY
    );
    pDistanceChar->addDescriptor(new BLE2902());

    // Command Characteristic (Phone -> ESP32)
    pCommandChar = pService->createCharacteristic(
        CHAR_COMMAND_UUID,
        BLECharacteristic::PROPERTY_WRITE |
        BLECharacteristic::PROPERTY_WRITE_NR
    );
    pCommandChar->setCallbacks(new GlanceCommandCallbacks());

    pService->start();

    // Start BLE Advertising with 128-bit Service UUID
    BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);

    BLEAdvertisementData advData;
    advData.setName(BLE_DEVICE_NAME);
    advData.setCompleteServices(BLEUUID(SERVICE_UUID));
    pAdvertising->setAdvertisementData(advData);

    BLEAdvertisementData scanResponseData;
    scanResponseData.setCompleteServices(BLEUUID(SERVICE_UUID));
    pAdvertising->setScanResponseData(scanResponseData);

    pAdvertising->setScanResponse(true);
    pAdvertising->setMinPreferred(0x06);
    pAdvertising->setMinPreferred(0x12);
    BLEDevice::startAdvertising();

    Serial.println("[GLANCE ESP32] Advertising as Glance-ESP32");
    Serial.println("[GLANCE ESP32] Setup complete. Entering main loop...\n");
}

// ============================================================================
// MAIN LOOP
// ============================================================================
void loop() {
    unsigned long currentMillis = millis();

    // 1. Motor Testing Handler (2 seconds test pulse)
    if (testMotorActive) {
        if (currentMillis >= testMotorEndTime) {
            testMotorActive = false;
            setMotor(false);
            Serial.println("[GLANCE MOTOR] TEST END");
        }
    }

    // 2. Emergency Alarm Vibration Pattern (300 ms ON, 300 ms OFF)
    if (alarmActive && !testMotorActive) {
        if (motorState && (currentMillis - lastMotorToggleTime >= MOTOR_PULSE_ON_MS)) {
            setMotor(false);
            lastMotorToggleTime = currentMillis;
        } else if (!motorState && (currentMillis - lastMotorToggleTime >= MOTOR_PULSE_OFF_MS)) {
            setMotor(true);
            lastMotorToggleTime = currentMillis;
        }
    } else if (!alarmActive && !testMotorActive) {
        if (motorState) {
            setMotor(false);
        }
    }

    // 3. VL53L4CD Distance Measurement (~10 Hz)
    if (currentMillis - lastReadTime >= READ_INTERVAL_MS) {
        lastReadTime = currentMillis;

        if (sensorInitialized) {
            uint8_t isDataReady = 0;
            uint8_t checkStatus = sensor_vl53l4cd.VL53L4CD_CheckForDataReady(&isDataReady);

            if (checkStatus == 0 && isDataReady != 0) {
                // Clear HW interrupt to allow next measurement to start
                sensor_vl53l4cd.VL53L4CD_ClearInterrupt();

                VL53L4CD_Result_t results;
                sensor_vl53l4cd.VL53L4CD_GetResult(&results);

                uint16_t distanceMm = results.distance_mm;
                uint8_t rangeStatus = results.range_status;
                uint16_t signalRate = results.signal_per_spad_kcps;
                uint16_t ambientRate = results.ambient_per_spad_kcps;

                bool isValid = (rangeStatus == 0 || rangeStatus == 1) && (distanceMm >= 20 && distanceMm <= 4000);

                if (isValid) {
                    Serial.printf("[TOF] READY | distance=%4d mm (%.2f m) | status=%u | signal=%5u kcps/spad | ambient=%5u kcps\n",
                                  distanceMm,
                                  distanceMm / 1000.0,
                                  rangeStatus,
                                  signalRate,
                                  ambientRate);

                    Serial.printf("[DISTANCE] %d mm | %.2f m\n", distanceMm, distanceMm / 1000.0);

                    if (deviceConnected && pDistanceChar != nullptr) {
                        uint8_t packet[3];
                        packet[0] = 0x00; // Valid
                        packet[1] = (uint8_t)((distanceMm >> 8) & 0xFF);
                        packet[2] = (uint8_t)(distanceMm & 0xFF);

                        pDistanceChar->setValue(packet, 3);
                        pDistanceChar->notify();
                    }
                } else {
                    Serial.printf("[TOF] NO TARGET / INVALID | raw_distance=%4d mm | status=%u | signal=%5u kcps/spad | ambient=%5u kcps\n",
                                  distanceMm,
                                  rangeStatus,
                                  signalRate,
                                  ambientRate);

                    Serial.println("[DISTANCE] INVALID");

                    if (deviceConnected && pDistanceChar != nullptr) {
                        uint8_t packet[3] = {0x01, 0x00, 0x00}; // Invalid
                        pDistanceChar->setValue(packet, 3);
                        pDistanceChar->notify();
                    }
                }
            }
        }
    }

    // 4. Auto-Resume Advertising on Disconnect
    if (!deviceConnected && oldDeviceConnected) {
        delay(500);
        pServer->startAdvertising();
        Serial.println("[BLE] Restarted advertising after disconnect");
        oldDeviceConnected = deviceConnected;
    }

    if (deviceConnected && !oldDeviceConnected) {
        oldDeviceConnected = deviceConnected;
    }
}
