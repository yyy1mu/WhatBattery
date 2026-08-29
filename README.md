# WhatBattery

WhatBattery 是一个原生 macOS 菜单栏外设电量监控器。它读取配置中声明的 USB
HID 电池协议、标准 BLE Battery Service，以及 macOS 系统提供的蓝牙与 Apple
配件电量。

应用完全在本机工作，不上传设备信息。为了读取 macOS 只在系统报告中提供的传统
蓝牙和耳机分电池数据，应用没有启用 App Sandbox；蓝牙访问仍由 macOS 隐私权限
控制。

## 功能

- 菜单栏始终显示当前可用设备中的最低电量
- 点击菜单栏图标查看所有可用设备和耳机左、右、充电盒电量
- USB 设备只有实际连接并成功读取电量后才显示
- 自动读取 HID descriptor 中声明的标准 Battery Strength/State of Charge 元素
- 普通第三方蓝牙离线缓存不会显示
- macOS 可能不给 AirPods 等 Apple 配件可靠的连接标记；本次系统快照仍提供电量
  时会保留显示，并标记为“最近电量”
- 默认每 5 分钟刷新，也支持 `⌘R` 手动刷新
- 设置中的“历史”页按设备展示 24 小时、7 天或 30 天的平滑电量曲线
- 历史记录仅在电量或充电状态变化时写入；长时间无变化时每 6 小时保留一个采样点
- 设置中可选择跟随系统、简体中文或英文；重启应用后全局生效
- 无主窗口、Dock 图标或 Command-Tab 项目

规则文件当前描述了：

- Logitech G304/G305 LIGHTSPEED 的 HID++ 2.0 Battery Status 请求
- Lofree/Compx 2.4 GHz 键盘的 17 字节厂商 HID 请求

这两个设备没有对应的专属 Swift 驱动。VID、PID、报文、动态变量、校验、重试、
响应条件和电量字段都在 JSON 中。

## 目录

```text
WhatBattery/
├── App/
│   ├── MenuBar/                 菜单栏标签、设备列表和电量量表
│   ├── Settings/                语言、电量历史和设备规则设置
│   └── WhatBatteryApp.swift
├── Core/
│   ├── Models/                  规则、协议定义与电量模型（每类一个文件）
│   ├── Monitoring/              设备生命周期、轮询与历史记录
│   └── Rules/                   JSON 规则加载和校验
├── Infrastructure/
│   ├── Bluetooth/               BLE、IORegistry、system_profiler
│   └── HID/                     通用 HID 发现、传输和协议执行器
├── Support/                     日志与重启工具
├── DeviceRules.json             首次运行使用的主规则文件模板
└── Assets.xcassets

WhatBatteryTests/                目录结构与源码一一对应
├── App/                         应用层测试
├── Core/                        监控与规则测试
└── Infrastructure/              蓝牙与 HID 协议测试
```

代码约定：`App` 只放 SwiftUI 视图和入口；`Core` 放与系统无关的模型和监控
逻辑（可通过协议注入 mock，全部在测试中覆盖）；`Infrastructure` 放所有
IOKit、CoreBluetooth、`system_profiler` 等系统交互实现。依赖方向固定为
`App → Core → Infrastructure`，反向不引用。

## JSON 驱动的 HID 协议

设备规则 schema 当前版本是 `2`。下面是一个简化示例：

```json
{
  "schemaVersion": 2,
  "catalogMode": "complete",
  "rules": [
    {
      "id": "example.receiver",
      "displayName": "Example Mouse",
      "symbolName": "computermouse",
      "match": {
        "deviceIDs": [
          { "vendorID": "0x1234", "productID": "0x5678" }
        ],
        "transport": "USB",
        "usagePage": "0xFF00",
        "usage": null,
        "usageMatch": "primary",
        "minimumInputReportLength": 8,
        "minimumOutputReportLength": 8
      },
      "protocol": {
        "reportID": "0x08",
        "reportLength": 8,
        "requestTimeoutMilliseconds": 500,
        "maximumAttempts": 3,
        "retryOnTimeout": true,
        "responseEchoes": [
          { "responseOffset": 0, "requestOffset": 0, "length": 2 }
        ],
        "steps": [
          {
            "id": "read-battery",
            "request": ["0x08", "0x04"]
          }
        ],
        "battery": {
          "levelOffset": 6,
          "chargingOffset": 7,
          "voltageHighOffset": null,
          "voltageLowOffset": null
        }
      },
      "pollingIntervalSeconds": 300,
      "requiresInputMonitoring": false
    }
  ]
}
```

优先使用 `deviceIDs` 写出准确的 VID/PID 组合，并为 USB 厂商协议设置
`"transport": "USB"`。程序只有在 macOS 实际枚举到完全匹配的 HID interface 后
才会打开它并执行协议步骤；规则文件中存在一条规则不代表设备在线。旧的
`vendorIDs` + `productIDs` 写法仍然兼容，但多个数组值会形成宽泛组合，只适合
确实共享同一协议的一组设备。

同一文件根部的 `systemAccessoryRules` 配置 Apple vendor ID、产品名关键词和
键盘、鼠标、触控板、耳机等类型匹配。蓝牙 Swift 代码只解析系统字段并执行这些
规则，不包含具体产品名单。

