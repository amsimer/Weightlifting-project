#include <LittleFS.h>
#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// Bluetooth UUIDs used by the WeightLifting app
#define SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_CHARACTERISTIC   "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define TX_CHARACTERISTIC   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// ESP32-C3 UART pins/Users/yunus/Documents/Arduino/plugins/arduino-littlefs-upload-1.6.3.vsix
const int ODRIVE_RX_PIN = 4;   // ESP32 receives from ODrive GPIO1 (TX)
const int ODRIVE_TX_PIN = 21;  // ESP32 sends to ODrive GPIO2 (RX)

// Conservative values for the first unloaded movement test
const float SAFE_CURRENT_LIMIT_A = 2.0f;
const float SAFE_JOG_SPEED_TURNS_PER_SECOND = 0.10f;
const float CALIBRATION_CURRENT_LIMIT_A = 10.668f;
// Previous group calibration: current = kg / 1.8 - 0.6.
// Keep the first training build inside the verified low range
const float MIN_TRAINING_WEIGHT_KG = 4.0f;
const float MAX_TRAINING_WEIGHT_KG = 30.0f;
const float RETURN_CURRENT_LIMIT_A = 3.0f;
const float RETURN_SPEED_TURNS_PER_SECOND = -0.5f;
const float RETURN_POSITION_TOLERANCE_TURNS = 0.02f;
const float START_POSITION_TOLERANCE_TURNS = 0.05f;
// Measured on the physical machine: 42.0 cm cable trabel over 18.4225516 encoder turns (30.09.26)
const float CABLE_CM_PER_TURN = 2.279448f;
const float SPEED_DISPLAY_DEADBAND_CM_S = 0.5f;
// Long enough to see the unloaded shaft move, but still automatically limited
const unsigned long SAFE_JOG_TIME_MS = 1500;
const unsigned long TRAINING_TIME_LIMIT_MS = 180000;
const unsigned long RETURN_TIMEOUT_MS = 60000;
const unsigned long RETURN_POLL_INTERVAL_MS = 100;
const unsigned long TRAINING_SPEED_POLL_INTERVAL_MS = 200;
const unsigned long ODRIVE_REPLY_TIMEOUT_MS = 1500;
// Return-settling state
const unsigned long RETURN_SETTLE_TIME_MS = 750;

HardwareSerial ODriveSerial(1);

BLEServer* bleServer = nullptr;
BLECharacteristic* txCharacteristic = nullptr;

// Local Wi-Fi network created by the ESP32
const char* WIFI_AP_NAME = "POWER-CABLE";

WebServer webServer(80);

String latestDeviceMessage = "STARTING";

float latestCablePositionCm = 0.0f;
float latestCableVelocityCmPerSecond = 0.0f;
unsigned long latestFeedbackSequence = 0;

bool bluetoothConnected = false;
bool previousConnection = false;
bool safeJogAllowed = false;
bool jogActive = false;
unsigned long jogStartTime = 0;
bool trainingActive = false;
unsigned long trainingStartTime = 0;
unsigned long nextTrainingSpeedPollTime = 0;
float selectedWeightKg = 4.0f;
float selectedCurrentLimitA = (4.0f / 1.8f) - 0.6f;
bool returnActive = false;
bool savedStartPositionValid = false;
float savedStartPosition = 0.0f;
unsigned long returnStartTime = 0;
unsigned long nextReturnPollTime = 0;
bool returnSettling = false;
unsigned long returnSettleStartTime = 0;

enum PendingRequest {
  REQUEST_NONE,
  REQUEST_VBUS,
  REQUEST_ENCODER_READY,
  REQUEST_MOTOR_CALIBRATED,
  REQUEST_AXIS_ERROR,
  REQUEST_MOTOR_ERROR,
  REQUEST_CONTROLLER_ERROR,
  REQUEST_MANUAL_POSITION,
  REQUEST_TRAINING_FEEDBACK,
  REQUEST_TRAINING_POSITION,
  REQUEST_RETURN_POSITION
};

