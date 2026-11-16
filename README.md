# Nikon USB Export（iOS / iPadOS）

## 功能

- iPhone 和 iPad 通过 USB（MTP/PTP）读取 Nikon Z 8，支持导出所选照片、目录（含子目录）、整卡或双卡的原片。导出期间应用需保持在前台。设备直连 Z 8 的流程仍待真机验证。
- 原片按卡号和机内目录写入应用的 `Documents`，可在系统「文件」中访问。同名且字节数相同的文件会跳过，大小不同则保留已有文件并记录冲突。

## 构建

最低支持 iOS / iPadOS 17。用 Xcode 打开 `NikonUSBExportIOS.xcodeproj`，选择 `NikonUSBExportIOS` scheme。在模拟器上按 ⌘U 运行测试。安装到真机前，在应用目标的 Signing & Capabilities 中选择开发团队。

在仓库根目录执行以下命令可编译未签名的真机版本。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project NikonUSBExportIOS.xcodeproj -scheme NikonUSBExportIOS \
  -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## 第三方组件

无。应用通过 Apple 的 ImageCaptureCore 访问相机。
