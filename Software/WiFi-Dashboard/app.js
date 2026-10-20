// MARK: - ESP32 connection

const DEVICE_BASE_URL =
    window.location.hostname === "192.168.4.1"
        ? ""
        : "http://192.168.4.1";

const STATUS_INTERVAL_MS = 1000;
const REQUEST_TIMEOUT_MS = 5000;


// MARK: - Repetition thresholds copied from the iOS app

const MOVEMENT_THRESHOLD_CM_S = 2.0;
const MINIMUM_REPETITION_DISTANCE_CM = 10.0;
const REQUIRED_RETURN_PERCENTAGE = 0.85;
const START_POSITION_TOLERANCE_CM = 2.5;


// MARK: - Interface elements

const weightRange = document.getElementById("weightRange");
const weightOutput = document.getElementById("weightOutput");

const targetRepsInput = document.getElementById("targetReps");
const targetSetsInput = document.getElementById("targetSets");

const connectButton = document.getElementById("connectButton");
const setWeightButton = document.getElementById("setWeightButton");
const startTrainingButton =
    document.getElementById("startTrainingButton");
const nextSetButton = document.getElementById("nextSetButton");
const stopMotorButton = document.getElementById("stopMotorButton");
const returnCableButton =
    document.getElementById("returnCableButton");

const connectionStatus =
    document.getElementById("connectionStatus");
const trainingState = document.getElementById("trainingState");
const deviceMessage = document.getElementById("deviceMessage");

const setProgress = document.getElementById("setProgress");
const repProgress = document.getElementById("repProgress");
const repProgressBar = document.getElementById("repProgressBar");

const liveSpeed = document.getElementById("liveSpeed");
const peakSpeed = document.getElementById("peakSpeed");
const setTime = document.getElementById("setTime");
const completedRepsDisplay =
    document.getElementById("completedReps");

const lastRange = document.getElementById("lastRange");
const averageSpeed = document.getElementById("averageSpeed");
const lastPeakSpeed = document.getElementById("lastPeakSpeed");

const recommendedWeight =
    document.getElementById("recommendedWeight");
const velocityLoss = document.getElementById("velocityLoss");
const recommendationReason =
    document.getElementById("recommendationReason");

const speedChart = document.getElementById("speedChart");
const chartContext = speedChart.getContext("2d");


// MARK: - Workout state

const workout = {
    connected: false,
    configured: false,
    training: false,
    awaitingReturn: false,

    weightKg: 8,
    targetReps: 10,
    targetSets: 4,

    currentSet: 1,
    completedReps: 0,
    partialReps: 0,

    liveSpeed: 0,
    peakSpeed: 0,
    elapsedSeconds: 0,

    phase: "waiting",
    repetitionStartPositionCm: 0,
    maximumCablePositionCm: 0,
    pullSpeedSum: 0,
    pullSpeedSampleCount: 0,
    currentRepPeakSpeed: 0,

    repetitionMetrics: [],
    recommendedWeightKg: 8,
    velocityLossPercent: 0,

    lastFeedbackSequence: -1
};

const speedHistory = new Array(80).fill(0);

let statusTimer = null;
let statusRequestActive = false;
let consecutiveConnectionFailures = 0;
let trainingStartTime = null;
let calibrationInProgress = false;
let configurationInProgress = false;


// MARK: - Formatting

function formatNumber(value, digits = 1) {
    return Number(value).toLocaleString(undefined, {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits
    });
}

function formatWeight(value) {
    return `${formatNumber(value)} kg`;
}


// MARK: - HTTP communication

async function fetchWithTimeout(path, options = {}) {
    const controller = new AbortController();

    const timeout = window.setTimeout(function () {
        controller.abort();
    }, REQUEST_TIMEOUT_MS);

    try {
        const response = await fetch(
            `${DEVICE_BASE_URL}${path}`,
            {
                ...options,
                signal: controller.signal
            }
        );

        if (!response.ok) {
            throw new Error(
                `HTTP ${response.status}`
            );
        }

        return response;
    } finally {
        window.clearTimeout(timeout);
    }
}

