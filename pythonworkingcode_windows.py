from kivy.app import async_runTouchApp
from kivy.app import App
from kivy.uix.widget import Widget
from kivy.uix.boxlayout import BoxLayout
from kivy.core.window import Window
from kivy.properties import (
    NumericProperty, ReferenceListProperty, ObjectProperty, ColorProperty
)
from kivy.lang.builder import Builder
import asyncio

import odrive
from odrive.enums import *
import time
import math
import numpy as np


Window.fullscreen = True


kv = '''#:kivy 2.3.1
<LayoutObject>:
    canvas.before:
        Color:
            rgba: root.k_background_color
        Rectangle:
            pos: self.pos
            size: self.size
    size: root.width, root.height 
    BoxLayout:
        orientation: 'vertical'
        BoxLayout:
            orientation: 'horizontal'
            size_hint_y: 0.1
            Label:
                font_size: root.k_font_medium
                color: root.k_highlight_text_color
                text: 'Set weight (KG)'
            Label:
                font_size: root.k_font_medium
                color: root.k_normal_text_color
                text: 'Current weight (KG)'
            Label:
                size_hint_x: 0.2
                font_size: 28
                text: ''
        BoxLayout:
            orientation: 'horizontal'
            Label:
                background_color: root.k_background_color
                id: set_weight
                font_size: root.k_font_big
                color: root.k_highlight_text_color
                text: root.get_set_force_string()
            Label:
                id: current_weight
                color: root.k_normal_text_color
                font_size: root.k_font_big
                text: root.get_current_force_string()
            BoxLayout:
                orientation: 'vertical'
                size_hint_x: 0.2
                Label:
                    text: "Reel(cm)"
                    color: root.k_normal_text_color
                    font_size: root.k_font_small
                Button:
                    background_color: root.k_less_use_button_color
                    color: root.k_normal_text_color
                    id: reel_out_10
                    text: '+10'
                    font_size: root.k_font_small
                Button:
                    background_color: root.k_less_use_button_color
                    color: root.k_normal_text_color
                    id: reel_out_1
                    text: '+1'
                    font_size: root.k_font_small
                Button:
                    background_color: root.k_less_use_button_color
                    color: root.k_normal_text_color
                    id: reel_in_1
                    text: '-1'
                    font_size: root.k_font_small
                Button:
                    background_color: root.k_less_use_button_color
                    color: root.k_normal_text_color
                    id: reel_in_10
                    text: '-10'
                    font_size: root.k_font_small
        BoxLayout:
            orientation: 'horizontal'
            size_hint_y: 0.25
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b10000p
                text: '+10'
                font_size: root.k_font_small
                on_press: root.add_force_kg(10.0)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b5000p
                text: '+5'
                font_size: root.k_font_small
                on_press: root.add_force_kg(5.0)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b2500p
                text: '+2,5'
                font_size: root.k_font_small
                on_press: root.add_force_kg(2.5)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b1000p
                text: '+1'
                font_size: root.k_font_small
                on_press: root.add_force_kg(1.0)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b500p
                text: '+0,5'
                font_size: root.k_font_small
                on_press: root.add_force_kg(0.5)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b500m
                text: '-0,5'
                font_size: root.k_font_small
                on_press: root.add_force_kg(-0.5)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b1000m
                text: '-1'
                font_size: root.k_font_small
                on_press: root.add_force_kg(-1.0)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b2500m
                text: '-2,5'
                font_size: root.k_font_small
                on_press: root.add_force_kg(-2.5)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b5000m
                text: '-5'
                font_size: root.k_font_small
                on_press: root.add_force_kg(-5.0)
            Button:
                background_color: root.k_active_use_button_color
                color: root.k_normal_text_color
                id: b10000m
                text: '-10'
                font_size: root.k_font_small
                on_press: root.add_force_kg(-10.0)
        BoxLayout:
            orientation: 'horizontal'
            size_hint_y: 0.3
            Button:
                background_color: root.k_less_use_button_color
                color: root.k_normal_text_color
                id: calibrate
                text: 'calibrate'
                font_size: root.k_font_medium
                on_press: root.calibrate()
            Button:
                background_color: root.k_less_use_button_color
                color: root.k_normal_text_color
                id: onoff
                text: 'On/Off'
                font_size: root.k_font_medium
                on_press: root.turn_on()
            Button:
                background_color: root.k_less_use_button_color
                color: root.k_normal_text_color
                id: clear_errors
                text: 'clear errors'
                font_size: root.k_font_medium
                on_press: root.clear_errors()
'''
Builder.load_string(kv)

