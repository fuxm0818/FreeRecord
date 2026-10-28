# 权限说明（macOS 隐私授权）

FreeRecord 是常驻菜单栏的 App，能用到四类权限。本文说明**每项权限用在哪、必须授权吗、怎么授权、以及重新编译后为什么会失效**。

## 一览

| 权限 | 用途 | 是否必需 | 不授权会怎样 |
|---|---|---|---|
| 屏幕录制（ScreenCapture / Screen Recording） | 采集整屏、窗口、区域画面 | **必需** | 开始录制时提示去授权，画面全黑或直接失败 |
| 麦克风（Microphone） | 录制麦克风人声 | 选择麦克风音轨时必需 | 音轨里没有麦克风声音 |
| 摄像头（Camera） | 「摄像头」模式的自拍录制 | 仅摄像头模式 | 摄像头画面为黑 |
| 辅助功能（Accessibility） | —— | **不需要** | 鼠标点击高亮用 `NSEvent.addGlobalMonitorForEvents`，只读鼠标事件，不触发授权框 |

系统声音：macOS 13 及以上由 ScreenCaptureKit 直接采集，无需额外权限；macOS 12 需要安装免费的开源虚拟声卡 [BlackHole](https://existential.audio/blackhole/)，App 内「设置 → 系统声音」会给出安装入口。

## 屏幕录制授权步骤

1. 打开 FreeRecord 主窗口，未授权时首页顶部会有权限横幅，点「去系统设置授权」（或系统设置 → 隐私与安全性 → 屏幕与系统音频录制）。
2. 在列表中找到「自由录屏 / FreeRecord」，打开开关。
3. **完全退出 App 再重新打开**。FreeRecord 常驻菜单栏，关窗口不算退出——右键菜单栏图标选「退出」，或用主窗口的退出入口。
4. 部分情况下（尤其是换了签名身份之后）需要先重置旧的授权记录：App 内设置页的「重置授权记录」按钮等价于

   ```bash
   tccutil reset ScreenCapture com.fuxiangming.freerec
   ```

   然后回到第 2 步重新授权。

## 为什么每次重新打包，授权就"莫名其妙"失效了

macOS 的 TCC 授权不是按 bundle id 记的，而是按**代码签名身份（designated requirement）**记的。默认 `codesign --sign -` 是 ad-hoc 签名，每次构建产物的 cdhash 都不同，系统会把它当成"另一个 App"：

- 系统设置里的开关看着还是打开的（那是上一条记录的残留显示）；
- 但 App 内 `CGPreflightScreenCaptureAccess()` 永远返回 false。

这是本项目最容易踩的坑，`scripts/build.sh` 已针对它做了处理：

- 构建脚本会优先使用钥匙串里的 **`FreeRec Dev`** 自签名证书（可用环境变量 `CODESIGN_IDENTITY` 覆盖）；
- 证书的设计要求是 `identifier + certificate root`，跨构建稳定，**授权可以长期保留**；
- 找不到该证书时自动退回 ad-hoc，并在构建日志里明确警告「每次构建都会让屏幕录制授权失效」。

首次给公开分发之外的自己使用时，建议跑一次：

```bash
bash scripts/create-signing-cert.sh
```

该脚本只在你本机登录钥匙串里创建一张自签名证书，不上传任何信息。要撤销：

```bash
security delete-identity -c "FreeRec Dev" ~/Library/Keychains/login.keychain-db
```

> ad-hoc / 自签名证书签出的 App，在**别人**的机器上仍会被 Gatekeeper 拦一次：下载后需要右键 →「打开」，或在系统设置 → 隐私与安全性里点「仍要打开」。要做到双击直接打开，需要 Apple Developer ID 签名 + 公证，见 `CONTRIBUTING.md` 的发布章节。

## 授权状态判定与自动续录

- 点「开始录制」时先做一次 `CGPreflightScreenCaptureAccess()`；未授权则**记住这次的目标和参数**并弹窗提示。
- 你在系统设置里打开开关后切回 FreeRecord（App 被激活），会自动用原来的目标和参数继续开始录制，不需要再点一次。
- 权限开关打开后，正在运行的进程也能读到最新授权状态；但如果仍显示未授权，说明签名身份变了，需要「重置授权记录」再授权。

## 摄像头与麦克风

这两项由系统在第一次调用时自动弹框，同意后记录在 TCC 中；文案来自 `Resources/App-Info.plist` 的 `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`。修改文案后必须重新打包才会生效。
