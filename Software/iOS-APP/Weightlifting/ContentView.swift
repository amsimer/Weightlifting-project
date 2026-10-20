import SwiftUI

struct ContentView: View {
    @StateObject private var bluetooth = BluetoothManager()
    @State private var selectedWeight = 4.0
    @State private var targetRepetitions = 10
    @State private var targetSets = 4
    @State private var showCalibrationWarning = false
    @State private var showReturnWarning = false
    @State private var showTrainingWarning = false
    @State private var showSetupControls = false
    @State private var showSetHistory = false
    
    var body: some View {
        ScrollView{
            VStack(spacing: 20) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 55))
                    .foregroundStyle(.blue)
                
                Text("WeightLifting")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text(bluetooth.status)
                    .foregroundStyle(
                        bluetooth.isConnected ? .green : .secondary)
                
                Button(bluetooth.isConnected ? "Disconnect" : "Connect") {
                    if bluetooth.isConnected {
                        bluetooth.disconnect()
                    } else {
                        bluetooth.connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                
                DisclosureGroup(
                    "Setup & Diagnostics",
                    isExpanded: $showSetupControls
                ) {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Button("Check Calibration") {
                                bluetooth.send("READ_ERROR")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(!bluetooth.isConnected)
                            
                            Button("Calibrate Motor") {
                                showCalibrationWarning = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(!bluetooth.isConnected)
                            .alert(
                                "Start Motor calibration?",
                                isPresented: $showCalibrationWarning
                            ) {
                                Button("Cancel", role: .cancel) {}
                                
                                Button("Start Calibration", role: .destructive) {
                                    bluetooth.send("CALIBRATE_AXIS1")
                                }
                            } message: {
                                Text("The motor will move. Remove all weight and keep everyone away from the cable.")
                            }
                        }
                        
                        Button("Read Position") {
                            bluetooth.send("READ_POSITION")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(!bluetooth.isConnected)
                        
                        Text("Calibration moves the motor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !bluetooth.receivedText.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Latest Device Message")
                                    .font(.caption)
                                    .fontWeight(.semibold)

                                Text(bluetooth.receivedText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 8)
                }
                .tint(.blue)
                
                Divider()
                
                VStack(spacing: 12) {
                    Text("Selected Weight")
                        .font(.headline)
                    
                    Text("\(selectedWeight, specifier: "%.1f") kg")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.blue)
                    
                    Slider(value: $selectedWeight, in: 4...30, step: 0.5)
                    Stepper("Target repetitions: \(targetRepetitions)",
                        value: $targetRepetitions,
                        in: 3...20)
                    Stepper(
                        "Target sets: \(targetSets)",
                        value: $targetSets,
                        in: 1...20)
                    
                    HStack {
                        Text("4 kg")
                        Spacer()
                        Text("30 kg")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    
                    Button("Set Weight") {
                        bluetooth.send(
                            "SET_KG:\(selectedWeight)"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!bluetooth.isConnected)
                }
                
                VStack(spacing: 12) {
                    Text("Training Controls")
                        .font(.headline)
                    if bluetooth.isTraining || !bluetooth.setResults.isEmpty {
                        HStack {
                            Label(
                                "Set \(bluetooth.currentSetNumber) of \(bluetooth.targetSetCount)",
                                systemImage: "list.number"
                            )

                            Spacer()

                            Text(
                                "\(bluetooth.repetitionCount) / \(targetRepetitions) reps"
                            )
                        }
                        .font(.subheadline)
                        .padding(10)
                        .background(
                            Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    
                    HStack(spacing: 12) {
                        VStack(spacing: 4) {
                            Text("Live Speed")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(
                                "\(bluetooth.cableSpeedCmPerSecond, specifier: "%.1f")"
                            )
                            .font(.system(size: 24, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.blue)

                            Text("cm/s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                            .frame(height: 55)

                        VStack(spacing: 4) {
                            Text("Peak Speed")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(
                                "\(bluetooth.peakCableSpeedCmPerSecond, specifier: "%.1f")"
                            )
                            .font(.system(size: 24, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.green)

                            Text("cm/s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                            .frame(height: 55)

                        VStack(spacing: 4) {
                            Text("Set Time")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Text(
                                "\(bluetooth.trainingDurationSeconds, specifier: "%.1f")"
                            )
                            .font(.system(size: 24, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(
                                bluetooth.isTraining ? .orange : .primary
                            )
                            
                            Text("seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        }
                        
                        HStack(spacing: 12) {
                            Label(
                                "\(bluetooth.repetitionCount) reps",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)

                            if bluetooth.partialRepetitionCount > 0 {
                                Label(
                                    "\(bluetooth.partialRepetitionCount) partial",
                                    systemImage: "exclamationmark.circle.fill"
                                )
                                .foregroundStyle(.orange)
                            }

                            Spacer()

                            Text(bluetooth.repetitionStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            
                        }
                        .font(.subheadline)
                        .padding(10)
                        .background(
                            Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    
                    if let lastRep = bluetooth.repetitionMetrics.last {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Last Repetition")
                                .font(.headline)

                            Text(
                                "Range: \(lastRep.rangeOfMotionCm, specifier: "%.1f") cm"
                            )

                            Text(
                                "Average speed: \(lastRep.meanPullSpeedCmPerSecond, specifier: "%.1f") cm/s"
                            )

                            Text(
                                "Peak speed: \(lastRep.peakPullSpeedCmPerSecond, specifier: "%.1f") cm/s"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color.blue.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    if let recommendedWeight = bluetooth.recommendedWeightKg {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Next Set Recommendation")
                                .font(.headline)

                            Text("\(recommendedWeight, specifier: "%.1f") kg")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.blue)

                            Text(
                                "Velocity loss: \(bluetooth.velocityLossPercent, specifier: "%.1f")%"
                            )

                            Text(bluetooth.adaptationReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color.green.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    
                    if !bluetooth.setResults.isEmpty {
                        SetHistoryView(
                            results: bluetooth.setResults,
                            targetSetCount: bluetooth.targetSetCount,
                            isExpanded: $showSetHistory
                        )
                    }
                    
                    if bluetooth.isWaitingForNextSet {
                        Button {
                            let nextWeight =
                                bluetooth.recommendedWeightKg ?? selectedWeight

                            selectedWeight = nextWeight

                            bluetooth.startNextSet(
                                weightKg: nextWeight,
                                targetRepetitions: targetRepetitions
                            )
                        } label: {
                            Label(
                                "Start Set \(bluetooth.currentSetNumber + 1)",
                                systemImage: "play.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(
                            !bluetooth.isConnected ||
                            abs(bluetooth.cablePositionCm) > 2.5 ||
                            bluetooth.cableSpeedCmPerSecond > 2.0
                        )

                        if abs(bluetooth.cablePositionCm) > 2.5 ||
                            bluetooth.cableSpeedCmPerSecond > 2.0 {

                            Text("Return the handle to enable the next set")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    
                    HStack(spacing: 16) {
                        Button("Start Training") {
                            showTrainingWarning = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!bluetooth.isConnected)
                        .alert(
                            "Start training?",
                            isPresented: $showTrainingWarning
                        ) {
                            Button("Cancel", role: .cancel) {}
                            
                            Button("Start") {
                                bluetooth.startAdaptiveSet(
                                    weightKg: selectedWeight,
                                    targetRepetitions: targetRepetitions,
                                    targetSets: targetSets)
                            }
                            } message: {
                                Text(
                                    "The motor will create resistance. Hold the handle securely and keep everyone away from the spool."
                                )
                            }
                        Button("Stop Motor") {
                            bluetooth.send("MOTOR_OFF")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!bluetooth.isConnected)
                    }
                    
                    Button("Return Cable") {
                        showReturnWarning = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!bluetooth.isConnected)
                    .alert(
                        "Return cable to the starting position?",
                        isPresented: $showReturnWarning
                    ) {
                        Button("Cancel", role: .cancel) {}
                        
                        Button("Return Cable", role: .destructive) {
                            bluetooth.send("RETURN_TO_START")
                        }
                    } message: {
                        Text(
                            "The motor and handle will move. Hold the handle securely and keep everyone away from the spool.")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: bluetooth.recommendedWeightKg) { _, newWeight in
            if let newWeight {
                selectedWeight = newWeight
            }
        }
    }
}

private struct SetHistoryView: View {
    let results: [SetResult]
    let targetSetCount: Int
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(
            "Set History (\(results.count)/\(targetSetCount))",
            isExpanded: $isExpanded
        ) {
            VStack(spacing: 8) {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Set \(result.setNumber)")
                                .fontWeight(.semibold)

                            Spacer()

                            Text(
                                "\(result.weightKg, specifier: "%.1f") kg"
                            )
                        }

                        HStack {
                            Text(
                                "\(result.completedRepetitions) reps"
                            )

                            if result.partialRepetitions > 0 {
                                Text(
                                    "• \(result.partialRepetitions) partial"
                                )
                                .foregroundStyle(.orange)
                            }

                            Spacer()

                            Text(
                                "Loss \(result.velocityLossPercent, specifier: "%.1f")%"
                            )
                        }
                        .font(.caption)

                        Text(
                            "Next: \(result.recommendedNextWeightKg, specifier: "%.1f") kg • \(result.durationSeconds, specifier: "%.1f") s"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .background(
            Color.secondary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}

#Preview {
    ContentView()
}