async function readDeviceStatus() {
    const response = await fetchWithTimeout(
        "/api/status"
    );

    return response.json();
}

async function sendCommand(command) {
    const response = await fetchWithTimeout(
        "/api/command",
        {
            method: "POST",
            headers: {
                "Content-Type": "text/plain"
            },
            body: command
        }
    );

    return response.json();
}

function wait(milliseconds) {
    return new Promise(function (resolve) {
        window.setTimeout(resolve, milliseconds);
    });
}

async function sendConfigurationCommand(command) {
    let lastError = null;

    for (let attempt = 1; attempt <= 4; attempt += 1) {
        try {
            return await sendCommand(command);
        } catch (error) {
            lastError = error;

            setDeviceMessage(
                `Applying workout settings… ${attempt}/4`
            );

            await wait(750);
        }
    }

    throw lastError || new Error("Configuration failed");
}


// MARK: - Connection

connectButton.addEventListener("click", async function () {
    if (workout.connected) {
        if (workout.training) {
            try {
                await sendCommand("MOTOR_OFF");
            } catch (error) {
                console.error(error);
            }
        }

        disconnectLocally();
        return;
    }

    connectionStatus.textContent = "Connecting…";
    connectButton.disabled = true;
    setDeviceMessage("Connecting to 192.168.4.1");

    try {
        let status = null;
        let lastError = null;

        for (let attempt = 1; attempt <= 5; attempt += 1) {
            try {
                status = await readDeviceStatus();
                break;
            } catch (error) {
                lastError = error;
                connectionStatus.textContent =
                    `Connecting… attempt ${attempt} of 5`;

                await new Promise(function (resolve) {
                    window.setTimeout(resolve, 1000);
                });
            }
        }

        if (!status) {
            throw lastError;
        }

        workout.connected = true;
        consecutiveConnectionFailures = 0;

        updateConnectionInterface();
        applyDeviceStatus(status);
        startStatusPolling();

        // These checks must not disconnect the whole interface.
        try {
            await sendCommand("PING");
        } catch (error) {
            console.warn("PING was delayed:", error);
        }

        try {
            await sendCommand("READ_ERROR");
        } catch (error) {
            console.warn("READ_ERROR was delayed:", error);
        }
    } catch (error) {
        console.error(error);

        workout.connected = false;
        updateConnectionInterface();

        connectionStatus.textContent = "Connection failed";
        connectionStatus.classList.add("disconnected");

        setDeviceMessage(
            "Could not reach the ESP32. Check the POWER-CABLE Wi-Fi."
        );
    } finally {
        connectButton.disabled = false;
    }
});

function disconnectLocally() {
    if (statusTimer !== null) {
        window.clearInterval(statusTimer);
        statusTimer = null;
    }

    workout.connected = false;
    workout.training = false;
    workout.awaitingReturn = false;
    trainingStartTime = null;

    updateConnectionInterface();
    updateControlAvailability();

    trainingState.textContent = "Disconnected";
    setDeviceMessage("Waiting for connection");
}

function updateConnectionInterface() {
    if (workout.connected) {
        connectionStatus.textContent = "Device connected";
        connectionStatus.classList.remove("disconnected");
        connectionStatus.classList.add("connected");

        connectButton.textContent = "Disconnect";
    } else {
        connectionStatus.textContent = "Disconnected";
        connectionStatus.classList.remove("connected");
        connectionStatus.classList.add("disconnected");

        connectButton.textContent = "Connect Device";
    }

    updateControlAvailability();
}

function updateControlAvailability() {
    const connected = workout.connected;

    setWeightButton.disabled = !connected;
    startTrainingButton.disabled =
        !connected ||
        !workout.configured ||
        workout.training ||
        workout.awaitingReturn;

    stopMotorButton.disabled = !connected;
    returnCableButton.disabled = !connected;
}

