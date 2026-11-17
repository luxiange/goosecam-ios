# 鹅相机 iOS（GooseCam）

安卓版「鹅相机 v0.30」的苹果版本，原生 Swift + SwiftUI + AVFoundation 实现，功能与安卓 0.30 一一对齐。

## 功能对照

| 功能 | 安卓 0.30 | iOS 本版 | 说明 |
| --- | --- | --- | --- |
| 4:5 取景框 | CameraX PreviewView + 4:5 FrameLayout | AVCaptureVideoPreviewLayer + aspectRatio(4:5) | 相同留边 20pt、顶部 36pt |
| 三档焦段 23/75/120mm（1x/3x/5x） | cameraControl.setZoomRatio | AVCaptureDevice.videoZoomFactor | iPhone 13 无长焦，3x/5x 为数码变焦 |
| 当前焦段黄色高亮 | #FFD24A | #FFD24A | 未选白色 |
| 点按对焦（白框→绿框） | FocusMeteringAction | focusPointOfInterest + exposurePointOfInterest | 白框 0.25s 转绿，1.4s 消失 |
| 闪光灯常亮 | enableTorch | device.torchMode | 图标同款闪电 |
| 水平仪 | LevelView（重力传感器） | CoreMotion attitude.roll | 水平时转黄 |
| 三分线网格 | GridLinesView | Path 绘制 | 同样的 0.22 白色透明度 |
| 4:5 居中裁切（横拍 5:4） | M72Filter.cropTo4x5 | 同 | 同一套比例算法 |
| 逐像素 M72 调色 | M72Filter.applyM72 | M72Filter.applyM72 | 两遍式场景自适应，阈值逐条复刻 |
| 胶片颗粒 / 暗角 | Random(72) / 暗角 0.14 | LCG 种子 72 / 同系数 | |
| 黑色细边框（四角略深） | M72Filter.addBlackBorder | 同 | 侧边 1.3%、上下 1.1% |
| 拍照转圈提示 | ProgressBar | ProgressView | 处理完成消失 |
| 内置相册（网格 + 时间 + 全屏缩放 + 左右滑 + 多选删除） | GalleryActivity | GalleryView + PhotoViewer | 双指缩放 1–4 倍 |
| 左下角缩略图 | MediaStore 查询 | Documents/goosecam 最新一张 | |
| 设置：选择相机（E72 / 待开发） | SettingsActivity | SettingsView | 待开发不可选 |
| 设置：导入照片（多选 + 倒计时 + 完成提示） | GetMultipleContents + 后台线程 | PhotosPicker + 后台运算 | 每张约 3 秒估算 |
| 设置：中英切换 | LangHelper + recreate | @AppStorage("app_lang") | 全界面即时切换 |
| 设置：软件说明（版本/更新时间/开发者/邮箱） | strings.xml | L10n | 版本读 CFBundleShortVersionString |
| 拍视频 | **0.30 无此功能** | 同样不做 | 后续版本再对齐 |

## 目录结构

```
GooseCam-iOS/
├── project.yml                  # XcodeGen 工程描述（CI 上生成 .xcodeproj）
├── .github/workflows/build-ipa.yml   # GitHub Actions：macOS 出无签名 IPA
└── GooseCam/
    ├── Info.plist               # 权限文案、竖屏、文件共享
    ├── GooseCamApp.swift        # @main
    ├── CameraScreen.swift       # 主界面
    ├── CameraSession.swift      # 采集会话（变焦/焦点/补光/拍照）
    ├── CameraPreview.swift      # 取景层（UIViewRepresentable）
    ├── M72Filter.swift          # 调色算法核心
    ├── PhotoStore.swift         # 落盘、缩略图、系统相册写入
    ├── GalleryView.swift        # 相册 + 全屏查看
    ├── SettingsView.swift       # 设置 + 导入批处理
    ├── Views.swift              # 水平仪 / 网格 / 对焦框
    ├── Lang.swift               # 中英文案
    └── Assets.xcassets          # AppIcon（1024，来自安卓图标）+ 玛米亚图案
```

## 构建（GitHub 云端 macOS）

推送到 GitHub 后自动触发 `.github/workflows/build-ipa.yml`：

1. `macos-15` runner，`brew install xcodegen`
2. `xcodegen generate` 生成 `GooseCam.xcodeproj`
3. `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO` 编译 **Release**（arm64）
4. 打包成 `GooseCam-unsigned.ipa`（Payload/GooseCam.app）
5. 作为 artifact 上传，供本机侧载工具签名安装

本地若有 Mac，也可 `xcodegen generate && open GooseCam.xcodeproj` 直接用 Xcode 编译。

## 侧载到 iPhone 13（Windows）

1. 装 iTunes（Apple 官网版，提供 Apple Mobile Device 驱动）与 Sideloadly
2. iPhone 用数据线连电脑，手机点「信任此电脑」
3. Sideloadly 拖入 `GooseCam-unsigned.ipa`，填 Apple ID，点 Start
4. 手机上「设置 → 通用 → VPN与设备管理」信任该开发者证书
5. 免费 Apple ID 的签名 **7 天失效**，到期用同样步骤重签一次（照片不会丢）

## 已知限制

- iPhone 13 只有广角 + 超广角，没有长焦：3x / 5x 是广角数码变焦，画质弱于原生长焦机型
- 免费 Apple ID 签名为 7 天有效期，且同时最多 3 个自签 App
- 照片存在 App 沙盒 `Documents/goosecam`（iOS 无公共 Pictures 目录），同时写入系统相册；开启文件共享后可在「文件」App 里看到
- 首次启动需要授予相机、相册（写入）权限
