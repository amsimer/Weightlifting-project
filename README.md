# Power Cable V2

Technology and Health Project Course

MSc Sports Technology Students at KTH Royal Institute of Technology

# Product Information

This product is an electric weight lifting device that can be set to different weights digitally without the need for external accesories like weight plates. The device can be operated through an app in IOS systems and a HTML file with any operating system in a PC. The user is able to set the desired training weight, see the current force in Kg they are pulling with, and see the speed for every rep. It also has an alternative adaptive resistance mode, for which the user selects their desired rep speed and the device automatically makes every rep close to muscle failure to optimize hyperthrophy training.

## Hardware

The device uses an electric longboard's ODrive motor, that attempts to go back to its starting position once turned on. The set weight is converted into a max current that limits with how much force can the motor pull back to return to its position. 

The hardware improvements made to the Power Cable previous prototype involved adding a cable box to enclose the power supply, Odrive controller, and Bluetooth antenna with an MDF box to avoid safety hazards related to cables coming from the power supply to the motor being exposed to the environment.

The box was designed using the open-source boxes.py tool and Inkscape to draw the cable holes. The dimensions were: 240x130x110 millimeters, and the cable holes in the front of the box are 40mm in diameter, and the back hole is 70 millimeters in diameter. 


- See all the hardware files here: [Hardware](https://github.com/amsimer/Weightlifting-project/tree/main/Hardware).
- View the PCB design and manufacturing files here: [PCB files](Hardware/PCB/).

## Software

The software provides three interfaces for operating, testing and monitoring the device.

### Original HTML interface

The original JavaScript interface controls the device through a computer. It was adapted from the earlier Python implementation and provides fixed-weight and adaptive-resistance modes together with force and speed tracking. It can be operated directly from this Github page.

- [Open the HTML interface](https://amsimer.github.io/Weightlifting-project/Software/control.html)

#### Demostration

https://github.com/user-attachments/assets/4b4825d2-2c79-4780-979c-93d6ef282277

https://github.com/user-attachments/assets/1ee684fa-d978-47a7-b3ad-fbba4a475636

### iOS application (Bluetooth Low Energy)

The native SwiftUI iPhone application connects directly to the ESP32-C3 over Bluetooth Low Energy. It supports motor calibration, resistance selection, target sets and repetitions, start/stop control, cable return, live cable speed, repetition and set tracking, set timing, last-repetition statistics, adaptive next-set recommendations and spoken/audio feedback.

- [Open the iOS application source](Software/iOS-APP/)
- [Watch the iOS application demo](Software/Demos/ios-app-recording.mp4)

### Wi-Fi training dashboard

The ESP32 creates the local `POWER-CABLE` Wi-Fi network and serves a browser dashboard from its LittleFS filesystem. The dashboard provides browser-based workout control and live feedback without requiring an installed application. It displays connection state, repetitions, set progress, cable speed, set time, last-repetition measurements and the next-set recommendation.

- [Open the live POWER-CABLE dashboard](http://192.168.4.1/) — available while connected to the `POWER-CABLE` Wi-Fi network
- [View the Wi-Fi dashboard source](Software/WiFi-Dashboard/)
- [Watch the Wi-Fi dashboard demo](Software/Demos/web-dashboard-recording.mov)

### ESP32 firmware

The shared Arduino firmware connects both wireless interfaces to the ODrive motor controller. It handles BLE commands, HTTP requests, LittleFS-hosted web files, ODrive UART communication, calibration, cable position and velocity measurements, repetition detection, workout state and safety-related motor-stop commands.

- [Open the ESP32 firmware](Software/Firmware/WeightLifting_ODrive_RepTracking/)

Before creating the HTML and iOS interfaces, two Python programs were used to verify that the device could be operated from Windows and macOS. These earlier development and diagnostic files are retained in the repository.

- [Browse all software files](Software/)

## Documentation

In this folder you can find relevant documents for this project, including the short paper and lean canvas.

- Find it here: [Documents](https://github.com/amsimer/Weightlifting-project/tree/main/Docs).

There's also a data folder where you can find the data used to validate the speed tracking for the HTML interface, as well as data extracted from the app.

- Look here: [Data](https://github.com/amsimer/Weightlifting-project/tree/main/Data).

## Previous Work

The device was originally built by Linus Remahl, research engineer at KTH, Stockholm, Sweden.

- Find his Github profile here: [Linus](https://github.com/linusreM).

Then it was worked on and improved by a group of third year students for Medical Engineering at KTH. You can look at their work in the following:

- Github Repository: [Power Cable](https://github.com/HugoPersson01/POWER-CABLE).
- Previous work files: [Previous Work](https://github.com/amsimer/Weightlifting-project/tree/main/Previous_Work).

## Contributors

<a href="https://github.com/amsimer">
  <b>Santiago Remis: amsimer</b><br>
  <img src="https://github.com/amsimer.png" width="100px"><br>
</a>

<a href="https://github.com/euro311">
  <b>Eusebio Rodriguez: euro311</b><br>
  <img src="https://github.com/euro311.png" width="100px"><br>
</a>

<a href="https://github.com/Yunus-Sah">
  <b>Yunus Emre Sahin: Yunus-Sah</b><br>
  <img src="https://github.com/Yunus-Sah.png" width="100px"><br>
</a>

<a href="https://github.com/shaunvarghese">
  <b>Shaun Varghese: shaunvarghese</b><br>
  <img src="https://github.com/shaunvarghese.png" width="100px"><br>
</a>

