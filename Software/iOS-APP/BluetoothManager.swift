//  BluetoothManager.swift
//  Weightlifting

import Foundation
import Combine
import CoreBluetooth
// feedback
import AVFoundation
import UIKit

struct RepetitionMetric: Identifiable {
    let id = UUID()
    let number: Int
    let rangeOfMotionCm: Double
    let meanPullSpeedCmPerSecond: Double
    let peakPullSpeedCmPerSecond: Double
}
struct SetResult: Identifiable {
    let id = UUID()
    let setNumber: Int
    let weightKg: Double
    let completedRepetitions: Int
    let partialRepetitions: Int
    let velocityLossPercent: Double
    let recommendedNextWeightKg: Double
    let durationSeconds: Double
}

final class BluetoothManager: NSObject, ObservableObject {
    @Published var status = "Bluetooth disconnected"
    @Published var isConnected = false
    @Published var receivedText = ""
    @Published var cableSpeedCmPerSecond = 0.0
    @Published var peakCableSpeedCmPerSecond = 0.0
    @Published var trainingDurationSeconds = 0.0
    @Published var isTraining = false
    @Published var cablePositionCm = 0.0
    @Published var repetitionCount = 0
    @Published var partialRepetitionCount = 0
    @Published var repetitionStatus = "Ready"
    @Published private(set) var repetitionMetrics: [RepetitionMetric] = []
    @Published private(set) var recommendedWeightKg: Double?
    @Published private(set) var velocityLossPercent = 0.0
    @Published private(set) var adaptationReason = ""
    @Published private(set) var setResults: [SetResult] = []
    @Published private(set) var currentSetNumber = 1
    @Published private(set) var targetSetCount = 1
    @Published private(set) var sessionIsComplete = false
    @Published private(set) var isWaitingForNextSet = false

    private var centralManager: CBCentralManager!
    private var esp32: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var trainingTimer: Timer?
    private var trainingStartDate: Date?
    private enum RepetitionPhase {
        case waiting
        case pulling
        case returning
    }
    
    private var repetitionPhase: RepetitionPhase = .waiting
    private var maximumCablePositionCm = 0.0
    private var repetitionStartPositionCm = 0.0
    private var pullSpeedSum = 0.0
    private var pullSpeedSampleCount = 0
    private var currentRepPeakPullSpeed = 0.0
    
    private let movementThresholdCmPerSecond = 2.0
    private let minimumRepetitionDistanceCm = 10.0
    private let requiredReturnPercentage = 0.85
    private let startPositionToleranceCm = 2.5
    
    private var currentSetWeightKg = 4.0
    private var targetRepetitions = 10
    private var setHasBeenEvaluated = false
    
    private var startTrainingAfterWeightConfirmation = false
    private var pendingNextSetWeightKg: Double?
    private var pendingNextSetRepetitions: Int?
    