function startStatusPolling() {
    if (statusTimer !== null) {
        window.clearInterval(statusTimer);
    }

    statusTimer = window.setInterval(
        pollDeviceStatus,
        STATUS_INTERVAL_MS
    );
}

async function pollDeviceStatus() {
    if (
        statusRequestActive ||
        !workout.connected ||
        calibrationInProgress ||
        configurationInProgress
    ) {
        return;
    }

    statusRequestActive = true;

    try {
        const status = await readDeviceStatus();

        consecutiveConnectionFailures = 0;
        applyDeviceStatus(status);
        updateConnectionInterface();

        connectionStatus.textContent = "Connected";
    } catch (error) {
        console.error(error);

        // A request already running may finish after
        // calibration has started. Ignore that failure.
        if (calibrationInProgress) {
            return;
        }

        consecutiveConnectionFailures += 1;

        if (consecutiveConnectionFailures >= 5) {
            connectionStatus.textContent =
                "Connection unstable — retrying…";
        }
    } finally {
        statusRequestActive = false;
    }
}

// MARK: - Device status

function applyDeviceStatus(status) {
    if (status.message) {
        setDeviceMessage(status.message);
    }

    // The ESP32 can execute a command even when its HTTP acknowledgement
    // reaches the browser too late. Treat the device's status message as
    // the source of truth so a successfully configured workout is not
    // left blocked in the interface.
    if (
        typeof status.message === "string" &&
        status.message.startsWith("WORKOUT_CONFIGURED:")
    ) {
        workout.configured = true;
        trainingState.textContent = "Ready";
        updateControlAvailability();
    }

    if (
        typeof status.message === "string" &&
        status.message.startsWith("WORKOUT_BLOCKED:")
    ) {
        workout.configured = false;
        trainingState.textContent = "Configuration blocked";
        updateControlAvailability();
    }

    if (
        status.trainingActive &&
        !workout.training &&
        !workout.awaitingReturn
    ) {
        beginSetTracking();
    }

    const sequence = Number(status.feedbackSequence);

    if (
        Number.isFinite(sequence) &&
        sequence !== workout.lastFeedbackSequence
    ) {
        workout.lastFeedbackSequence = sequence;

        const position =
            Number(status.cablePositionCm);

        const velocity =
            Number(status.cableVelocityCmPerSecond);

        updateLiveMeasurement(position, velocity);
    }

    if (workout.training && trainingStartTime !== null) {
        workout.elapsedSeconds =
            (performance.now() - trainingStartTime) / 1000;

        updateMetrics();
    }

    if (
        workout.awaitingReturn &&
        status.message === "RETURN_TO_START_COMPLETE"
    ) {
        handleReturnComplete();
    }

    if (
        typeof status.message === "string" &&
        status.message.startsWith("TRAINING_BLOCKED:")
    ) {
        workout.training = false;
        trainingStartTime = null;

        trainingState.textContent = "Training blocked";
        startTrainingButton.disabled = false;
    }

    if (status.returnActive) {
        trainingState.textContent = "Returning cable";
    }
}


// MARK: - Workout configuration

weightRange.addEventListener("input", function () {
    weightOutput.textContent =
        formatWeight(weightRange.value);
});

setWeightButton.addEventListener("click", async function () {
    workout.weightKg = Number(weightRange.value);
    workout.targetReps = Math.max(
        1,
        Number(targetRepsInput.value)
    );
    workout.targetSets = Math.max(
        1,
        Number(targetSetsInput.value)
    );

    workout.currentSet = 1;
    workout.completedReps = 0;
    workout.partialReps = 0;
    workout.recommendedWeightKg = workout.weightKg;
    workout.configured = false;

    nextSetButton.hidden = true;

    resetRepetitionTracking();
    updateWorkoutProgress();
    updateRecommendation(
        workout.weightKg,
        0,
        "Complete a set to receive a recommendation."
    );

    setWeightButton.disabled = true;
    setWeightButton.textContent = "Applying…";
    configurationInProgress = true;

    if (statusTimer !== null) {
        window.clearInterval(statusTimer);
        statusTimer = null;
    }

    try {
        // Allow a status request that already started to finish before
        // sending the workout configuration command.
        for (
            let attempt = 0;
            attempt < 60 && statusRequestActive;
            attempt += 1
        ) {
            await wait(100);
        }

        await sendConfigurationCommand(
            `SET_WORKOUT:${workout.weightKg.toFixed(1)}`
        );

        workout.configured = true;
        trainingState.textContent = "Ready";
        setDeviceMessage("WORKOUT_CONFIGURED");
    } catch (error) {
        console.error(error);
        setDeviceMessage("CONFIGURATION_FAILED");
    } finally {
        configurationInProgress = false;
        setWeightButton.disabled = false;
        setWeightButton.textContent = "Set Weight";
        updateControlAvailability();

        if (workout.connected) {
            startStatusPolling();
        }
    }
});


