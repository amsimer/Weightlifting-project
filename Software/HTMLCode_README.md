# ODrive HTML Interfce Console
 
A single-file web interface that controls a motor-driven cable machine through an ODrive. It sets the resistance as a motor current limit, shows your pulling force and handle speed live, and includes an adaptive mode for bicep curls.
 
Runs in Chrome or Edge only (Web Serial). Operate the HTML file directly from this Github.
 
## Contents
 
1. [Connection and polling](#1-connection-and-polling)
2. [Fixed mode and basic buttons](#2-fixed-mode-and-basic-buttons)
3. [Adaptive mode: stroke tracking](#3-adaptive-mode-stroke-tracking)
4. [Adaptive mode: calibration rep](#4-adaptive-mode-calibration-rep)
5. [Adaptive mode: every working rep](#5-adaptive-mode-every-working-rep)
6. [Between reps](#6-between-reps)
7. [Safety and assumptions](#7-safety-and-assumptions)
8. [Main settings](#8-main-settings)
## 1. Connection and polling
 
### Connection
 
The page talks to the ODrive over Web Serial (115200 baud, ASCII protocol) and reconnects by itself whenever the adapter or the ODrive comes back.
 
- All commands go through one queue.
- Writes (`w ...`) are sent and the queue moves on.
- Reads (`r ...`) wait for a single reply line, with a timeout, so replies can't be mixed up.
- Three failed reads in a row mark the ODrive as offline (yellow status), and the page keeps trying until it answers.
### Polling
 
Every 20 to 60 ms the page reads the measured current and the handle speed. Every fifth cycle it also reads the current limit, the axis state and the error code.
 
### How kg and current are linked
 
The motor's torque is proportional to its current, and the cable force is that torque divided by the spool radius (and multiplied by any gear reduction). So force and current are linked by a single constant, `kgToCurrent = 1/1.8`, meaning 1.8 kg of cable force per amp. For example, 18 kg corresponds to 10 A.
 
- **Setting the load:** the page writes the current limit (`axis1.motor.config.current_lim`) as kg × `kgToCurrent`. The limit caps the torque, so it caps the force the motor can apply.
- **Reading your pull:** the page reads the measured current (`Iq_measured`) and divides by the same factor to get kg.
- **Where the constant comes from:** it was in the original code and hasn't been checked against the hardware. It's separate from `SPOOL_RADIUS_M` and `GEAR_RATIO`, which are only used for speed. If you change the spool or gearing, recheck it.
- **Limitation:** the measured current only shows your pull while the handle is stuck, with the load above what you can move. Once the handle moves, the motor is at its current limit, so the reading just equals the load. That's why the code only uses force readings during the stuck phase.
### How speed is measured
 
The ODrive's encoder estimates the motor's velocity in turns per second (`axis1.encoder.vel_estimate` on firmware 0.5.x). If that property gets no reply for 8 reads in a row, the page tries the alternatives `axis1.pos_vel_mapper.vel` and `axis1.vel_estimate`. The page converts it to handle speed with:
 
```
m/s = turns/s × (2π × SPOOL_RADIUS_M ÷ GEAR_RATIO) × CONC_SIGN × scaleFix
```
 
- The first factor is the cable length pulled per motor turn.
- `CONC_SIGN` makes pulling positive.
- `scaleFix` is the correction the calibration rep learns, so a wrong radius doesn't distort the distances.
- The speed is lightly smoothed (50% blend with the previous value) because the encoder estimate is noisy at low speeds.
- The stroke is not read from the encoder. It's calculated by adding up speed over time.
## 2. Fixed mode and basic buttons
 
- **Fixed mode** sets the current limit directly with the ± buttons.
- **Calibrate** runs idle, clear errors, then the motor calibration, and reports the result or error.
- **On / Off** follows the real axis state.
- **Clear errors** sends `sc`.
## 3. Adaptive mode: stroke tracking
 
The handle position isn't read. The stroke `x` is calculated by adding up speed over time, and it resets to zero when the handle sits still near home. A rep starts when `x` passes 3 cm and ends when it comes back under 2 cm.
 
## 4. Adaptive mode: calibration rep
 
When you press **Start set**, the load is a light constant 2 kg. Your first curl does two jobs:
 
- It compares the measured stroke with `REAL_ROM_M` (60 cm) and fixes the distance scale.
- Its lifting time sets your target speed, so the pace you calibrate at is the pace you train at.
The load then goes to your start weight.
 
## 5. Adaptive mode: every working rep
 
The load can only go down within a rep, and only between 5 cm and 85% of the stroke while you aren't lowering:
 
- **Pulling but the handle isn't moving** (force above 2 kg for 120 ms): the load falls at up to 8 kg/s toward 90% of your measured pull. Force is only measurable while the handle is stuck, because once it moves the motor current equals the limit.
- **Moving slower than 95% of the target speed:** the load falls at up to 6 kg/s, scaled by how far below target you are.
- **At the top of the stroke and while lowering,** the load isn't touched.
## 6. Between reps
 
- The load at which the handle started moving is recorded.
- The next rep starts at that load plus `RESTART_MARGIN_KG` (5), never above your start weight.
- Each log line shows the start load, the load it moved at, the end load, the stroke and the average speed.
- Short reps (under 8 cm) aren't logged and don't change the next start.
- Nothing ends the set automatically. **Stop set** drops the load to 2 kg.
- Calibrate and On / Off are disabled during a set.
## 7. Safety and assumptions
 
- The load never exceeds `MAX_KG` (30).
- The code assumes the motor holds position with the current limit acting as the force cap.
- Lifting must read as positive speed (`CONC_SIGN`).
## 8. Main settings
 
In the `AD` block of the script, plus the spool values above it:
 
| Setting | Purpose |
|---|---|
| `RESTART_MARGIN_KG` | Headroom above the last rep's moving load for the next start |
| `CAL_SPEED_FACTOR` | Multiplies the calibration speed to get the target speed |
| `STALL_DROP_KG_S` | Maximum load drop rate while pulling against a stuck handle |
| `SLOW_DROP_KG_S` | Load drop rate when moving slower than the target |
| `STALL_TARGET` | Fraction of your measured pull the load falls toward when stuck |
| `SPEED_DEADBAND` | Fraction of the target speed above which the load stops dropping |
| `CTRL_END_FRAC` | Fraction of the stroke after which the load isn't changed |
| `REAL_ROM_M` | Real handle travel of one full curl, measured with a tape |
| `SPOOL_RADIUS_M` | Effective spool radius, used to convert motor speed to handle speed |
| `GEAR_RATIO` | Motor turns per spool turn, used for the same conversion |

These settings can be changed depending on user capacity/preference but be sure to always do it in a controlled environment and take the following safety precautions:
- Always keep your hands away from the motor and the coil when the device is plugged in.
- Work with weight settings you know you can handle.
- Do not drop any external objects into the enclosure box and/or the motor and wind coil.
- Always step on the device when training with it.
- Always turn the device off after use and when moving/transporting it.