    private let serviceUUID =
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    private let rxUUID =
        CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    private let txUUID =
        CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()

            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )

            try audioSession.setActive(true)
        } catch {
            print("Audio feedback setup failed: \(error)")
        }
    }

    override init() {
        super.init()
        
        configureAudioSession()

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil
        )
    }
    

    func connect() {
        guard centralManager.state == .poweredOn else {
            status = "Please switch Bluetooth on"
            return
        }

        status = "Searching for WeightLifting device..."

        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: nil
        )
    }

    func disconnect() {
        if let esp32 {
            centralManager.cancelPeripheralConnection(esp32)
        }
    }

    func send(_ message: String) {
        guard let esp32,
              let writeCharacteristic else {
            status = "Device is not connected"
            return
        }

        let text = message + "\n"

        guard let data = text.data(using: .utf8) else {
            return
        }

        let writeType: CBCharacteristicWriteType =
            writeCharacteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse

        esp32.writeValue(
            data,
            for: writeCharacteristic,
            type: writeType
        )
    }
    
    func prepareAdaptiveSet(
        weightKg: Double,
        targetRepetitions: Int
    ) {
        currentSetWeightKg = weightKg
        self.targetRepetitions = targetRepetitions
        setHasBeenEvaluated = false

        recommendedWeightKg = nil
        velocityLossPercent = 0.0
        adaptationReason = ""

        resetRepetitionTracking()
    }
    
    func startAdaptiveSet(
        weightKg: Double,
        targetRepetitions: Int,
        targetSets: Int
    ) {
        let selectedSetCount = max(1, targetSets)

        if sessionIsComplete {
            setResults.removeAll()
            currentSetNumber = 1
            targetSetCount = selectedSetCount
            sessionIsComplete = false

        } else if setResults.isEmpty {
            currentSetNumber = 1
            targetSetCount = selectedSetCount

        } else if setHasBeenEvaluated {
            currentSetNumber = min(
                setResults.count + 1,
                targetSetCount
            )
        }

        prepareAdaptiveSet(
            weightKg: weightKg,
            targetRepetitions: targetRepetitions
        )

        startTrainingAfterWeightConfirmation = true
        send("SET_KG:\(weightKg)")
    }
    
    func startNextSet(
        weightKg: Double,
        targetRepetitions: Int
    ) {
        guard isWaitingForNextSet,
              !sessionIsComplete
        else {
            return
        }

        guard abs(cablePositionCm) <= startPositionToleranceCm,
              cableSpeedCmPerSecond <= movementThresholdCmPerSecond
        else {
            repetitionStatus =
                "Return the handle before starting the next set"
            return
        }

        pendingNextSetWeightKg = weightKg
        pendingNextSetRepetitions = targetRepetitions

        send("NEXT_SET:\(weightKg)")
    }
    private func startTrainingTimer() {
        trainingTimer?.invalidate()

        trainingStartDate = Date()
        trainingDurationSeconds = 0.0
        isTraining = true

        trainingTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            guard let self,
                  let startDate = self.trainingStartDate
            else {
                return
            }

            self.trainingDurationSeconds =
                Date().timeIntervalSince(startDate)
        }
    }

    private func stopTrainingTimer() {
        if let startDate = trainingStartDate {
            trainingDurationSeconds =
                Date().timeIntervalSince(startDate)
        }

        trainingTimer?.invalidate()
        trainingTimer = nil
        trainingStartDate = nil
        isTraining = false
    }
    private func resetRepetitionTracking() {
        repetitionCount = 0
        partialRepetitionCount = 0
        repetitionStatus = "Ready"
        repetitionPhase = .waiting
        maximumCablePositionCm = 0.0
        cablePositionCm = 0.0
        repetitionStartPositionCm = 0.0
        
        repetitionMetrics.removeAll()
        pullSpeedSum = 0.0
        pullSpeedSampleCount = 0
        currentRepPeakPullSpeed = 0.0
    }
    
    private func evaluateSetIfReady() {
        guard !setHasBeenEvaluated,
              repetitionCount >= targetRepetitions,
              repetitionMetrics.count >= targetRepetitions
        else {
            return
        }

        let completedRepetitions = Array(
            repetitionMetrics.prefix(targetRepetitions)
        )

        let baselineCount = min(2, completedRepetitions.count)

        let baselineSpeed =
            completedRepetitions
                .prefix(baselineCount)
                .map(\.meanPullSpeedCmPerSecond)
                .reduce(0.0, +)
            / Double(baselineCount)

        let baselineRange =
            completedRepetitions
                .prefix(baselineCount)
                .map(\.rangeOfMotionCm)
                .reduce(0.0, +)
            / Double(baselineCount)

        guard let finalRepetition = completedRepetitions.last,
              baselineSpeed > 0.0
        else {
            return
        }

        velocityLossPercent = max(
            0.0,
            (baselineSpeed - finalRepetition.meanPullSpeedCmPerSecond)
                / baselineSpeed * 100.0
        )

        let insufficientRange =
            finalRepetition.rangeOfMotionCm < baselineRange * 0.85

        if partialRepetitionCount > 0 ||
            insufficientRange ||
            velocityLossPercent > 35.0 {

            recommendedWeightKg = max(
                4.0,
                currentSetWeightKg - 0.5
            )

            adaptationReason =
                "High fatigue or incomplete movement"

        } else if velocityLossPercent < 20.0 {
            recommendedWeightKg = min(
                30.0,
                currentSetWeightKg + 0.5
            )

            adaptationReason =
                "Strong performance with low speed loss"

        } else {
            recommendedWeightKg = currentSetWeightKg
            adaptationReason =
                "Appropriate fatigue for this resistance"
        }

        let nextWeight =
            recommendedWeightKg ?? currentSetWeightKg

        let completedSet = SetResult(
            setNumber: currentSetNumber,
            weightKg: currentSetWeightKg,
            completedRepetitions: repetitionCount,
            partialRepetitions: partialRepetitionCount,
            velocityLossPercent: velocityLossPercent,
            recommendedNextWeightKg: nextWeight,
            durationSeconds: trainingDurationSeconds
        )

        setResults.append(completedSet)
        setHasBeenEvaluated = true

        if currentSetNumber >= targetSetCount {
            sessionIsComplete = true
            isWaitingForNextSet = false
            repetitionStatus = "Workout complete"
        } else {
            isWaitingForNextSet = true
            repetitionStatus =
                "Set \(currentSetNumber) of \(targetSetCount) complete"
        }

        stopTrainingTimer()

        // Keep resistance active after the final repetition.
        // The user must return and release the handle before stopping.
    }
    
    private func announceRepetitionProgress() {
        let repetitionsRemaining =
            targetRepetitions - repetitionCount

        let spokenMessage: String

        if repetitionsRemaining <= 0 {
            if currentSetNumber >= targetSetCount {
                spokenMessage = "Workout complete. Return the handle."
            } else {
                spokenMessage = "Set \(currentSetNumber) of \(targetSetCount) complete. Return the handle."
            }

            UINotificationFeedbackGenerator()
                .notificationOccurred(.success)

        } else if repetitionsRemaining == 1 {
            spokenMessage = "Last repetition"

            UIImpactFeedbackGenerator(style: .heavy)
                .impactOccurred()

        } else if repetitionsRemaining == 2 {
            spokenMessage = "Two repetitions remaining"

            UIImpactFeedbackGenerator(style: .medium)
                .impactOccurred()

        } else {
            spokenMessage = "\(repetitionCount)"

            UIImpactFeedbackGenerator(style: .light)
                .impactOccurred()
        }

        speechSynthesizer.stopSpeaking(at: .immediate)

        let announcement = AVSpeechUtterance(
            string: spokenMessage
        )
        
        announcement.voice =
            AVSpeechSynthesisVoice(language: "en-GB")
        
        announcement.rate = 0.5
        announcement.volume = 1.0

        speechSynthesizer.speak(announcement)
    }
    
    private func processCableFeedback(
        positionCm: Double,
        velocityCmPerSecond: Double
    ) {
        cablePositionCm = positionCm

        let absoluteSpeed = abs(velocityCmPerSecond)
        cableSpeedCmPerSecond = absoluteSpeed

        if absoluteSpeed > peakCableSpeedCmPerSecond {
            peakCableSpeedCmPerSecond = absoluteSpeed
        }
        
        if setHasBeenEvaluated {
            return
        }

        switch repetitionPhase {
        case .waiting:
            if velocityCmPerSecond >
                movementThresholdCmPerSecond {
                repetitionStartPositionCm = positionCm
                maximumCablePositionCm = positionCm
                pullSpeedSum = velocityCmPerSecond
                pullSpeedSampleCount = 1
                currentRepPeakPullSpeed = velocityCmPerSecond
                repetitionPhase = .pulling
                repetitionStatus = "Pulling"
            }

        case .pulling:
            maximumCablePositionCm = max(maximumCablePositionCm,positionCm)
            if velocityCmPerSecond > 0 {
                pullSpeedSum += velocityCmPerSecond
                pullSpeedSampleCount += 1
                currentRepPeakPullSpeed = max(
                    currentRepPeakPullSpeed,
                    velocityCmPerSecond
                )
            }

            if velocityCmPerSecond <
                -movementThresholdCmPerSecond {
                repetitionPhase = .returning
                repetitionStatus = "Returning"
            }

        case .returning:
            let repetitionDistance = max(0.0,
                maximumCablePositionCm - repetitionStartPositionCm)
            
            let returnTolerance = max(startPositionToleranceCm, repetitionDistance * (1.0 - requiredReturnPercentage))
                                      
            let acceptedReturnPosition = repetitionStartPositionCm + returnTolerance

            if positionCm <= acceptedReturnPosition {
                if repetitionDistance >= minimumRepetitionDistanceCm {
                    repetitionCount += 1

                    let meanPullSpeed =
                        pullSpeedSampleCount > 0
                        ? pullSpeedSum / Double(pullSpeedSampleCount)
                        : 0.0

                    let metric = RepetitionMetric(
                        number: repetitionCount,
                        rangeOfMotionCm: repetitionDistance,
                        meanPullSpeedCmPerSecond: meanPullSpeed,
                        peakPullSpeedCmPerSecond: currentRepPeakPullSpeed
                    )

                    repetitionMetrics.append(metric)
                    announceRepetitionProgress()
                    evaluateSetIfReady()

                    if !setHasBeenEvaluated {
                        repetitionStatus = "Full rep \(repetitionCount)"
                    }
                } else {
                    partialRepetitionCount += 1
                    repetitionStatus = "Partial: movement too short"
                }

                repetitionPhase = .waiting
                repetitionStartPositionCm = positionCm
                maximumCablePositionCm = positionCm
                pullSpeedSum = 0.0
                pullSpeedSampleCount = 0
                currentRepPeakPullSpeed = 0.0

            } else if velocityCmPerSecond >
                        movementThresholdCmPerSecond {

                partialRepetitionCount += 1
                repetitionStatus = "Partial: return farther"

                repetitionStartPositionCm = positionCm
                maximumCablePositionCm = positionCm
                pullSpeedSum = velocityCmPerSecond
                pullSpeedSampleCount = 1
                currentRepPeakPullSpeed = velocityCmPerSecond
                repetitionPhase = .pulling
            }
        }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(
        _ central: CBCentralManager
    ) {
        switch central.state {
        case .poweredOn:
            status = "Bluetooth ready"

        case .poweredOff:
            status = "Bluetooth is switched off"

        case .unauthorized:
            status = "Bluetooth permission is required"

        case .unsupported:
            status = "Bluetooth is not supported"

        default:
            status = "Bluetooth unavailable"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()

        esp32 = peripheral
        peripheral.delegate = self

        status = "Connecting..."
        central.connect(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        status = "Finding Bluetooth controls..."
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        status = "Connection failed"
        isConnected = false
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        status = "Bluetooth disconnected"
        isConnected = false
        writeCharacteristic = nil
        stopTrainingTimer()
        cableSpeedCmPerSecond = 0.0
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard error == nil else {
            status = "Could not read Bluetooth service"
            return
        }

        peripheral.services?.forEach { service in
            if service.uuid == serviceUUID {
                peripheral.discoverCharacteristics(
                    [rxUUID, txUUID],
                    for: service
                )
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            status = "Could not read Bluetooth controls"
            return
        }

        service.characteristics?.forEach { characteristic in
            if characteristic.uuid == rxUUID {
                writeCharacteristic = characteristic
            }

            if characteristic.uuid == txUUID {
                peripheral.setNotifyValue(
                    true,
                    for: characteristic
                )
            }
        }

        if writeCharacteristic != nil {
            status = "Connected to WeightLifting"
            isConnected = true
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              let data = characteristic.value,
              let message = String(data: data, encoding: .utf8)
        else {
            return
        }

        let cleanMessage = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        receivedText = cleanMessage
        if cleanMessage.hasPrefix("WEIGHT_SET:"),
           startTrainingAfterWeightConfirmation {

            startTrainingAfterWeightConfirmation = false
            send("MOTOR_ON")
        }
        
        if cleanMessage.hasPrefix("NEXT_SET_READY:"),
           let nextWeight = pendingNextSetWeightKg,
           let nextRepetitions = pendingNextSetRepetitions {

            currentSetNumber = min(
                setResults.count + 1,
                targetSetCount
            )

            prepareAdaptiveSet(
                weightKg: nextWeight,
                targetRepetitions: nextRepetitions
            )

            isWaitingForNextSet = false
            pendingNextSetWeightKg = nil
            pendingNextSetRepetitions = nil

            repetitionStatus =
                "Set \(currentSetNumber) of \(targetSetCount)"

            startTrainingTimer()
        }

        if cleanMessage.hasPrefix("NEXT_SET_BLOCKED:") {
            pendingNextSetWeightKg = nil
            pendingNextSetRepetitions = nil
            repetitionStatus = cleanMessage
        }

        if cleanMessage.hasPrefix("WEIGHT_BLOCKED:") {
            startTrainingAfterWeightConfirmation = false
        }

        let speedPrefix = "CABLE_SPEED_CM_S:"

        if cleanMessage.hasPrefix(speedPrefix) {
            let valueText = cleanMessage
                .dropFirst(speedPrefix.count)
                .trimmingCharacters(in: .whitespaces)

            if let speed = Double(valueText) {
                cableSpeedCmPerSecond = speed
                if speed > peakCableSpeedCmPerSecond {
                    peakCableSpeedCmPerSecond = speed
                }
            }
        }
        
        let feedbackPrefix = "CABLE_FEEDBACK:"

        if cleanMessage.hasPrefix(feedbackPrefix) {
            let feedbackText = cleanMessage
                .dropFirst(feedbackPrefix.count)

            let values = feedbackText.split(
                separator: ",",
                maxSplits: 1
            )

            if values.count == 2 {
                let positionText = values[0]
                    .trimmingCharacters(in: .whitespaces)

                let velocityText = values[1]
                    .trimmingCharacters(in: .whitespaces)

                if let position = Double(positionText),
                   let velocity = Double(velocityText) {
                    processCableFeedback(
                        positionCm: position,
                        velocityCmPerSecond: velocity
                    )
                }
            }
        }

        if cleanMessage.hasPrefix("TRAINING_STARTED:") {
            cableSpeedCmPerSecond = 0.0
            peakCableSpeedCmPerSecond = 0.0
            resetRepetitionTracking()
            startTrainingTimer()
        }
        if cleanMessage == "MOTOR_STOPPED" ||
            cleanMessage.hasPrefix("TRAINING_STOPPED") {

            cableSpeedCmPerSecond = 0.0
            stopTrainingTimer()
        }
    }
}
//  Created by Yunus Sahin on 2026-09-22.
//