PendingRequest pendingRequest = REQUEST_NONE;
unsigned long requestStartTime = 0;
String odriveResponse = "";

void sendToApp(const String& message) {
  latestDeviceMessage = message;
  Serial.println(message);

  if (bluetoothConnected && txCharacteristic != nullptr) {
    txCharacteristic->setValue(message.c_str());
    txCharacteristic->notify();
  }
}

void clearODriveInput() {
  while (ODriveSerial.available()) {
    ODriveSerial.read();
  }
}

void beginODriveRequest(PendingRequest request, const char* command) {
  clearODriveInput();
  odriveResponse = "";
  pendingRequest = request;
  requestStartTime = millis();
  ODriveSerial.print(command);
}

void requestBusVoltage() {
  beginODriveRequest(REQUEST_VBUS, "r vbus_voltage\n");
  Serial.println("Voltage request sent to ODrive");
}

void requestManualPosition() {
  if (jogActive || trainingActive || returnActive || pendingRequest != REQUEST_NONE) {
    sendToApp("POSITION_BLOCKED: SYSTEM_BUSY");
    return;
  }

  beginODriveRequest(
    REQUEST_MANUAL_POSITION,
    "r axis1.encoder.pos_estimate\n"
  );
  Serial.println("Position request sent to ODrive");
}

void requestReadinessCheck() {
  safeJogAllowed = false;
  beginODriveRequest(REQUEST_ENCODER_READY, "r axis1.encoder.is_ready\n");
  Serial.println("Readiness check started");
}

void stopMotor(bool reportToApp) {
  // Set both velocity and torque feed-forward to known zero values, the IDLE
  ODriveSerial.print("v 1 0 0\n");
  delay(10);
  ODriveSerial.print("w axis1.requested_state 1\n");
  jogActive = false;
  trainingActive = false;
  returnActive = false;
  pendingRequest = REQUEST_NONE;
  odriveResponse = "";
  clearODriveInput();
  returnSettling = false;
  returnSettleStartTime = 0;

  if (reportToApp) {
    sendToApp("MOTOR_STOPPED");
  }
}
 
 void requestTrainingStart() {
  if (!safeJogAllowed) {
    sendToApp("TRAINING_BLOCKED: CHECK_CALIBRATION_FIRST");
    return;
  }

  if (jogActive || trainingActive || returnActive || pendingRequest != REQUEST_NONE) {
    sendToApp("TRAINING_BLOCKED: SYSTEM_BUSY");
    return;
  }

  // First read the current cable position. The controller will hold this position, so the
  // motor does not jump to an old position when enabling the motor
  beginODriveRequest(REQUEST_TRAINING_POSITION, "r axis1.encoder.pos_estimate\n");
  sendToApp("TRAINING_PREPARING");
}

void startTrainingAtPosition(float currentPosition) {
  
  if (savedStartPositionValid && fabsf(currentPosition - savedStartPosition) > START_POSITION_TOLERANCE_TURNS) {
    sendToApp("TRAINING_BLOCKED: RETURN_TO_START_FIRST");
    return;
  }

  if (!savedStartPositionValid) {
    savedStartPosition = currentPosition;
    savedStartPositionValid = true;
  }

  // Begin from the safe IDLE state.
  ODriveSerial.print("w axis1.requested_state 1\n");
  delay(20);

  // Remove old velocity and torque commands.
  ODriveSerial.print("w axis1.controller.input_vel 0\n");
  delay(10);
  ODriveSerial.print("w axis1.controller.input_torque 0\n");
  delay(10);

  // Limit the motor current to the 4 kg test value.
  ODriveSerial.print("w axis1.motor.config.current_lim ");
  ODriveSerial.print(selectedCurrentLimitA, 3);
  ODriveSerial.print("\n");
  delay(10);

  // Use position control to resist movement away from the starting position.
  ODriveSerial.print("w axis1.controller.config.control_mode 3\n");
  delay(10);
  ODriveSerial.print("w axis1.controller.config.input_mode 1\n");
  delay(10);

  // Use the present cable position as the holding position.
  ODriveSerial.print("w axis1.controller.input_pos ");
  ODriveSerial.print(savedStartPosition, 6);
  ODriveSerial.print("\n");
  delay(10);

  // Enter closed-loop control.
  ODriveSerial.print("w axis1.requested_state 8\n");

  trainingActive = true;
  trainingStartTime = millis();
  nextTrainingSpeedPollTime = millis();
  sendToApp("TRAINING_STARTED: " + String(selectedWeightKg, 1) + "KG");
}

