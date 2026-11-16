# Nikon USB Export 1.0（macOS）

## 功能

- 通过 USB（MTP/PTP）浏览 Nikon Z 8 的存储卡、拍摄目录和缩略图。应用根据机身卷标和存储标识识别卡槽，未识别的存储卡仅供浏览。
- 按所选照片、目录（含子目录）、整卡或双卡导出 NEF、JPEG、HEIF 和 TIFF 原片。目标路径保留卡号和机内目录，例如 `卡2/DCIM/100NCZ_8/DSC_0001.NEF`。
- 目标文件同名且字节数相同时跳过。大小不同时保留已有文件，并记录冲突路径和两侧的字节数。

## 构建

使用 Xcode 27.2 构建，应用最低支持 macOS 14。将 SDK 原包放在 `Dependencies/NikonRemoteSDK/2.1.0/S-SDKZ-210BF-ALLIN.zip`，在仓库根目录执行以下命令。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project NikonUSBExport.xcodeproj -scheme NikonUSBExport \
  -configuration Release -derivedDataPath build build
```

产物位于 `build/Build/Products/Release/Nikon USB Export.app`。在 Xcode 中选择 `NikonUSBExport` scheme，按 ⌘U 运行测试。

## 第三方组件

**Nikon Remote SDK 2.1.0** 提供 MAID 接口，供 `NikonSDKService` 识别机身和读取存储标识。构建脚本校验原包的 SHA-256，将 `TypeCommon Module.bundle`、`Royalmile.framework`、`libNkPTPDriver2.dylib` 和配套配置嵌入 XPC 服务。原片通过 macOS 的 ImageCaptureCore 读取。[尼康 SDK 申请与下载](https://sdk.nikonimaging.com/apply/guide)
