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

## Software

We developed an HTML interface using Javascript code to control the device through a PC directly from this Github Repository, which was adapted from a previoues python code. The interface offers a fixed weight mode, an adaptive weight mode, user force and speed tracking for a set. 

- Use the control interface here: [HTML Interface](https://amsimer.github.io/Weightlifting-project/Software/control.html).

We also developed an IOS app for Mac and iPhone that.............

- Find the app here:

Before making the HTML and app interfaces, we developed two python codes to make sure the device could be operated from windows and from mac.

- Find all the software files here: [Software](https://github.com/amsimer/Weightlifting-project/tree/main/Software).

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