void startReturnMotion() {
  ODriveSerial.print("w axis1.requested_state 1\n");
  delay(20);
  ODriveSerial.print("w axis1.controller.input_vel 0\n");
  delay(10);
  ODriveSerial.print("w axis1.controller.input_torque 0\n");
  delay(10);
  ODriveSerial.print("w axis1.motor.config.current_lim ");
  ODriveSerial.print(RETURN_CURRENT_LIMIT_A, 3);
  ODriveSerial.print("\n");
  delay(10);

  // Position control returns to and briefly holds the saved start
  ODriveSerial.print("w axis1.controller.config.control_mode 3\n");
  delay(10);
  ODriveSerial.print("w axis1.controller.config.input_mode 1\n");
  delay(10);
  // Enter closed-loop control first.
  ODriveSerial.print("w axis1.requested_state 8\n");
  delay(100);

// Then command the saved start position.
// ODrive may reset input_pos when closed-loop begins.
  ODriveSerial.print("w axis1.controller.input_pos ");
  ODriveSerial.print(savedStartPosition, 6);
  ODriveSerial.print("\n");
 
  returnActive = true;
  returnSettling = false;
  returnSettleStartTime = 0;
  returnStartTime = millis();
  nextReturnPollTime = millis();

  sendToApp("RETURN_TO_START_STARTED");
}

void requestReturnToStart() {
  if (!safeJogAllowed) {
    sendToApp("RETURN_BLOCKED: CHECK_CALIBRATION_FIRST");
    return;
  }

  if (!savedStartPositionValid) {
    sendToApp("RETURN_BLOCKED: NO_SAVED_START");
    return;
  }

  if (jogActive || trainingActive || returnActive || pendingRequest != REQUEST_NONE) {
    sendToApp("RETURN_BLOCKED: SYSTEM_BUSY");
    return;
  }

  beginODriveRequest(REQUEST_RETURN_POSITION, "r axis1.encoder.pos_estimate\n");
  sendToApp("RETURN_TO_START_PREPARING");
}

 void startSafeJog(float speed) {
  if (!safeJogAllowed) {
    sendToApp("JOG_BLOCKED: CHECK_CALIBRATION_FIRST");
    return;
  }

  // Start from IDLE and configure a conservative velocity test in RAM only.
  // These settings are not saved to the ODrive configuration.
  ODriveSerial.print("w axis1.requested_state 1\n");
  delay(20);
  ODriveSerial.print("w axis1.controller.input_vel 0\n");
  delay(10);
  ODriveSerial.print("w axis1.controller.input_torque 0\n");
  delay(10);
  ODriveSerial.print("w axis1.motor.config.current_lim 2.0\n");
  delay(10);
  ODriveSerial.print("w axis1.controller.config.control_mode 2\n");
  delay(10);
  // PASSTHROUGH uses the explicit velocity and zero torque avlues below.
  // This avoids a stale/invalid ramp torque on older ODrive firmware.
  ODriveSerial.print("w axis1.controller.config.input_mode 1\n");
  delay(10);
  ODriveSerial.print("w axis1.requested_state 8\n");
  delay(100);

  // ODrive ASCII velocity command: v <axis> <turns/s> <torque feed-forward>.
  // Supplying the final zero prevents UNKOWN_TORQUE on firmware v0.5.5.
  ODriveSerial.print("v 1 ");
  ODriveSerial.print(speed, 3);
  ODriveSerial.print(" 0\n");

  jogActive = true;
  jogStartTime = millis();

  if (speed > 0) {
    sendToApp("SAFE_JOG_FORWARD_STARTED");
  } else {
    sendToApp("SAFE_JOG_REVERSE_STARTED");
  }
}

