/*
================================================================================
ESP32 LoRa → Serial Bridge (Optimized Receiver)
Combined with reliable DIO0 pin checking and frequency offset
================================================================================
*/

// ================================================================================
// SECTION 1: INCLUDES
// ================================================================================
#include <Arduino.h>
#include <RadioLib.h>
#include <NimBLEDevice.h>

// ================================================================================
// SECTION 2: PIN DEFINITIONS (Match your transmitter exactly)
// ================================================================================
#define LORA_SCK   18      // GPIO18 - SPI Clock
#define LORA_MISO  19      // GPIO19 - SPI Master In Slave Out
#define LORA_MOSI  23      // GPIO23 - SPI Master Out Slave In
#define LORA_CS    5       // GPIO5  - Chip Select
#define LORA_RST   14      // GPIO14 - Reset
#define LORA_DIO0  4       // GPIO4  - Digital I/O 0 (interrupt pin)

// ================================================================================
// SECTION 3: LORA CONFIGURATION (MUST match transmitter exactly!)
// ================================================================================
#define LORA_FREQUENCY     433.0   // MHz (433/868/915 based on region)
#define LORA_BANDWIDTH     125.0   // kHz (MUST MATCH TX: 125.0 = 125 kHz)
#define LORA_SPREADING_FACTOR 10   // 7-12 (higher = longer range, slower)
#define LORA_CODING_RATE   5       // 5-8 (higher = better error correction)
#define LORA_SYNC_WORD     0x12    // Network ID (0x12 default, 0x34 private)
#define FREQ_OFFSET        +7000   // Hz - MUST MATCH TRANSMITTER EXACTLY!

// System parameters
#define SERIAL_BAUD_RATE   115200  // Serial monitor baud rate
#define LOOP_DELAY_MS      10      // Main loop delay (short for DIO0 checking)
#define MAX_RETRY_COUNT    3       // Max retries for failed transmissions
#define DATA_TIMEOUT_MS    30000   // 30 seconds - warn if no data received

// ================================================================================
// SECTION 4: GLOBAL OBJECTS AND VARIABLES
// ================================================================================
Module mod = Module(LORA_CS, LORA_DIO0, LORA_RST);
SX1278 radio = SX1278(&mod);

// BLE (NUS-like) globals
NimBLEServer* pBleServer = nullptr;
NimBLECharacteristic* pBleTx = nullptr; // notify -> app
NimBLECharacteristic* pBleRx = nullptr; // write  <- app
const char* BLE_DEVICE_NAME = "LoRaReceiver";

// ================================================================================
// SECTION 5: FUNCTION PROTOTYPES (MUST be before class definitions!)
// ================================================================================
bool initializeLoRa();
void checkIncomingLoRaData();

String convertToJSON(const String& loraData);
String escapeJsonString(const String& str);
void parseCSVData(const String& data, float values[], int& count);
void sendLoRaCommand(const String& command);
void printSystemStatus();

// BLE helper: notify if connected (with message chunking to prevent fragmentation issues)
void bleNotify(const String &msg) {
  // CRITICAL: Check ALL pointers are valid BEFORE use
  if (pBleServer == nullptr || pBleTx == nullptr) return;
  if (pBleServer->getConnectedCount() == 0) return;
  
  // CRITICAL: Send message in small chunks (< 20 bytes) with NEWLINE delimiters
  // This ensures Flutter receives complete, parseable messages instead of fragments
  const int CHUNK_SIZE = 18;  // 18 bytes per chunk (leave room for newline + safety margin)
  
  String fullMsg = msg + "\n";  // Add newline as message terminator
  
  for (int i = 0; i < fullMsg.length(); i += CHUNK_SIZE) {
    int len = CHUNK_SIZE;
    if (i + len > fullMsg.length()) {
      len = fullMsg.length() - i;
    }
    
    String chunk = fullMsg.substring(i, i + len);
    std::string s = chunk.c_str();
    pBleTx->setValue((uint8_t*)s.data(), s.length());
    pBleTx->notify();
    
    // Small delay between notifications to prevent buffer overflow on phone
    delay(10);
  }
}