// MARK: - Training controls

startTrainingButton.addEventListener("click", async function () {
    if (!workout.connected) {
        setDeviceMessage("CONNECT_FIRST");
        return;
    }

    if (!workout.configured) {
        setDeviceMessage("APPLY_WORKOUT_SETTINGS_FIRST");
        return;
    }

    startTrainingButton.disabled = true;
    trainingState.textContent = "Preparing";

    try {
        await sendCommand("MOTOR_ON");
    } catch (error) {
        console.error(error);

        trainingState.textContent = "Start failed";
        startTrainingButton.disabled = false;
    }
});

nextSetButton.addEventListener("click", async function () {
    if (workout.currentSet >= workout.targetSets) {
        return;
    }

    workout.currentSet += 1;
    workout.weightKg =
        workout.recommendedWeightKg;

    weightRange.value = workout.weightKg;
    weightOutput.textContent =
        formatWeight(workout.weightKg);

    nextSetButton.hidden = true;
    trainingState.textContent = "Preparing next set";

    resetRepetitionTracking();
    updateWorkoutProgress();

    try {
        await sendCommand(
            `SET_KG:${workout.weightKg.toFixed(1)}`
        );

        await sendCommand("MOTOR_ON");
    } catch (error) {
        console.error(error);

        trainingState.textContent =
            "Could not start next set";

        nextSetButton.hidden = false;
    }
});

stopMotorButton.addEventListener("click", async function () {
    try {
        await sendCommand("MOTOR_OFF");
    } catch (error) {
        console.error(error);
    }

    stopLocalTraining();
    trainingState.textContent = "Stopped";
});

returnCableButton.addEventListener("click", async function () {
    workout.awaitingReturn = true;
    trainingState.textContent = "Returning cable";

    try {
        await sendCommand("RETURN_TO_START");
    } catch (error) {
        console.error(error);

        workout.awaitingReturn = false;
        trainingState.textContent = "Return failed";
    }
});


// MARK: - Real repetition tracking

function beginSetTracking() {
    resetRepetitionTracking();

    workout.training = true;
    workout.awaitingReturn = false;
    trainingStartTime = performance.now();

    trainingState.textContent = "Training";
    startTrainingButton.disabled = true;

    setDeviceMessage(
        `SET_${workout.currentSet}_ACTIVE`
    );
}

function resetRepetitionTracking() {
    workout.training = false;
    workout.completedReps = 0;
    workout.partialReps = 0;
    workout.liveSpeed = 0;
    workout.peakSpeed = 0;
    workout.elapsedSeconds = 0;

    workout.phase = "waiting";
    workout.repetitionStartPositionCm = 0;
    workout.maximumCablePositionCm = 0;
    workout.pullSpeedSum = 0;
    workout.pullSpeedSampleCount = 0;
    workout.currentRepPeakSpeed = 0;

    workout.repetitionMetrics = [];

    speedHistory.fill(0);

    lastRange.textContent = "—";
    averageSpeed.textContent = "—";
    lastPeakSpeed.textContent = "—";

    updateWorkoutProgress();
    updateMetrics();
    drawSpeedChart();
}

