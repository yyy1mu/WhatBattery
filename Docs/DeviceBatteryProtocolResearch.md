# USB/HID 电量协议调研

调研日期：2026-08-24。

## 可安全泛化的标准

USB-IF 的 HID Usage Tables 1.5 定义了两类可表达电量的标准 usage：

- Generic Device Controls page (`0x06`) 的 Battery Strength (`0x20`)。
- Battery System page (`0x85`) 的 Relative State of Charge (`0x64`)、Absolute State
  of Charge (`0x65`) 和 Remaining Capacity (`0x66`)。

Linux 主线 `hid-input.c` 也只在 HID report descriptor 实际暴露 Battery Strength
时创建通用电池；它使用 descriptor 的 logical minimum/maximum 把原始值缩放为
0–100。macOS 对应的公开入口是 `IOHIDDeviceGetValue`，feature 元素会触发读取报告，
input 元素返回最近一次报告的值。

因此“标准 HID 电量”由程序枚举 HID element 并读取，而不是伪造一个对所有 VID/PID
发送相同字节的 JSON 规则。项目现已加入标准 element monitor，并支持同时读取多个
USB HID 设备；JSON 执行器继续只处理厂商 raw report。

## 厂商协议结论

| 家族 | 公开依据 | 能否直接批量生成当前 JSON 规则 |
|---|---|---|
| Logitech HID++ | Logitech 官方 HID++ 2.0 文档公开 `0x1000` Battery Unified Level Status；Linux 与 libratbag 同时实现 HID++ 1.0/2.0 | 不能按 Logitech VID 全开。接收器可有 1–6 个设备槽，产品支持的 battery feature 也不同；必须确认 receiver PID、槽位和 feature |
| Razer | OpenRazer 驱动包含 0–255 电量值和厂商命令 | 不能。报文长度、事务 ID、CRC、busy/status 和设备 generation 不同，超出当前“整帧求和”校验模型 |
| SteelSeries | Linux `hid-steelseries.c` 只对明确产品和 report 格式读取 | 不能按品牌泛化；鼠标、耳机和接收器并非同一电量协议 |
| 其他 libratbag 设备 | libratbag 的设备数据库把产品匹配和 backend 分开 | 设备列入数据库不等于电量报文相同；只有确认 backend 的读电量路径后才能迁移 |

项目内置规则因此只保留已在实机日志验证的 G304/G305 和 Lofree/Compx。Lofree 的
在线响应为 `08 03 00 00 00 81 ...`，在线标志是偏移 5 的 `0x81`；此前检查偏移 6
的 `0x01` 会把接收器错误判为离线，现已更正。

## 一手来源

- [USB-IF HID 规范入口](https://www.usb.org/hid)
- [USB-IF HID Usage Tables 1.5](https://usb.org/sites/default/files/hut1_5.pdf)
- [Apple IOHIDDeviceGetValue](https://developer.apple.com/documentation/iokit/1588657-iohiddevicegetvalue)
- [Apple IOHIDElementGetUsage](https://developer.apple.com/documentation/iokit/1564126-iohidelementgetusage)
- [Linux hid-input.c](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-input.c)
- [Linux hid-logitech-hidpp.c](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-logitech-hidpp.c)
- [Logitech HID++ 2.0 文档](https://github.com/Logitech/cpg-docs/blob/master/hidpp20/README.rst)
- [libratbag](https://github.com/libratbag/libratbag)
- [OpenRazer](https://github.com/openrazer/openrazer)