// BLE Server callbacks for connection monitoring
// CRITICAL: NimBLE 2.x API - signatures MUST match exactly or callbacks are silently ignored!
class BleServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
    Serial.println("✓ BLE CLIENT CONNECTED");
    Serial.printf("  Client: %s\n", connInfo.getAddress().toString().c_str());
  }
  
  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
    Serial.printf("✗ BLE CLIENT DISCONNECTED (reason: %d)\n", reason);
    Serial.println("  Restarting BLE advertising...");
    
    // CRITICAL: Restart advertising after disconnect
    NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
    if (pAdv != nullptr) {
      pAdv->stop();
      delay(100);
      pAdv->start();
      Serial.println("  ✓ BLE advertising restarted");
    }
  }
};

class BleRxCallbacks: public NimBLECharacteristicCallbacks {
  // CRITICAL: NimBLE 2.x requires NimBLEConnInfo& parameter!
  // Old 1.x signature void onWrite(NimBLECharacteristic*) is SILENTLY IGNORED in 2.x!
  void onWrite(NimBLECharacteristic* pChr, NimBLEConnInfo& connInfo) override {
    Serial.println("\n========== BLE WRITE CALLBACK TRIGGERED ==========");
    Serial.printf("   From client: %s\n", connInfo.getAddress().toString().c_str());
    Serial.printf("   Characteristic UUID: %s\n", pChr->getUUID().toString().c_str());
    
    std::string s = pChr->getValue();
    Serial.printf("   Raw length: %d bytes\n", s.length());
    
    if (s.length() == 0) {
      Serial.println("   ❌ Empty payload - ignoring");
      bleNotify("REJECT:EMPTY:No data received");
      return;
    }
    
    String cmd = String(s.c_str());
    cmd.trim();
    Serial.printf("   Parsed command: [%s] (%d chars)\n", cmd.c_str(), cmd.length());
    
    Serial.println("📲 BLE RX: " + cmd);

    // Special command: GETSTATE (no colon required) — forward directly to transmitter
    if (cmd == "GETSTATE") {
      Serial.println("   📡 Forwarding GETSTATE query via LoRa...");
      sendLoRaCommand(cmd);
      bleNotify("FORWARDED:GETSTATE");
      Serial.println("=========================================\n");
      return;
    }
    
    // Validate command format: should be DEVICE:ACTION (e.g., HEATER:ON)
    int colonPos = cmd.indexOf(':');
    if (colonPos <= 0) {
      Serial.println("   ❌ Invalid command format (must be DEVICE:ACTION)");
      bleNotify("REJECT:FORMAT:Must be DEVICE:ACTION (e.g. HEATER:ON)");
      return;
    }
    
    String device = cmd.substring(0, colonPos);
    String action = cmd.substring(colonPos + 1);
    device.trim();
    action.trim();
    
    Serial.printf("   Device: %s | Action: %s\n", device.c_str(), action.c_str());
    
    // Forward the exact command to transmitter via LoRa
    Serial.println("   📡 Forwarding command via LoRa...");
    sendLoRaCommand(cmd);
    
    // Notify app that it was forwarded
    String ack = "FORWARDED:" + cmd;
    Serial.println("   📤 Sending BLE acknowledgment: " + ack);
    bleNotify(ack);
    
    Serial.println("=========================================\n");
  }
};

// Timing and state variables
unsigned long lastDataReceived = 0;     // Timestamp of last LoRa data
unsigned long lastStatusPrint = 0;      // Timestamp of last status print
unsigned int packetCounter = 0;         // Count of received packets
unsigned int failedPackets = 0;         // Count of failed receptions
bool loraInitialized = false;           // LoRa initialization status