function updateLiveMeasurement(position, velocity) {
    if (!Number.isFinite(position) ||
        !Number.isFinite(velocity)) {
        return;
    }

    const absoluteSpeed = Math.abs(velocity);

    workout.liveSpeed = absoluteSpeed;

    if (workout.training) {
        workout.peakSpeed = Math.max(
            workout.peakSpeed,
            absoluteSpeed
        );

        speedHistory.push(absoluteSpeed);
        speedHistory.shift();

        processCableFeedback(position, velocity);
    }

    updateMetrics();
    drawSpeedChart();
}

function processCableFeedback(position, velocity) {
    switch (workout.phase) {
    case "waiting":
        if (velocity > MOVEMENT_THRESHOLD_CM_S) {
            workout.repetitionStartPositionCm = position;
            workout.maximumCablePositionCm = position;
            workout.pullSpeedSum = velocity;
            workout.pullSpeedSampleCount = 1;
            workout.currentRepPeakSpeed = velocity;

            workout.phase = "pulling";
            trainingState.textContent = "Pulling";
        }
        break;

    case "pulling":
        workout.maximumCablePositionCm = Math.max(
            workout.maximumCablePositionCm,
            position
        );

        if (velocity > 0) {
            workout.pullSpeedSum += velocity;
            workout.pullSpeedSampleCount += 1;

            workout.currentRepPeakSpeed = Math.max(
                workout.currentRepPeakSpeed,
                velocity
            );
        }

        if (velocity < -MOVEMENT_THRESHOLD_CM_S) {
            workout.phase = "returning";
            trainingState.textContent = "Returning";
        }
        break;

    case "returning": {
        const repetitionDistance = Math.max(
            0,
            workout.maximumCablePositionCm -
                workout.repetitionStartPositionCm
        );

        const returnTolerance = Math.max(
            START_POSITION_TOLERANCE_CM,
            repetitionDistance *
                (1 - REQUIRED_RETURN_PERCENTAGE)
        );

        const acceptedReturnPosition =
            workout.repetitionStartPositionCm +
            returnTolerance;

        if (position <= acceptedReturnPosition) {
            finishRepetition(repetitionDistance);
        } else if (velocity > MOVEMENT_THRESHOLD_CM_S) {
            workout.partialReps += 1;

            workout.repetitionStartPositionCm = position;
            workout.maximumCablePositionCm = position;
            workout.pullSpeedSum = velocity;
            workout.pullSpeedSampleCount = 1;
            workout.currentRepPeakSpeed = velocity;

            workout.phase = "pulling";
            trainingState.textContent =
                "Partial: return farther";
        }
        break;
    }
    }
}

function finishRepetition(distance) {
    if (distance >= MINIMUM_REPETITION_DISTANCE_CM) {
        workout.completedReps += 1;

        const meanSpeed =
            workout.pullSpeedSampleCount > 0
                ? workout.pullSpeedSum /
                    workout.pullSpeedSampleCount
                : 0;

        const metric = {
            number: workout.completedReps,
            rangeCm: distance,
            meanSpeedCmPerSecond: meanSpeed,
            peakSpeedCmPerSecond:
                workout.currentRepPeakSpeed
        };

        workout.repetitionMetrics.push(metric);

        lastRange.textContent =
            `${formatNumber(distance)} cm`;

        averageSpeed.textContent =
            `${formatNumber(meanSpeed)} cm/s`;

        lastPeakSpeed.textContent =
            `${formatNumber(
                workout.currentRepPeakSpeed
            )} cm/s`;

        trainingState.textContent =
            `Full rep ${workout.completedReps}`;

        updateWorkoutProgress();

        if (
            workout.completedReps >=
            workout.targetReps
        ) {
            finishSet();
        }
    } else {
        workout.partialReps += 1;

        trainingState.textContent =
            "Partial: movement too short";
    }

    workout.phase = "waiting";
    workout.repetitionStartPositionCm = 0;
    workout.maximumCablePositionCm = 0;
    workout.pullSpeedSum = 0;
    workout.pullSpeedSampleCount = 0;
    workout.currentRepPeakSpeed = 0;
}


