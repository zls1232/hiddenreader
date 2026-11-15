# 闲阅（HiddenReader）—— 伪装成电子书的相册隐藏工具

这是一个**完整的 Xcode 工程**，双击 `HiddenReader.xcodeproj` 即可用 Xcode 打开、直接 Build。
表面上是一个电子书阅读 App；在「意见反馈」里输入密码 **789897** 并提交，进入隐藏的资料库。

## 功能
- 伪装成普通电子书：书架 + 假阅读页
- 隐藏入口：意见反馈 → 在「反馈内容」输入 789897 → 点「提交反馈」→ 进入资料库
- 从系统相册导入照片 / 视频到 App 私有目录
- 可选「导入后删除相册原图」（需相册权限，开启后导入即从系统相册抹掉）
- 长按缩略图 / 详情页：恢复到系统相册、彻底删除
- 数据存在 App 沙盒 Documents/HiddenVault，不联网、不云同步

## 要求
- iOS 16 及以上
- 编译：macOS + Xcode 14/15/16（或 GitHub Actions 云编译，无需 Mac）
- 安装：TrollStore（巨魔）直接装 .ipa，无需签名

## 工程结构
```
HiddenReader/
├── HiddenReader.xcodeproj          ← 双击用 Xcode 打开
├── HiddenReader/                   ← 源码（7 个 Swift 文件）
├── .github/workflows/build.yml     ← 云端自动编 .ipa
└── README.md
```

## 编译 + 安装

### 方法 A：有 Mac
1. 双击 `HiddenReader.xcodeproj`
2. 选 `Any iOS Device (arm64)`，Product → Build（或 Archive）
3. 得到 `HiddenReader.app` 后打包成 .ipa：
   新建 `Payload` 文件夹 → 把 .app 放进去 → 压缩成 zip → 改后缀为 `.ipa`
4. .ipa 传到手机，用巨魔安装

### 方法 B：无 Mac（GitHub Actions 云编译，推荐）
1. 把整个 `HiddenReader` 文件夹 push 到 GitHub 仓库（.xcodeproj 已共享 scheme，可直接用）
2. 仓库 → Actions → `Build TrollStore IPA` → Run workflow
3. 下载 artifact 里的 `HiddenReader.ipa`，传到手机用巨魔装

> 云编译已设置 `CODE_SIGNING_ALLOWED=NO`，产出的是未签名 .ipa，巨魔直接装。

## 使用方法
1. 打开 App，看到的是普通书架
2. 底部「意见反馈」→ 在「反馈内容」输入 `789897` → 点「提交反馈」
3. 进入资料库 → 右上角 + 导入照片 / 视频
4. 长按缩略图：恢复到相册 / 删除

## 注意
- 密码 789897 写在 `HiddenReader/FeedbackView.swift` 的 `submit()` 里，可自行修改
- App 显示名「闲阅」、相册权限描述已内置在工程里，无需手动配
- 开启「导入后删除相册原图」但原图仍残留：说明未匹配到原图或未授权，请在系统相册手动删除
- 删除、恢复均不可撤销，删除前请确认