void handleODriveResponse(const String& response) {
  PendingRequest completedRequest = pendingRequest;
  pendingRequest = REQUEST_NONE;

  if (completedRequest == REQUEST_VBUS) {
    sendToApp("ODRIVE_VBUS: " + response + " V");
    return;
  }

  if (completedRequest == REQUEST_ENCODER_READY) {
    sendToApp("ENCODER1_READY: " + response);
    if (response != "1") {
      sendToApp("NOT_READY: ENCODER");
      return;
    }

beginODriveRequest(REQUEST_MOTOR_CALIBRATED, "r axis1.motor.is_calibrated\n");
    return;
  }

  if (completedRequest == REQUEST_MOTOR_CALIBRATED) {
    sendToApp("MOTOR1_CALIBRATED: " + response);
    if (response != "1") {
      sendToApp("NOT_READY: MOTOR");
      return;
    }

    beginODriveRequest(REQUEST_AXIS_ERROR, "r axis1.error\n");
    return;
  }

  if (completedRequest == REQUEST_AXIS_ERROR) {
    sendToApp("AXIS1_ERROR: " + response);
    if (response == "0") {
      safeJogAllowed = true;
      sendToApp("READY_FOR_SAFE_JOG");
    } else {
      // Axis error 64 means MOTOR_FAILED on ODrive firmware 0.5.5.
      // Read the detailed motor error before changing or clearing anything.
      beginODriveRequest(REQUEST_MOTOR_ERROR, "r axis1.motor.error\n");
    }
  return;
}

if (completedRequest == REQUEST_MOTOR_ERROR) {
    sendToApp("MOTOR1_ERROR: " + response);
    beginODriveRequest(REQUEST_CONTROLLER_ERROR, "r axis1.controller.error\n");
    return;
  }
  if (completedRequest == REQUEST_CONTROLLER_ERROR) {
  sendToApp("CONTROLLER1_ERROR: " + response);
  sendToApp("NOT_READY: ODRIVE_ERROR");
  return;
}

if (completedRequest == REQUEST_MANUAL_POSITION) {
  char* endPointer = nullptr;
  float positionTurns = strtof(response.c_str(), &endPointer);

  if (endPointer == response.c_str() || *endPointer != '\0') {
    sendToApp("POSITION_ERROR: INVALID_RESPONSE");
    return;
  }

  sendToApp("POSITION_TURNS: " + String(positionTurns, 6));
  return;
}

if (completedRequest == REQUEST_TRAINING_FEEDBACK) {
  float positionTurns = 0.0f;
  float velocityTurnsPerSecond = 0.0f;

  int parsedValues = sscanf(
    response.c_str(),
    "%f %f",
    &positionTurns,
    &velocityTurnsPerSecond
  );

  if (parsedValues != 2) {
    sendToApp("FEEDBACK_ERROR: INVALID_RESPONSE");
    return;
  }

  float cablePositionCm =
    (positionTurns - savedStartPosition) *
    CABLE_CM_PER_TURN;

  float cableVelocityCmPerSecond =
    velocityTurnsPerSecond *
    CABLE_CM_PER_TURN;

  if (
    fabsf(cableVelocityCmPerSecond) <
    SPEED_DISPLAY_DEADBAND_CM_S
  ) {
    cableVelocityCmPerSecond = 0.0f;
  }
  latestCablePositionCm = cablePositionCm;
  latestCableVelocityCmPerSecond =
   cableVelocityCmPerSecond;
   latestFeedbackSequence++;

  sendToApp(
    "CABLE_FEEDBACK: " +
    String(cablePositionCm, 2) +
    "," +
    String(cableVelocityCmPerSecond, 2)
  );

  nextTrainingSpeedPollTime =
    millis() + TRAINING_SPEED_POLL_INTERVAL_MS;

  return;
}

if (completedRequest == REQUEST_TRAINING_POSITION) {
  char* endPointer = nullptr;
  float holdPosition = strtof(response.c_str(), &endPointer);

  if (endPointer == response.c_str() || *endPointer != '\0') {
    sendToApp("RESISTANCE_BLOCKED: INVALID_POSITION");
    return;
  }

  startTrainingAtPosition(holdPosition);
  return;
}

  if (completedRequest == REQUEST_RETURN_POSITION) {
  char* endPointer = nullptr;

  float currentPosition =
    strtof(response.c_str(), &endPointer);

  if (
    endPointer == response.c_str() ||
    *endPointer != '\0'
  ) {
    stopMotor(false);
    sendToApp("RETURN_STOPPED: INVALID_POSITION");
    return;
  }

  // Start position-control return, even when the first reading
  // appears close to the saved start position.
  if (!returnActive) {
    startReturnMotion();
    return;
  }

  float positionError =
    fabsf(currentPosition - savedStartPosition);

  if (
    positionError <=
    RETURN_POSITION_TOLERANCE_TURNS
  ) {
    if (!returnSettling) {
      returnSettling = true;
      returnSettleStartTime = millis();
    }
    else if (
      millis() - returnSettleStartTime >=
      RETURN_SETTLE_TIME_MS
    ) {
      stopMotor(false);
      sendToApp("RETURN_TO_START_COMPLETE");
      return;
    }
  }
  else {
    // The cable was pulled away again.
    // Continue holding the saved start and restart the timer.
    returnSettling = false;
    returnSettleStartTime = 0;
  }

  nextReturnPollTime =
    millis() + RETURN_POLL_INTERVAL_MS;
}
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    bluetoothConnected = true;
    safeJogAllowed = false;
    Serial.println("Bluetooth connected");
  }

  void onDisconnect(BLEServer* server) override {
    // A lost phone connection must never leave the motor enabled.
    stopMotor(false);
    bluetoothConnected = false;
    safeJogAllowed = false;
    pendingRequest = REQUEST_NONE;
    Serial.println("Bluetooth disconnected - motor stopped");
  }
};