// MARK: - Adaptive recommendation

async function finishSet() {
    calculateRecommendation();

    workout.training = false;
    workout.awaitingReturn = true;
    workout.liveSpeed = 0;
    trainingStartTime = null;

    trainingState.textContent = "Returning cable";
    startTrainingButton.disabled = true;

    updateMetrics();

    try {
        await sendCommand("FINISH_SET");
    } catch (error) {
        console.error(error);

        workout.awaitingReturn = false;
        trainingState.textContent = "Set finish failed";
    }
}

function calculateRecommendation() {
    const metrics = workout.repetitionMetrics;

    if (metrics.length === 0) {
        return;
    }

    const baselineMetrics = metrics.slice(
        0,
        Math.min(2, metrics.length)
    );

    const baselineSpeed =
        baselineMetrics.reduce(
            (sum, metric) =>
                sum + metric.meanSpeedCmPerSecond,
            0
        ) / baselineMetrics.length;

    const baselineRange =
        baselineMetrics.reduce(
            (sum, metric) =>
                sum + metric.rangeCm,
            0
        ) / baselineMetrics.length;

    const finalRepetition =
        metrics[metrics.length - 1];

    const loss = baselineSpeed > 0
        ? Math.max(
            0,
            (
                (baselineSpeed -
                    finalRepetition.meanSpeedCmPerSecond) /
                baselineSpeed
            ) * 100
        )
        : 0;

    const insufficientRange =
        finalRepetition.rangeCm <
        baselineRange * 0.85;

    let nextWeight = workout.weightKg;
    let reason =
        "Appropriate fatigue for this resistance.";

    if (
        workout.partialReps > 0 ||
        insufficientRange ||
        loss > 35
    ) {
        nextWeight = Math.max(
            4,
            workout.weightKg - 0.5
        );

        reason =
            "High fatigue or incomplete movement.";
    } else if (loss < 20) {
        nextWeight = Math.min(
            30,
            workout.weightKg + 0.5
        );

        reason =
            "Strong performance with low speed loss.";
    }

    workout.recommendedWeightKg = nextWeight;
    workout.velocityLossPercent = loss;

    updateRecommendation(
        nextWeight,
        loss,
        reason
    );
}

function updateRecommendation(weight, loss, reason) {
    recommendedWeight.textContent =
        formatWeight(weight);

    velocityLoss.textContent =
        `${formatNumber(loss)}%`;

    recommendationReason.textContent = reason;
}

function handleReturnComplete() {
    workout.awaitingReturn = false;

    if (workout.currentSet < workout.targetSets) {
        trainingState.textContent =
            `Set ${workout.currentSet} complete`;

        nextSetButton.textContent =
            `Start Set ${workout.currentSet + 1}`;

        nextSetButton.hidden = false;
    } else {
        trainingState.textContent = "Workout complete";
        nextSetButton.hidden = true;
    }

    updateControlAvailability();
}

function stopLocalTraining() {
    workout.training = false;
    workout.awaitingReturn = false;
    workout.liveSpeed = 0;
    trainingStartTime = null;

    updateMetrics();
    updateControlAvailability();
}


// MARK: - Interface updates

function updateWorkoutProgress() {
    setProgress.textContent =
        `Set ${workout.currentSet} of ${workout.targetSets}`;

    repProgress.textContent =
        `${workout.completedReps} / ${workout.targetReps}`;

    completedRepsDisplay.textContent =
        workout.completedReps;

    const progress =
        workout.targetReps > 0
            ? (
                workout.completedReps /
                workout.targetReps
            ) * 100
            : 0;

    repProgressBar.style.width =
        `${Math.min(progress, 100)}%`;
}

function updateMetrics() {
    liveSpeed.textContent =
        formatNumber(workout.liveSpeed);

    peakSpeed.textContent =
        formatNumber(workout.peakSpeed);

    setTime.textContent =
        formatNumber(workout.elapsedSeconds);
}

