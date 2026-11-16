# Nikon USB Export（共享核心）

## 功能

macOS 和 iOS 共用的 Swift 包，通过 USB/PTP 读取 Nikon Z 8 的存储信息、目录、缩略图和原片。导出支持所选照片、目录、整卡或双卡，按卡号保留机内路径。同名且字节数相同的文件会跳过，大小不同则记录冲突。

## 构建

使用完整 Xcode 和 Swift 5.9 或更新版本的工具链。部署目标为 macOS 14 和 iOS 17。在 Mac 上从仓库根目录构建并运行离线测试。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
```

构建完整应用时，macOS 工程位于 `Nikon_USB_Export_MAC` 分支，iPhone 和 iPad 工程位于 `Nikon_USB_Export_IOS` 分支。

## 第三方组件

无。USB 通信使用 Apple 的 ImageCaptureCore。
