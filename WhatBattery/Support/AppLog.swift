import Foundation
import os

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "WhatBattery"

    static let battery = Logger(subsystem: subsystem, category: "Battery")
    static let bluetooth = Logger(subsystem: subsystem, category: "Bluetooth")
    static let hid = Logger(subsystem: subsystem, category: "HID")
}