// ================================================================================
// SECTION 6: SETUP FUNCTION
// ================================================================================
void setup() {
  // Initialize Serial
  Serial.begin(SERIAL_BAUD_RATE);
  delay(1000);
  
  Serial.printf("\n%lus: ========================================\n", millis() / 1000);
  Serial.println("        ESP32 LoRa-Serial Bridge (Optimized)");
  Serial.println("        Combined Receiver with DIO0 Checking");
  Serial.println("========================================\n");
  
  // Initialize SPI with custom pins
  SPI.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_CS);
  
  Serial.println("🔧 Initializing LoRa radio...");
  Serial.println("   Configuration:");
  Serial.printf("   • Frequency: %.1f MHz\n", LORA_FREQUENCY);
  Serial.printf("   • Offset: %d Hz\n", FREQ_OFFSET);
  Serial.printf("   • Spreading Factor: %d\n", LORA_SPREADING_FACTOR);
  Serial.printf("   • Bandwidth: %.1f kHz\n", LORA_BANDWIDTH);
  Serial.printf("   • Coding Rate: %d/8\n", LORA_CODING_RATE);
  
  // Initialize LoRa with hardware reset
  loraInitialized = initializeLoRa();
  
  if (loraInitialized) {
    Serial.println("\n📡 LoRa Radio Status:");
    Serial.println("   ✅ Module: SX1278 detected");
    Serial.println("   ✅ Mode: Receiver active");
    Serial.println("   ✅ CRC: Enabled");
    Serial.println("\n   📊 RSSI Interpretation (after packet arrival):");
    Serial.println("      -30 to -60 dBm: Excellent signal");
    Serial.println("      -60 to -90 dBm: Good signal");
    Serial.println("      -90 to -120 dBm: Weak signal");
    Serial.println("      Below -120 dBm: Very weak/missing");
  } else {
    Serial.println("❌ LoRa initialization failed!");
    Serial.println("   Check wiring and power supply.");
  }
  
  Serial.println("\n✅ SYSTEM READY");
  Serial.println("   Waiting for:");
  Serial.println("   1. LoRa data from primary ESP32");
  Serial.println("   2. Serial commands from Flutter app");
  Serial.println("========================================\n");
  
  lastDataReceived = millis();

  // Initialize BLE (NUS-like) for Flutter app
  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P7); // Max power for better advertising range
  
  // CRITICAL: Disable security to prevent pairing issues blocking writes
  NimBLEDevice::setSecurityAuth(false, false, false);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  
  // CRITICAL: Delete all bonds to force Android to re-discover GATT table
  // This fixes the stale GATT cache issue where writes go to wrong handle
  NimBLEDevice::deleteAllBonds();
  Serial.println("✓ BLE bonds cleared (forces GATT rediscovery)");
  
  pBleServer = NimBLEDevice::createServer();
  pBleServer->setCallbacks(new BleServerCallbacks()); // Monitor connections/disconnections
  
  // Create service
  NimBLEService* pSvc = pBleServer->createService("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  pBleTx = pSvc->createCharacteristic("6E400003-B5A3-F393-E0A9-E50E24DCCA9E", NIMBLE_PROPERTY::NOTIFY);
  
  // CRITICAL FIX: Support BOTH write types for maximum compatibility
  pBleRx = pSvc->createCharacteristic("6E400002-B5A3-F393-E0A9-E50E24DCCA9E", 
                                       NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  pBleRx->setCallbacks(new BleRxCallbacks());
  Serial.printf("✓ BLE RX characteristic created (callback addr: %p)\n", pBleRx);
  
  pSvc->start();
  
  // Configure advertising
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  
  // Clear any previous advertising data
  pAdv->reset();
  
  // Set device name
  pAdv->setName(BLE_DEVICE_NAME);
  
  // Add complete list of 128-bit service UUIDs (critical for NRF to see it)
  NimBLEUUID svcUUID("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  pAdv->addServiceUUID(svcUUID);
  
  // Advertising parameters
  pAdv->setAppearance(0);           // Generic appearance
  pAdv->setMinInterval(0x20);       // Min advertising interval (20ms)
  pAdv->setMaxInterval(0xF4);       // Max advertising interval (308ms)
  
  // Start advertising
  pAdv->start();
  delay(200); // Give advertising time to start properly
  
  Serial.println("✓ BLE initialized (NUS-like)");
  Serial.println("  Device Name: LoRaReceiver");
  Serial.println("  Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  Serial.println("  TX Char: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E (NOTIFY)");
  Serial.println("  RX Char: 6E400002-B5A3-F393-E0A9-E50E24DCCA9E (WRITE)");
  Serial.println("  Status: Advertising... Awaiting connection");
}

// ================================================================================
// SECTION 7: MAIN LOOP
// ================================================================================
void loop() {
  unsigned long currentTime = millis();

  // Periodic BLE connection check (every 5 seconds)
  static unsigned long lastConnCheck = 0;
  if (currentTime - lastConnCheck > 5000) {
    lastConnCheck = currentTime;
    if (pBleServer) {
      Serial.printf("BLE connected clients: %d\n", pBleServer->getConnectedCount());
    }
  }

  // 1. Check for incoming LoRa data using DIO0 pin (most reliable)
  if (loraInitialized) {
    checkIncomingLoRaData();
  }
  
  // 2. Print system status every 30 seconds (includes BLE connection count)
  if (currentTime - lastStatusPrint >= 30000) {
    lastStatusPrint = currentTime;
    printSystemStatus();
    
    // Show BLE connection status
    if (pBleServer) {
      int connCount = pBleServer->getConnectedCount();
      if (connCount > 0) {
        Serial.printf("📱 BLE: %d client(s) connected\n", connCount);
      } else {
        Serial.println("📱 BLE: No clients connected (advertising active)");
      }
    }
  }
  
  // 3. Check for data timeout (warn if no data for 30+ seconds)
  //    Skip during first 30s of uptime (lastDataReceived from setup() isn't real data)
  if (currentTime > DATA_TIMEOUT_MS && lastDataReceived > 0 && 
      currentTime > lastDataReceived &&  // Prevent unsigned underflow → 4294967s bug
      (currentTime - lastDataReceived) >= DATA_TIMEOUT_MS) {
    static unsigned long lastWarning = 0;
    // Only warn every 30 seconds (not every 5 seconds - reduces spam)
    if (currentTime - lastWarning >= 30000) {
      unsigned long secsSinceData = (currentTime - lastDataReceived) / 1000;
      Serial.printf("⚠️ WARNING: No LoRa data received for %lu seconds\n", secsSinceData);
      lastWarning = currentTime;
      
      // Restart receiver if timeout occurs
      if (loraInitialized) {
        Serial.println("   🔄 Restarting receiver mode...");
        radio.startReceive();
      }
    }
  }
  
  delay(LOOP_DELAY_MS);
}

// ================================================================================
// SECTION 8: LORA INITIALIZATION
// ================================================================================
bool initializeLoRa() {
  Serial.println("Initializing LoRa with frequency offset...");
  
  // Hardware reset (critical for stable operation)
  pinMode(LORA_RST, OUTPUT);
  digitalWrite(LORA_RST, LOW);
  delay(100);
  digitalWrite(LORA_RST, HIGH);
  delay(200);
  
  // Calculate frequency with offset
  float freqWithOffset = LORA_FREQUENCY + (FREQ_OFFSET / 1e6);
  
  int state = radio.begin(
    freqWithOffset,
    LORA_BANDWIDTH,
    LORA_SPREADING_FACTOR,
    LORA_CODING_RATE,
    LORA_SYNC_WORD
  );
  
  if (state != RADIOLIB_ERR_NONE) {
    Serial.printf("❌ LoRa begin failed (code %d)\n", state);
    return false;
  }
  
  // Set CRC BEFORE starting receive
  radio.setCRC(true);

  // Set output power
  radio.setOutputPower(17);
  Serial.println("   Output power set to 17 dBm");

  // Start receive mode AFTER CRC configuration
  state = radio.startReceive();
  if (state != RADIOLIB_ERR_NONE) {
    Serial.printf("❌ startReceive failed (code %d)\n", state);
    return false;
  }

  Serial.println("✅ LoRa initialized successfully!");
  Serial.printf("   Frequency: %.3f MHz (Offset: %d Hz)\n",
                freqWithOffset, FREQ_OFFSET);
  Serial.println("   Using DIO0 pin checking for reliable reception");
  
  return true;
}

// ================================================================================
// SECTION 9: LORA DATA RECEPTION
// ================================================================================
void checkIncomingLoRaData() {
  // Method 1: Check DIO0 pin (most reliable for SX1278)
  if (digitalRead(LORA_DIO0) == HIGH) {
    uint8_t buf[256] = {0};
    int state = radio.readData(buf, 255);
    
    if (state == RADIOLIB_ERR_NONE) {
      // Properly null-terminate using actual packet length
      size_t pktLen = radio.getPacketLength();
      if (pktLen < 256) buf[pktLen] = 0;
      else buf[255] = 0;
      String loraData = String((char*)buf);
      loraData.trim();  // Remove any trailing whitespace/newlines
      
      // Update timing and counters
      lastDataReceived = millis();
      packetCounter++;
      
      // Get signal metrics (REAL RSSI appears HERE after packet)
      float rssi = radio.getRSSI();
      float snr = radio.getSNR();
      long freqErr = radio.getFrequencyError();
      
      // Log reception
      Serial.printf("\n%lus: 📥 LoRa Data Received\n", millis() / 1000);
      Serial.printf("   Raw: %s\n", loraData.c_str());
      Serial.printf("   RSSI: %.1f dBm | SNR: %.1f dB | FreqErr: %ld Hz\n", 
                    rssi, snr, freqErr);
      
      // Signal strength indicators
      if (rssi > -100) Serial.println("   💡 STRONG SIGNAL");
      else if (rssi > -120) Serial.println("   💡 USABLE SIGNAL");
      else Serial.println("   ⚠️  WEAK SIGNAL");

      // Determine packet type and convert to JSON for BLE forwarding
      float testValues[6];
      int testCount = 0;
      parseCSVData(loraData, testValues, testCount);
      
      if (testCount == 6 && !loraData.startsWith("ACKCMD:") && !loraData.startsWith("REJECT:")) {
        // This is our simplified sensor CSV format
        String json = convertToJSON(loraData);
        Serial.println(json);
        bleNotify(json);
      } else if (loraData.startsWith("ACKCMD:")) {
        // Command ACK from transmitter - forward as structured JSON
        String safeRaw = escapeJsonString(loraData);
        char buf[256];
        snprintf(buf, sizeof(buf),
          "{\"type\":\"ackcmd\",\"raw\":\"%s\","
          "\"timestamp\":%lu,\"rssi\":%.1f,\"snr\":%.1f}",
          safeRaw.c_str(), millis() / 1000, rssi, snr);
        Serial.println(buf);
        bleNotify(String(buf));
      } else if (loraData.startsWith("STATUS:")) {
        // Tank status change from transmitter (TANK_FULL or TANK_OK)
        String statusValue = loraData.substring(7);  // After "STATUS:"
        statusValue.trim();
        Serial.printf("📡 STATUS received from transmitter: [%s]\n", statusValue.c_str());
        
        char buf[256];
        snprintf(buf, sizeof(buf),
          "{\"type\":\"status\",\"status\":\"%s\","
          "\"tank_full\":%s,\"timestamp\":%lu,\"rssi\":%.1f,\"snr\":%.1f}",
          escapeJsonString(statusValue).c_str(),
          (statusValue == "TANK_FULL" ? "true" : "false"),
          millis() / 1000, rssi, snr);
        Serial.println(buf);
        bleNotify(String(buf));
      } else if (loraData.startsWith("DEVSTATE:")) {
        // Device state report from transmitter (response to GETSTATE command)
        String stateData = loraData.substring(9);  // After "DEVSTATE:"
        int f1=0, f2=0, f3=0, ht=0, dh=0, tk=0;
        sscanf(stateData.c_str(), "FAN1=%d,FAN2=%d,FAN3=%d,HEATER=%d,DEHUM=%d,TANK=%d",
               &f1, &f2, &f3, &ht, &dh, &tk);

        char buf[256];
        snprintf(buf, sizeof(buf),
          "{\"type\":\"devstate\",\"fan1\":%s,\"fan2\":%s,\"fan3\":%s,"
          "\"heater\":%s,\"dehum\":%s,\"tank_full\":%s,"
          "\"timestamp\":%lu,\"rssi\":%.1f,\"snr\":%.1f}",
          f1 ? "true" : "false", f2 ? "true" : "false", f3 ? "true" : "false",
          ht ? "true" : "false", dh ? "true" : "false", tk ? "true" : "false",
          millis() / 1000, rssi, snr);
        Serial.println(buf);
        bleNotify(String(buf));
      } else if (loraData.startsWith("REJECT:")) {
        // Expected format: REJECT:<command>:<REASON>
        int firstColon = loraData.indexOf(':'); // index of ':' after REJECT
        int secondColon = loraData.indexOf(':', firstColon + 1);
        String cmdStr = "";
        String reason = "";
        if (secondColon > 0) {
          cmdStr = loraData.substring(firstColon + 1, secondColon);
          reason = loraData.substring(secondColon + 1);
        } else {
          cmdStr = loraData.substring(firstColon + 1);
        }
        char buf[256];
        snprintf(buf, sizeof(buf),
          "{\"type\":\"reject\",\"command\":\"%s\",\"reason\":\"%s\","
          "\"timestamp\":%lu,\"rssi\":%.1f,\"snr\":%.1f}",
          escapeJsonString(cmdStr).c_str(), escapeJsonString(reason).c_str(),
          millis() / 1000, rssi, snr);
        Serial.println(buf);
        bleNotify(String(buf));
      } else {
        // Other non-sensor messages - forward as simple JSON
        String safeRaw = escapeJsonString(loraData);
        char buf[256];
        snprintf(buf, sizeof(buf),
          "{\"type\":\"message\",\"raw\":\"%s\","
          "\"timestamp\":%lu,\"rssi\":%.1f,\"snr\":%.1f}",
          safeRaw.c_str(), millis() / 1000, rssi, snr);
        Serial.println(buf);
        bleNotify(String(buf));
      }
      
    } else if (state == RADIOLIB_ERR_CRC_MISMATCH) {
      failedPackets++;
      Serial.printf("⚠️ CRC MISMATCH (code %d) - weak signal/corruption (Total errors: %d)\n", 
                    state, failedPackets);
    } else {
      failedPackets++;
      Serial.printf("⚠️ LoRa reception failed: %d (Total errors: %d)\n", 
                    state, failedPackets);
    }
    
    // Always restart receive after processing any packet
    radio.startReceive();
  }
}

// ================================================================================
// SECTION 10: DATA CONVERSION FUNCTIONS
// ================================================================================
// Escape string for safe JSON embedding
String escapeJsonString(const String& str) {
  String result = "";
  for (int i = 0; i < str.length(); i++) {
    char c = str[i];
    switch (c) {
      case '"':  result += "\\\""; break;
      case '\\': result += "\\\\"; break;
      case '\n': result += "\\n"; break;
      case '\r': result += "\\r"; break;
      case '\t': result += "\\t"; break;
      default:
        if (c >= 32 && c < 127) {  // Printable ASCII
          result += c;
        } else {
          // Non-printable: skip or replace with ?
          result += '?';
        }
    }
  }
  return result;
}

String convertToJSON(const String& loraData) {
  // Expected format: "T1,H1,T2,H2,VOL,TANK" (6 fields)
  float values[6];
  int valueCount = 0;
  
  // Parse CSV data
  parseCSVData(loraData, values, valueCount);
  
  // Validate we have enough values
  if (valueCount < 6) {
    String safeData = escapeJsonString(loraData);
    return "{\"error\":\"Invalid data format\",\"raw\":\"" + safeData + "\",\"fields_found\":" + String(valueCount) + "}";
  }
  
  // Build JSON object with snprintf - only the 6 required fields
  char buf[256];
  snprintf(buf, sizeof(buf),
    "{\"temp1\":%.1f,\"humid1\":%.1f,\"temp2\":%.1f,\"humid2\":%.1f,"
    "\"volume\":%.1f,\"tank_full\":%s,"
    "\"timestamp\":%lu,\"rssi\":%.1f,\"snr\":%.1f}",
    values[0], values[1], values[2], values[3],
    values[4], (values[5] == 1 ? "true" : "false"),
    millis() / 1000, radio.getRSSI(), radio.getSNR());
  return String(buf);
}

void parseCSVData(const String& data, float values[], int& count) {
  count = 0;
  int startIndex = 0;
  int commaIndex = 0;
  
  // Parse up to 6 values: T1,H1,T2,H2,VOL,TANK
  while (commaIndex >= 0 && count < 6) {
    commaIndex = data.indexOf(',', startIndex);
    
    String valueStr;
    if (commaIndex >= 0) {
      valueStr = data.substring(startIndex, commaIndex);
      startIndex = commaIndex + 1;
    } else {
      valueStr = data.substring(startIndex);
    }
    
    values[count++] = valueStr.toFloat();
  }
}

// ================================================================================
// SECTION 11: LORA TRANSMISSION FUNCTION
// ================================================================================
void sendLoRaCommand(const String& command) {
  if (!loraInitialized) {
    Serial.println("   ❌ LoRa not initialized, cannot send command");
    return;
  }
  
  // Send the command TWICE to combat half-duplex timing collisions
  // (Transmitter ignores duplicates within 5-second window)
  for (int attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) {
      // Wait before resending - give transmitter time to finish any TX/ACK
      Serial.println("   ⏳ Waiting 1.2s before resend...");
      delay(1200);
    }
    
    int retryCount = 0;
    int state = RADIOLIB_ERR_UNKNOWN;
    
    // Convert String to C-string for RadioLib (NO newline - cleaner parsing)
    const char* cmd_cstr = command.c_str();
    Serial.printf("\n📤 LoRa TX COMMAND [%d/2]: [%s] (%d bytes)\n", attempt + 1, cmd_cstr, command.length());
    Serial.println("   🛑 Stopping receiver mode (standby)");
    
    // CRITICAL: Stop receive mode before transmitting (prioritize command)
    radio.standby();
    delay(10);  // Give radio time to switch modes
    
    // Retry logic (for radio TX errors, not application-level retries)
    while (retryCount < MAX_RETRY_COUNT) {
      state = radio.transmit(cmd_cstr);
      
      if (state == RADIOLIB_ERR_NONE) {
        Serial.printf("   ✅ Command sent [%d/2]\n", attempt + 1);
        break;
      }
      
      retryCount++;
      if (retryCount < MAX_RETRY_COUNT) {
        Serial.printf("   ⚠️ Radio retry %d/%d after error: %d\n", 
                      retryCount, MAX_RETRY_COUNT, state);
        delay(100 * retryCount);
      }
    }
    
    if (state != RADIOLIB_ERR_NONE) {
      Serial.printf("   ❌ TX failed on attempt %d (Error: %d)\n", attempt + 1, state);
    }
    
    // Restart receive mode between attempts
    radio.startReceive();
  }
  
  // Notify BLE after both sends complete
  String ack = "SENT:" + command;
  Serial.println("   📱 BLE ACK: " + ack);
  bleNotify(ack);
}

// ================================================================================
// SECTION 12: SYSTEM STATUS FUNCTION
// ================================================================================
void printSystemStatus() {
  unsigned long uptime = millis() / 1000;
  unsigned long lastDataSec = (millis() - lastDataReceived) / 1000;
  float freqWithOffset = LORA_FREQUENCY + (FREQ_OFFSET / 1e6);
  
  Serial.println("\n📊 SYSTEM STATUS =======================");
  Serial.printf("   Uptime: %lu seconds\n", uptime);
  Serial.printf("   LoRa: %s\n", loraInitialized ? "READY" : "FAILED");
  
  if (loraInitialized) {
    Serial.printf("   Frequency: %.3f MHz (Offset: %d Hz)\n", 
                  freqWithOffset, FREQ_OFFSET);
    Serial.printf("   Packets: %u received, %u errors\n", packetCounter, failedPackets);
    
    if (packetCounter > 0) {
      float successRate = (float)packetCounter / (packetCounter + failedPackets) * 100;
      Serial.printf("   Success Rate: %.1f%%\n", successRate);
    }
    
    if (lastDataReceived > 0) {
      Serial.printf("   Last data: %lu seconds ago\n", lastDataSec);
    }

    Serial.printf("   Current RSSI: %.1f dBm\n", radio.getRSSI());
  }
  
  Serial.printf("   DIO0 Pin State: %s\n", digitalRead(LORA_DIO0) ? "HIGH" : "LOW");
  Serial.println("======================================\n");
}

// ================================================================================
// END OF CODE
// ================================================================================