class ReceiveCallbacks : public BLECharacteristicCallbacks {
  // Command-handling code
  public:
    void processCommand(String command) {
      command.trim();

    Serial.print("App command: ");
    Serial.println(command);

    bool isNextSetCommand = command.startsWith("NEXT_SET"); 
    if (
      (jogActive || trainingActive || returnActive) && command != "MOTOR_OFF" && command != "FINISH_SET" && !isNextSetCommand) {
      sendToApp("BLOCKED: MOTOR_ACTIVE");
      return;
    }

    if (command == "READ_VBUS") {
      requestBusVoltage();
    }
    else if (command == "READ_POSITION") {
      requestManualPosition();
    }
    else if (command == "READ_ERROR") {
      requestReadinessCheck();
    }
    else if (command == "CALIBRATE_AXIS1") {
      stopMotor(false);
      safeJogAllowed = false;
      savedStartPositionValid = false;
      pendingRequest = REQUEST_NONE;
      // Clear stored ODrive faults only after forcing Axis 1 to IDLE
      // This avoids requiring a full 24 V power cycle after a test fault
      ODriveSerial.print("sc\n");
      delay(100);
      // The jog temporarily lowers current_lim to 2 A. Restore the known Motor 1 calibration limit
      // before requesting full calibration
      ODriveSerial.print("w axis1.motor.config.current_lim 10.668\n");
      delay(20);
      ODriveSerial.print("w axis1.controller.input_vel 0\n");
      delay(10);
      ODriveSerial.print("w axis1.controller.input_torque 0\n");
      delay(10);
      ODriveSerial.print("w axis1.requested_state 3\n");
      sendToApp("CALIBRATION_STARTED");
  }
    else if (command == "JOG_FORWARD") {
      startSafeJog(SAFE_JOG_SPEED_TURNS_PER_SECOND);
    }
    else if (command == "JOG_REVERSE") {
      startSafeJog(-SAFE_JOG_SPEED_TURNS_PER_SECOND);
    }
    else if (command == "FINISH_SET") {
      stopMotor(false);
      delay(100);
      requestReturnToStart();
    }
    else if (command == "MOTOR_OFF") {
      stopMotor(true);
    }
    else if (command == "RETURN_TO_START") {
     requestReturnToStart();
  
  }

  else if (command.startsWith("NEXT_SET:")) {
  if (!trainingActive) {
    sendToApp("NEXT_SET_BLOCKED: MOTOR_NOT_ACTIVE");
    return;
  }

  float requestedKg = command.substring(9).toFloat();

  if (
    requestedKg < MIN_TRAINING_WEIGHT_KG ||
    requestedKg > MAX_TRAINING_WEIGHT_KG
  ) {
    sendToApp("NEXT_SET_BLOCKED: INVALID_WEIGHT");
    return;
  }

  selectedWeightKg = requestedKg;
  selectedCurrentLimitA =
    (requestedKg / 1.8f) - 0.6f;

  ODriveSerial.print(
    "w axis1.motor.config.current_lim "
  );
  ODriveSerial.print(selectedCurrentLimitA, 3);
  ODriveSerial.print("\n");

  sendToApp(
    "NEXT_SET_READY: " +
    String(selectedWeightKg, 1) +
    " KG"
  );
}

  else if (command.startsWith("SET_WORKOUT:")) {
    float requestedKg = command.substring(12).toFloat();

    if (
      requestedKg < MIN_TRAINING_WEIGHT_KG ||
      requestedKg > MAX_TRAINING_WEIGHT_KG
    ) {
      sendToApp("WORKOUT_BLOCKED: ALLOWED_RANGE_4_TO_30_KG");
    } else {
      // A new workout must capture its own cable start position.
      // Combining this reset with the weight change gives the website
      // one reliable, idempotent configuration request.
      savedStartPositionValid = false;
      selectedWeightKg = requestedKg;
      selectedCurrentLimitA =
        (requestedKg / 1.8f) - 0.6f;

      sendToApp(
        "WORKOUT_CONFIGURED: " +
        String(selectedWeightKg, 1) +
        " KG"
      );
    }
  }
  else if (command.startsWith("SET_KG:")) {
    float requestedKg = command.substring(7).toFloat();

     if (requestedKg < MIN_TRAINING_WEIGHT_KG || requestedKg > MAX_TRAINING_WEIGHT_KG) {
        sendToApp("WEIGHT_BLOCKED: ALLOWED_RANGE_4_TO_30_KG");
      } else {
        selectedWeightKg = requestedKg;
        selectedCurrentLimitA = (requestedKg / 1.8f) - 0.6f;
        sendToApp("WEIGHT_SET: " + String(selectedWeightKg, 1) + " KG");
    }
  }
  else if (command == "PING") {
      sendToApp("PONG");
    }
    else if (command == "SET_NEW_START") {
      savedStartPositionValid = false;
      sendToApp("NEW_START_READY: PRESS_START_TRAINING");
      }
    else if (command == "MOTOR_ON") {
      requestTrainingStart();
    }
    else {
      sendToApp("UNKNOWN_COMMAND");
    }
  }
    void onWrite(
      BLECharacteristic* characteristic
    ) override {
      String command =
        characteristic->getValue().c_str();

      processCommand(command);
  }
};
ReceiveCallbacks* receiveCallbacks = nullptr;