class LayoutObject(BoxLayout):
    set_weight = NumericProperty(0)
    current_weight = NumericProperty(0)

    k_background_color = ColorProperty("242038")
    k_active_use_button_color = ColorProperty("8D86C9")
    k_less_use_button_color = ColorProperty("9067C6")
    k_highlight_text_color = ColorProperty("E8FCC2")
    k_normal_text_color = ColorProperty("B1CC74")
    k_font_small = NumericProperty(38)
    k_font_medium = NumericProperty(48)
    k_font_big = NumericProperty(200)

    kg_to_current = 1.0/1.8
    motor = None
    def __init__(self, motor, **kwargs):
        super(LayoutObject, self).__init__(**kwargs)

        self.motor = motor

    def calibrate(self):
        self.motor.axis1.requested_state = AXIS_STATE_FULL_CALIBRATION_SEQUENCE

    def turn_on(self):
        if(self.motor.axis1.current_state != AXIS_STATE_CLOSED_LOOP_CONTROL):
            print("AXIS_STATE -> CLOSED_LOOP_CONTROL")
            self.motor.axis1.requested_state = AXIS_STATE_CLOSED_LOOP_CONTROL
        else:
            print("AXIS_STATE -> IDLE")
            self.motor.axis1.requested_state = AXIS_STATE_IDLE

    def set_force_kg(self, kg):
        self.motor.axis1.motor.config.current_lim = kg*self.kg_to_current

    def get_max_force(self):
        return self.motor.axis1.motor.config.current_lim / self.kg_to_current

    def add_force_kg(self, kg):
        self.set_force_kg(self.get_max_force() + kg)

    def clear_errors(self):
        self.motor.clear_errors()   # was: self.motor.axis1.clear_errors()


    def get_current_force(self):
        return self.motor.axis1.motor.current_control.Iq_measured / self.kg_to_current


    def get_current_force_string(self):
        if self.motor != None:
            return f"{self.get_current_force():.2f}"
        return "error"

    def get_set_force_string(self):
        if self.motor != None:
            return f"{self.get_max_force():.2f}"
        return "error"

class AsyncApp(App):
    

    data_task = None

    layout = None

    motor = odrive.find_any(timeout = 10)

    async def init_motor(self):
        print("finding an odrive...")
        try:
            self.motor = odrive.find_any(timeout = 0.1)
        except:
            print("No odrive found")

    def build(self):
        #self.init_motor()
        self.layout = LayoutObject(self.motor)
        return self.layout


    def app_func(self):
        '''This will run both methods asynchronously and then block until they
        are finished
        '''
        self.data_task = asyncio.ensure_future(self.update_task())

        async def run_wrapper():
            # we don't actually need to set asyncio as the lib because it is
            # the default, but it doesn't hurt to be explicit
            await self.async_run(async_lib='asyncio')
            print('App done')
            self.data_task.cancel()

        return asyncio.gather(run_wrapper(), self.data_task)

    async def gui_task(root, update_task):
        #init_motor()
        await async_runTouchApp(root, async_lib='asyncio')
        print('App done')
        update_task.cancel()

    async def update_task(self):
        while True:
            if self.layout != None:
                self.layout.ids.current_weight.text = self.layout.get_current_force_string()
                self.layout.ids.set_weight.text = self.layout.get_set_force_string()
            await asyncio.sleep(0.25)
 

if __name__ == '__main__':
    loop = asyncio.get_event_loop()
    loop.run_until_complete(AsyncApp().app_func())
    loop.close()