请求数组不足 `reportLength` 的部分自动补零。字节可以写十进制或 `0x` 十六进制。
协议还支持：

- `variables`：初始一字节变量
- `captures`：从某一步响应中捕获变量
- `"$variable"`：在后续请求中使用变量
- `runOnce`：连接期间只执行一次的发现步骤
- `requirements`：按响应字节判断 `peripheralOffline` 或 `unsupported`
- `checksum`：生成并校验“整帧字节和等于目标值”的校验字节
- `errorResponse`：声明错误报文、错误码和可重试错误
- `chargingOffset`、`voltageHighOffset`、`voltageLowOffset`：可选电池元数据

因此 HID++ 动态 feature index 和多步键盘查询都由相同执行器完成。只有协议需要的
运算超出这些声明能力时，才需要扩展通用配置模型，而不是增加产品命名的 Swift
文件。

## 规则文件

打开菜单栏弹窗，进入“设置…”，点击“显示规则目录”。应用会创建并打开：

```text
Application Support/WhatBattery/
├── device-rules.json
└── device-rules.d/
    ├── 10-logitech.json
    └── 20-keyboards.json
```

`device-rules.json` 是主目录，`device-rules.d` 中可以放任意数量的 `.json` 规则
目录。程序先读取主文件，再按不区分大小写的文件名顺序读取扩展文件，因此可用数字
前缀稳定控制顺序。每个文件都使用相同的 schema 2 根结构；扩展文件可只包含
`schemaVersion` 和 `rules`。单个扩展文件损坏不会阻止其他文件加载；跨文件出现相同
`id` 时保留先加载的规则并在设置页报告问题。`systemAccessoryRules` 也只能由第一个
包含它的文件定义。

应用不会扫描其他目录，也不会在升级时从网络下载或执行未知报文。首次运行时，应用
会把随包的 `DeviceRules.json` 模板复制为主文件，此后 HID 设备协议、Apple 配件识别
和设备类型分类都以这些可编辑文件为准。编辑后点击“重新加载规则”，不需要重新编译。
旧双来源版本留下的空文件或覆盖文件会在首次加载时升级为完整目录：模板中的规则
作为基础，同 `id` 的旧规则覆盖模板，额外规则继续保留。设置页的规则开关只决定
哪些设备协议生效，不会从规则文件中删除 G304、Lofree 或 Apple 配件定义。
旧的非空 schema 1 驱动 ID 配置不再兼容，需要迁移到 schema 2 的 `protocol` 字段。

不要创建两条会同时匹配同一个 HID interface 的规则，否则两个会话可能争用同一
条厂商协议通道。

程序会自动枚举当前 USB HID 设备公开的标准电量 element，并根据 descriptor 的
logical minimum/maximum 换算为百分比；这条只读路径不需要为每个 VID/PID 建规则。
USB HID 没有适用于所有鼠标和键盘的厂商查询报文。USB HID Usage Tables 定义了
Generic Device Controls 的 `Battery Strength`（usage page `0x06`、usage `0x20`）
和 Battery System 的相对/绝对荷电状态（page `0x85`、usage `0x64`/`0x65`），但设备
必须真的在 HID report descriptor 中声明这些元素。未声明时只能使用经过设备协议或
上游驱动验证的厂商规则；不能只根据品牌 VID 猜命令。协议调研结论与来源见
[`Docs/DeviceBatteryProtocolResearch.md`](Docs/DeviceBatteryProtocolResearch.md)。

## 电量历史

打开菜单栏弹窗，进入“设置…”，在“历史”页选择设备与时间范围。应用保存最近 30 天
成功读取的 USB HID、BLE、蓝牙和 Apple 配件电量；AirPods 等多组件设备会分别显示
左耳、右耳和充电盒曲线。在曲线上选择时间点可以查看精确电量。

历史文件保存在：

```text
Application Support/WhatBattery/battery-history.json
```

可在历史页右上角清除全部记录。记录只保存在本机，不会上传。

## 权限

部分键盘接收器把厂商协议和按键输入放在同一个 HID interface，macOS 会要求
“系统设置 → 隐私与安全性 → 输入监控”权限。设置页提供“检查受保护键盘的电量”
开关：开启后应用会检查权限并提醒授权，同时运行所有
`requiresInputMonitoring: true` 的设备规则；关闭后这些规则会被完全跳过，也不会
检查或请求输入监控权限。

首次读取 BLE 电量时，macOS 可能请求蓝牙权限。应用不发起配对，也不保存按键或
音频数据。

## 开发与测试

系统要求：macOS 14 或更高版本、Xcode 16 或更高版本。

```bash
xcodebuild test \
  -project WhatBattery.xcodeproj \
  -scheme WhatBattery \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

推送形如 `v26.0.1` 的版本标签会触发 GitHub Actions，运行测试、构建 `arm64 + x86_64`
Release App，并上传压缩包与 SHA-256。CI 使用 ad-hoc 签名，没有 Apple 公证；公开
分发前应配置 Developer ID 和 notarization。