function setDeviceMessage(message) {
    deviceMessage.textContent = message;
}


// MARK: - Speed graph

function drawSpeedChart() {
    const width = speedChart.width;
    const height = speedChart.height;

    const padding = 24;
    const maximumSpeed = 100;

    chartContext.clearRect(0, 0, width, height);
    chartContext.beginPath();

    speedHistory.forEach(function (speed, index) {
        const x =
            padding +
            (
                index /
                (speedHistory.length - 1)
            ) *
            (width - padding * 2);

        const y =
            height -
            padding -
            (
                Math.min(speed, maximumSpeed) /
                maximumSpeed
            ) *
            (height - padding * 2);

        if (index === 0) {
            chartContext.moveTo(x, y);
        } else {
            chartContext.lineTo(x, y);
        }
    });

    chartContext.strokeStyle = "#20a4ff";
    chartContext.lineWidth = 4;
    chartContext.lineJoin = "round";
    chartContext.lineCap = "round";
    chartContext.stroke();
}

const calibrateButton =
    document.getElementById("calibrateButton");

calibrateButton.addEventListener("click", async () => {
    const confirmed = window.confirm(
        "Remove all weight from the cable and keep everyone clear. Start motor calibration?"
    );

    if (!confirmed) {
        return;
    }

    calibrationInProgress = true;

    if (statusTimer !== null) {
        window.clearInterval(statusTimer);
        statusTimer = null;
    }

    calibrateButton.disabled = true;
    calibrateButton.textContent = "Calibrating...";
    connectionStatus.textContent = "Calibrating motor…";
    setDeviceMessage(
        "Calibration is running. Please wait approximately 15 seconds."
    );

    try {
        await sendCommand("CALIBRATE_AXIS1");

        // Do not resume normal polling while the ODrive is calibrating.
        await new Promise(function (resolve) {
            window.setTimeout(resolve, 15000);
        });

        connectionStatus.textContent =
            "Checking calibration…";
        setDeviceMessage("Checking motor readiness");

        await sendCommand("READ_ERROR");

        // Allow the ESP32 to complete the ODrive readiness checks.
        await new Promise(function (resolve) {
            window.setTimeout(resolve, 2000);
        });

        let status = null;
        let lastStatusError = null;

        // The Mac may briefly pause requests while connected to a
        // Wi-Fi network without internet access. Retry the local ESP32
        // instead of reporting a false calibration failure.
        for (let attempt = 1; attempt <= 6; attempt += 1) {
            try {
                status = await readDeviceStatus();
                break;
            } catch (error) {
                lastStatusError = error;

                connectionStatus.textContent =
                    `Reconnecting after calibration… ${attempt}/6`;

                await new Promise(function (resolve) {
                    window.setTimeout(resolve, 1000);
                });
            }
        }

        if (!status) {
            throw lastStatusError ||
                new Error("No status received after calibration");
        }

        applyDeviceStatus(status);

        if (status.ready) {
            connectionStatus.textContent = "Connected";
            setDeviceMessage(
                "Calibration completed. Motor is ready."
            );
        } else {
            connectionStatus.textContent =
                "Connected — motor not ready";

            setDeviceMessage(
                status.message ||
                "Calibration finished, but the motor is not ready."
            );
        }
    } catch (error) {
        console.error(error);

        connectionStatus.textContent =
            "Calibration finished — reconnecting…";

        setDeviceMessage(
            "Calibration finished. Waiting for the ESP32 connection."
        );
    } finally {
        calibrationInProgress = false;
        calibrateButton.disabled = false;
        calibrateButton.textContent = "Calibrate Motor";

        if (workout.connected) {
            startStatusPolling();

            window.setTimeout(
                pollDeviceStatus,
                1000
            );
        }
    }
});


// MARK: - Initial page state

weightOutput.textContent =
    formatWeight(weightRange.value);

nextSetButton.hidden = true;

updateConnectionInterface();
updateWorkoutProgress();
updateMetrics();
drawSpeedChart();
