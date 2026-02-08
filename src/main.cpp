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
void checkSerialCommands();
String convertToJSON(const String& loraData);
void parseCSVData(const String& data, float values[], int& count);
void sendLoRaCommand(const String& command);
void printSystemStatus();

// BLE helper: notify if connected
void bleNotify(const String &msg) {
  // Use server connected count to determine if any client is connected
  if (pBleTx && pBleServer && pBleServer->getConnectedCount() > 0) {
    // Ensure a stable data pointer when passing to setValue
    // Add newline terminator for message boundary detection
    String msgWithNewline = msg + "\n";
    std::string s = msgWithNewline.c_str();
    pBleTx->setValue((uint8_t*)s.data(), s.length());
    pBleTx->notify();
  }
}

// BLE Server callbacks for connection monitoring
class BleServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
    Serial.println("✓ BLE CLIENT CONNECTED");
    Serial.printf("  Client: %s\n", NimBLEAddress(desc->peer_ota_addr).toString().c_str());
  }
  
  void onDisconnect(NimBLEServer* pServer) {
    Serial.println("✗ BLE CLIENT DISCONNECTED");
    Serial.println("  Restarting BLE advertising...");
    
    // CRITICAL: Restart advertising after disconnect
    // This fixes the issue where device disappears from scan list
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
  void onWrite(NimBLECharacteristic* pChr) {
    std::string s = pChr->getValue();
    if (s.length() == 0) return;
    String cmd = String(s.c_str());
    cmd.trim();
    
    Serial.println("📲 BLE RX: " + cmd);
    
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
    
    // Log the parsed command
    Serial.printf("   Device: %s | Action: %s\n", device.c_str(), action.c_str());
    
    // Forward the exact command to transmitter via LoRa
    sendLoRaCommand(cmd);
    
    // Notify app that it was forwarded
    String ack = "FORWARDED:" + cmd;
    bleNotify(ack);
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
  
  Serial.println("\n" + String(millis() / 1000) + "s: ========================================");
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
    
    // ⚠️ FIX #1: REMOVE immediate RSSI read (causes -164 dBm artifact)
    // RSSI is meaningless until first packet arrives - skip this check
    // float currentRSSI = radio.getRSSI();
    // Serial.printf("   📶 Current RSSI: %.1f dBm\n", currentRSSI);
    
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
  
  pBleServer = NimBLEDevice::createServer();
  pBleServer->setCallbacks(new BleServerCallbacks()); // Monitor connections/disconnections
  
  // Create service
  NimBLEService* pSvc = pBleServer->createService("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  pBleTx = pSvc->createCharacteristic("6E400003-B5A3-F393-E0A9-E50E24DCCA9E", NIMBLE_PROPERTY::NOTIFY);
  pBleRx = pSvc->createCharacteristic("6E400002-B5A3-F393-E0A9-E50E24DCCA9E", NIMBLE_PROPERTY::WRITE);
  pBleRx->setCallbacks(new BleRxCallbacks());
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
  
  // 1. Check for incoming LoRa data using DIO0 pin (most reliable)
  if (loraInitialized) {
    checkIncomingLoRaData();
  }
  
  // 2. Check for Serial commands (from Flutter app)
  checkSerialCommands();
  
  // 3. Print system status every 30 seconds
  if (currentTime - lastStatusPrint >= 30000) {
    lastStatusPrint = currentTime;
    printSystemStatus();
  }
  
  // 4. Check for data timeout (warn if no data for 30+ seconds)
  if (currentTime - lastDataReceived >= DATA_TIMEOUT_MS && lastDataReceived > 0) {
    if (currentTime - lastStatusPrint >= 5000) {
      Serial.println("⚠️ WARNING: No LoRa data received for " + 
                     String((currentTime - lastDataReceived) / 1000) + " seconds");
      lastStatusPrint = currentTime;
      
      // Restart receiver if timeout occurs
      if (loraInitialized) {
        radio.startReceive();
        Serial.println("   Receiver restarted");
      }
    }
  }
  
  delay(LOOP_DELAY_MS);
}

// ================================================================================
// SECTION 8: LORA INITIALIZATION (WITH FREQUENCY OFFSET & CRC FIX)
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
  
  // Initialize WITHOUT CRC first
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
  
  // CRITICAL FIX #2: Set CRC BEFORE starting receive (prevents error -24)
  radio.setCRC(true);
  
  // OPTIONAL: Set output power if you want to see transmitter side info
  radio.setOutputPower(17);  // 17 dBm (typical max for SX1278)
  Serial.println("   Output power set to 17 dBm");
  
  // Start receive mode AFTER CRC configuration
  state = radio.startReceive();
  if (state != RADIOLIB_ERR_NONE) {
    Serial.printf("❌ startReceive failed (code %d)\n", state);
    return false;
  }
  
  // ⚠️ FIX #3: REMOVE immediate RSSI read (causes -164 dBm artifact)
  // The -164 dBm you saw was NORMAL - RSSI register not updated yet
  // Real RSSI appears ONLY after first packet reception
  
  Serial.println("✅ LoRa initialized successfully!");
  Serial.printf("   Frequency: %.3f MHz (Offset: %d Hz)\n", 
                freqWithOffset, FREQ_OFFSET);
  Serial.println("   Using DIO0 pin checking for reliable reception");
  
  return true;
}

// ================================================================================
// SECTION 9: LORA DATA RECEPTION (USING DIO0 PIN CHECKING - FIXED API)
// ================================================================================
void checkIncomingLoRaData() {
  // Method 1: Check DIO0 pin (most reliable for SX1278)
  if (digitalRead(LORA_DIO0) == HIGH) {
    // ⚠️ FIX #4: CORRECT RadioLib API for SX1278 (was using invalid receive() method)
    uint8_t buf[256];
    int state = radio.readData(buf, 255);  // MUST use buffer + length
    
    if (state == RADIOLIB_ERR_NONE) {
      buf[255] = 0;  // Null-terminate
      String loraData = String((char*)buf);
      
      // Update timing and counters
      lastDataReceived = millis();
      packetCounter++;
      
      // Get signal metrics (REAL RSSI appears HERE after packet)
      float rssi = radio.getRSSI();
      float snr = radio.getSNR();
      long freqErr = radio.getFrequencyError();
      
      // Log reception
      Serial.println("\n" + String(millis() / 1000) + "s: 📥 LoRa Data Received");
      Serial.println("   Raw: " + loraData);
      Serial.printf("   RSSI: %.1f dBm | SNR: %.1f dB | FreqErr: %ld Hz\n", 
                    rssi, snr, freqErr);
      
      // Signal strength indicators
      if (rssi > -100) Serial.println("   💡 STRONG SIGNAL");
      else if (rssi > -120) Serial.println("   💡 USABLE SIGNAL");
      else Serial.println("   ⚠️  WEAK SIGNAL");

      // If the packet is a sensor CSV (starts with "WT1"), convert->JSON and ACK.
      if (loraData.startsWith("WT1")) {
        String json = convertToJSON(loraData);
        Serial.println(json);
        bleNotify(json);

        // CRITICAL FIX: Send STATUS instead of ACK to prevent command loop
        // Transmitter ignores STATUS packets but logs them
        String status = "STATUS:RX:" + String(packetCounter);
        sendLoRaCommand(status);
      }
       else if (loraData.startsWith("ACKCMD:")) {
        // Command ACK from transmitter - forward structured JSON
        String json = "{";
        json += "\"type\":\"ackcmd\",";
        json += "\"raw\":\"" + loraData + "\",";
        json += "\"timestamp\":" + String(millis() / 1000) + ",";
        json += "\"rssi\":" + String(rssi, 1) + ",";
        json += "\"snr\":" + String(snr, 1);
        json += "}";
        Serial.println(json);
        bleNotify(json);
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
        String json = "{";
        json += "\"type\":\"reject\",";
        json += "\"command\":\"" + cmdStr + "\",";
        json += "\"reason\":\"" + reason + "\",";
        json += "\"timestamp\":" + String(millis() / 1000) + ",";
        json += "\"rssi\":" + String(rssi, 1) + ",";
        json += "\"snr\":" + String(snr, 1);
        json += "}";
        Serial.println(json);
        bleNotify(json);
      } else {
        // Other non-sensor messages - forward as simple JSON
        String msg = "{";
        msg += "\"type\":\"message\",";
        msg += "\"raw\":\"" + loraData + "\",";
        msg += "\"timestamp\":" + String(millis() / 1000) + ",";
        msg += "\"rssi\":" + String(rssi, 1) + ",";
        msg += "\"snr\":" + String(snr, 1);
        msg += "}";
        Serial.println(msg);
        bleNotify(msg);
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
    
    // CRITICAL: Always restart receive after processing ANY packet
    radio.startReceive();
  }
  
  // REMOVED: radio.available() check (causes state corruption with SX1278)
  // Alternative method removed to prevent error -24
}

// ================================================================================
// SECTION 10: SERIAL COMMAND HANDLING
// ================================================================================
void checkSerialCommands() {
  if (Serial.available()) {
    String command = Serial.readStringUntil('\n');
    command.trim();
    
    if (command.length() > 0) {
      Serial.println("\n" + String(millis() / 1000) + "s: 📤 Serial Command Received");
      Serial.println("   Command: " + command);
      
      // Validate command format
      if (command.startsWith("GPIO") && command.indexOf('=') > 4) {
        // Forward command to primary ESP32 via LoRa
        sendLoRaCommand(command);
        
        // Confirm to Serial
        Serial.println("   ✅ Command forwarded via LoRa");
        // Notify BLE client
        bleNotify("FORWARDED:" + command);
      } else {
        // Handle special commands
        if (command.equalsIgnoreCase("STATUS")) {
          printSystemStatus();
        } 
        else if (command.equalsIgnoreCase("RSSI")) {
          float currentRSSI = radio.getRSSI();
          float currentSNR = radio.getSNR();
          Serial.printf("   📶 Current RSSI: %.1f dBm | SNR: %.1f dB\n", currentRSSI, currentSNR);
        }
        else if (command.equalsIgnoreCase("RESET")) {
          packetCounter = 0;
          failedPackets = 0;
          Serial.println("   ✅ Counters reset");
        } else if (command.equalsIgnoreCase("RESTART")) {
          radio.startReceive();
          Serial.println("   ✅ Receiver restarted");
        } else {
          // Forward as-is
          sendLoRaCommand(command);
        }
      }
    }
  }
}

// ================================================================================
// SECTION 11: DATA CONVERSION FUNCTIONS
// ================================================================================
String convertToJSON(const String& loraData) {
  // Expected format: "WT1,T1,H1,T2,H2,WL,VOL,PERCENT,PKT#,TANK"
  float values[10];
  int valueCount = 0;
  
  // Parse CSV data
  parseCSVData(loraData, values, valueCount);
  
  // Validate we have enough values
  if (valueCount < 10) {
    return "{\"error\":\"Invalid data format\",\"raw\":\"" + loraData + "\"}";
  }
  
  // Build JSON object
  String json = "{";
  json += "\"sensor\":\"WT1\",";
  json += "\"temp1\":" + String(values[1], 1) + ",";
  json += "\"humid1\":" + String(values[2], 1) + ",";
  json += "\"temp2\":" + String(values[3], 1) + ",";
  json += "\"humid2\":" + String(values[4], 1) + ",";
  json += "\"water_level\":" + String(values[5], 1) + ",";
  json += "\"volume\":" + String(values[6], 1) + ",";
  json += "\"percent\":" + String(values[7], 1) + ",";
  json += "\"packet\":" + String((int)values[8]) + ",";
  json += "\"tank_full\":" + String(values[9] == 1 ? "true" : "false") + ",";
  json += "\"timestamp\":" + String(millis() / 1000) + ",";
  json += "\"rssi\":" + String(radio.getRSSI(), 1) + ",";
  json += "\"snr\":" + String(radio.getSNR(), 1);
  json += "}";
  
  return json;
}

void parseCSVData(const String& data, float values[], int& count) {
  count = 0;
  int startIndex = 0;
  int commaIndex = 0;
  
  while (commaIndex >= 0 && count < 10) {
    commaIndex = data.indexOf(',', startIndex);
    
    String valueStr;
    if (commaIndex >= 0) {
      valueStr = data.substring(startIndex, commaIndex);
      startIndex = commaIndex + 1;
    } else {
      valueStr = data.substring(startIndex);
    }
    
    // Handle special case for first value (should be "WT1")
    if (count == 0 && valueStr == "WT1") {
      values[count++] = 0;  // Placeholder
    } else {
      values[count++] = valueStr.toFloat();
    }
  }
}

// ================================================================================
// SECTION 12: LORA TRANSMISSION FUNCTION
// ================================================================================
void sendLoRaCommand(const String& command) {
  if (!loraInitialized) {
    Serial.println("   ❌ LoRa not initialized, cannot send command");
    return;
  }
  
  int retryCount = 0;
  int state = RADIOLIB_ERR_UNKNOWN;
  
  // Convert String to C-string for RadioLib
  const char* cmd_cstr = command.c_str();
  Serial.printf("\n📤 LoRa TX COMMAND: [%s] (%d bytes)\n", cmd_cstr, command.length());
  
  // Stop receive mode before transmitting
  radio.standby();
  
  // Retry logic
  while (retryCount < MAX_RETRY_COUNT) {
    state = radio.transmit(cmd_cstr);
    
    if (state == RADIOLIB_ERR_NONE) {
      // Success
      Serial.printf("   ✅ Command sent (RSSI: %d dBm, SNR: %.1f dB)\n", 
                    radio.getRSSI(), radio.getSNR());
      // Notify BLE
      bleNotify(String("SENT:") + command);
      
      // Restart receive mode
      radio.startReceive();
      return;
    }
    
    retryCount++;
    if (retryCount < MAX_RETRY_COUNT) {
      Serial.printf("   ⚠️ Retry %d/%d after error: %d\n", 
                    retryCount, MAX_RETRY_COUNT, state);
      delay(100 * retryCount);
    }
  }
  
  // Failed after retries
  Serial.printf("   ❌ Failed to send after %d retries (Error: %d)\n", 
                MAX_RETRY_COUNT, state);
  // Notify BLE of failure
  bleNotify(String("SEND_FAILED:") + String(state));
  
  // Always restart receive mode
  radio.startReceive();
}

// ================================================================================
// SECTION 13: SYSTEM STATUS FUNCTION
// ================================================================================
void printSystemStatus() {
  unsigned long uptime = millis() / 1000;
  unsigned long lastDataSec = (millis() - lastDataReceived) / 1000;
  float freqWithOffset = LORA_FREQUENCY + (FREQ_OFFSET / 1e6);
  
  Serial.println("\n📊 SYSTEM STATUS =======================");
  Serial.println("   Uptime: " + String(uptime) + " seconds");
  Serial.println("   LoRa: " + String(loraInitialized ? "READY" : "FAILED"));
  
  if (loraInitialized) {
    Serial.printf("   Frequency: %.3f MHz (Offset: %d Hz)\n", 
                  freqWithOffset, FREQ_OFFSET);
    Serial.println("   Packets: " + String(packetCounter) + " received, " + 
                   String(failedPackets) + " errors");
    
    if (packetCounter > 0) {
      float successRate = (float)packetCounter / (packetCounter + failedPackets) * 100;
      Serial.printf("   Success Rate: %.1f%%\n", successRate);
    }
    
    if (lastDataReceived > 0) {
      Serial.println("   Last data: " + String(lastDataSec) + " seconds ago");
    }
    
    // ✅ REAL RSSI appears HERE (after packets received)
    Serial.printf("   Current RSSI: %.1f dBm\n", radio.getRSSI());
  }
  
  Serial.println("   DIO0 Pin State: " + String(digitalRead(LORA_DIO0) ? "HIGH" : "LOW"));
  Serial.println("======================================\n");
}

// ================================================================================
// END OF CODE
// ================================================================================