void serveWebFile(
  const char* path,
  const char* contentType
) {
  File file = LittleFS.open(path, "r");

  if (!file) {
    webServer.send(
      404,
      "text/plain",
      "Website file not found"
    );
    return;
  }

  webServer.streamFile(file, contentType);
  file.close();
}

void startWebServer() {
    if (!LittleFS.begin(false)) {
      Serial.println("LittleFS could not be mounted");
    } else {
      Serial.println("LittleFS ready");
    }
  // Wi-Fi server code
  WiFi.mode(WIFI_AP);

  bool accessPointStarted = WiFi.softAP(WIFI_AP_NAME);

  if (!accessPointStarted) {
    Serial.println("Wi-Fi access point failed");
    return;
  }

  webServer.on("/", HTTP_GET, []() {
  serveWebFile(
    "/index.html",
    "text/html"
  );
});

webServer.on("/style.css", HTTP_GET, []() {
  serveWebFile(
    "/style.css",
    "text/css"
  );
});

webServer.on("/app.js", HTTP_GET, []() {
  serveWebFile(
    "/app.js",
    "application/javascript"
  );
});

  webServer.on("/api/status", HTTP_GET, []() {
  String json = "{";

  json += "\"online\":true,";

  json += "\"trainingActive\":";
  json += (trainingActive ? "true" : "false");

  json += ",\"returnActive\":";
  json += (returnActive ? "true" : "false");

  json += ",\"ready\":";
  json += (safeJogAllowed ? "true" : "false");

  json += ",\"selectedWeightKg\":";
  json += String(selectedWeightKg, 1);

  json += ",\"cablePositionCm\":";
  json += String(latestCablePositionCm, 2);

  json += ",\"cableVelocityCmPerSecond\":";
  json += String(
    latestCableVelocityCmPerSecond,
    2
  );

  json += ",\"feedbackSequence\":";
  json += String(latestFeedbackSequence);

  json += ",\"message\":\"";
  json += latestDeviceMessage;
  json += "\"";

  json += "}";

  webServer.sendHeader(
    "Access-Control-Allow-Origin",
    "*"
  );

  webServer.send(
    200,
    "application/json",
    json
  );
  });

  webServer.on("/api/command", HTTP_OPTIONS, []() {
  webServer.sendHeader(
    "Access-Control-Allow-Origin",
    "*"
  );

  webServer.sendHeader(
    "Access-Control-Allow-Methods",
    "POST, OPTIONS"
  );

  webServer.sendHeader(
    "Access-Control-Allow-Headers",
    "Content-Type"
  );

  webServer.send(
    204,
    "text/plain",
    ""
  );
});

webServer.on("/api/command", HTTP_POST, []() {
  String command = webServer.arg("plain");
  command.trim();

  webServer.sendHeader(
    "Access-Control-Allow-Origin",
    "*"
  );

  if (command.length() == 0) {
    webServer.send(
      400,
      "application/json",
      "{\"accepted\":false,\"error\":\"EMPTY_COMMAND\"}"
    );
    return;
  }

  bool commandAllowed =
    command.startsWith("SET_WORKOUT:") ||
    command.startsWith("SET_KG:") ||
    command.startsWith("NEXT_SET:") ||
    command == "READ_ERROR" ||
    command == "CALIBRATE_AXIS1" ||
    command == "MOTOR_ON" ||
    command == "MOTOR_OFF" ||
    command == "FINISH_SET" ||
    command == "RETURN_TO_START" ||
    command == "SET_NEW_START" ||
    command == "PING";

  if (!commandAllowed) {
    webServer.send(
      403,
      "application/json",
      "{\"accepted\":false,\"error\":\"COMMAND_NOT_ALLOWED\"}"
    );
    return;
  }

  if (receiveCallbacks == nullptr) {
    webServer.send(
      503,
      "application/json",
      "{\"accepted\":false,\"error\":\"CONTROLLER_NOT_READY\"}"
    );
    return;
  }

  receiveCallbacks->processCommand(command);

  webServer.send(
    202,
    "application/json",
    "{\"accepted\":true}"
  );
});

  webServer.begin();

  Serial.print("POWER-CABLE Wi-Fi address: ");
  Serial.println(WiFi.softAPIP());
}

