LoRa Receiver Flutter App

Minimal Flutter app to connect to the ESP32 `LoRaReceiver` via BLE (NUS-like service) and display sensor data.

How to run

1. Install Flutter SDK: https://flutter.dev/docs/get-started/install
2. From this folder run:

```bash
flutter pub get
flutter run
```

Behavior

- Scans for BLE devices advertising the service UUID `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`.
- Subscribes to notifications on `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` (TX characteristic).
- Writes commands to `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` (RX characteristic).
- Shows sensor fields, provides buttons for `DEV:HEATER` and `DEV:DEHUM`, and a free text command box.

Notes

- Ensure `Receiver` ESP32 advertises as `LoRaReceiver` and is advertising the NUS service.
- The app expects incoming JSON (as implemented in `Receiver`) or CSV starting with `WT1`.
