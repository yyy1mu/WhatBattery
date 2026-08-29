import Testing
@testable import WhatBattery

struct StandardHIDBatteryMonitorTests {
    @Test("Standard HID logical ranges scale to a percentage")
    func scalesLogicalRanges() {
        #expect(StandardHIDBatteryScale.percentage(
            rawValue: 50,
            logicalMinimum: 0,
            logicalMaximum: 100
        ) == 50)
        #expect(StandardHIDBatteryScale.percentage(
            rawValue: 128,
            logicalMinimum: 0,
            logicalMaximum: 255
        ) == 50)
        #expect(StandardHIDBatteryScale.percentage(
            rawValue: 15,
            logicalMinimum: 10,
            logicalMaximum: 20
        ) == 50)
    }

    @Test("Invalid standard HID values are rejected")
    func rejectsInvalidValues() {
        #expect(StandardHIDBatteryScale.percentage(
            rawValue: -1,
            logicalMinimum: 0,
            logicalMaximum: 100
        ) == nil)
        #expect(StandardHIDBatteryScale.percentage(
            rawValue: 101,
            logicalMinimum: 0,
            logicalMaximum: 100
        ) == nil)
        #expect(StandardHIDBatteryScale.percentage(
            rawValue: 1,
            logicalMinimum: 1,
            logicalMaximum: 1
        ) == nil)
    }
}