void setup() {
  // Setup code
  Serial.begin(115200);
  delay(1000);

  Serial.println();
  Serial.println("Starting safe ODrive jog test");

  ODriveSerial.begin(
    115200,
    SERIAL_8N1,
    ODRIVE_RX_PIN,
    ODRIVE_TX_PIN
  );

 // Force a safe state whenever the ESP32 restarts.
  stopMotor(false);

  BLEDevice::init("WeightLifting");

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);

  txCharacteristic = service->createCharacteristic(
    TX_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_NOTIFY);
  txCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic* rxCharacteristic =
    service->createCharacteristic(
      RX_CHARACTERISTIC,
      BLECharacteristic::PROPERTY_WRITE);
  receiveCallbacks = new ReceiveCallbacks();

  rxCharacteristic->setCallbacks(receiveCallbacks);

  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();
  startWebServer();

  Serial.println("Bluetooth ready");
  Serial.println("Waiting for the WeightLifting app");
}

void loop() {
  webServer.handleClient();
  // Hard time limit for every jog, independent of the phone connection.
  if (jogActive && millis() - jogStartTime >= SAFE_JOG_TIME_MS) {
    stopMotor(true);
  }

  if (trainingActive && millis() - trainingStartTime >= TRAINING_TIME_LIMIT_MS) {
  stopMotor(false);
  sendToApp("TRAINING_STOPPED: TIME_LIMIT");
  }

  if (trainingActive && pendingRequest == REQUEST_NONE && millis() >= nextTrainingSpeedPollTime) {
    beginODriveRequest(REQUEST_TRAINING_FEEDBACK, "f 1\n");
  }

  if (returnActive) {
    if (millis() - returnStartTime >= RETURN_TIMEOUT_MS) {
      stopMotor(false);
      sendToApp("RETURN_STOPPED: TIMEOUT");
    }
    else if (pendingRequest == REQUEST_NONE && millis() >= nextReturnPollTime) {
      beginODriveRequest(REQUEST_RETURN_POSITION, "r axis1.encoder.pos_estimate\n");
    }
  }

 if (pendingRequest != REQUEST_NONE) {
    while (ODriveSerial.available()) {
      char receivedCharacter = ODriveSerial.read();

      if (receivedCharacter == '\n') {
        odriveResponse.trim();
        if (odriveResponse.length() > 0) {
          String completedResponse = odriveResponse;
          odriveResponse = "";
          handleODriveResponse(completedResponse);
        }
      }
      else if (receivedCharacter != '\r') {
        if (odriveResponse.length() < 64) {
          odriveResponse += receivedCharacter;
        }
      }
    }

    if (pendingRequest != REQUEST_NONE && millis() - requestStartTime > ODRIVE_REPLY_TIMEOUT_MS) {
      pendingRequest = REQUEST_NONE;
      safeJogAllowed = false;
      if (returnActive || jogActive || trainingActive) {
        stopMotor(false);
      }
      sendToApp("ODRIVE_TIMEOUT");
    }
  }

  if (!bluetoothConnected && previousConnection) {
    delay(500);
    bleServer->startAdvertising();
    Serial.println("Bluetooth advertising restarted");
    previousConnection = false;
  }

  if (bluetoothConnected && !previousConnection) {
    previousConnection = true;
  }

  delay(10);
}
