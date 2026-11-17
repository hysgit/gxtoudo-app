# 高效Todo App

Flutter 客户端使用一套 Dart 源码构建 Android 和 iOS 应用，版本为 `7.2.0+112`。本仓库包含 App 页面、离线数据、同步客户端和双端构建工程。服务端通过 HTTP API 独立连接。

| 路径 | 内容 |
| --- | --- |
| `lib/home.dart` | 时间轴、任务列表、项目和便签首页 |
| `lib/task_editor.dart` · `lib/catalog.dart` | 任务、项目、便签和分类编辑 |
| `lib/tasks.dart` · `lib/schedule.dart` | 任务、完成记录和重复日程规则 |
| `lib/repository.dart` · `lib/domain.dart` | SQLite 本地存储及数据模型 |
| `lib/api.dart` · `lib/sync.dart` · `lib/controller.dart` | 账户、服务端地址和增量同步 |
| `lib/cloud_pages.dart` | 团队、消息、评论和参与人 |
| `lib/reminders.dart` · `lib/backup_page.dart` | 系统提醒和个人空间备份 |
| `android/` · `ios/` | 平台工程和签名配置 |
| `test/` | 业务规则、界面和 API 联调测试 |

## 开发

使用 Flutter 3.50.0 和 Dart 3.14。用 Android Studio 或 VS Code 打开仓库根目录后执行。

```sh
flutter pub get
flutter analyze
flutter test
```

App 可离线录入个人任务和便签。Codemagic 构建和 App 默认连接 `https://tudosrv.woslx.com`。Android 和 iOS 均通过 HTTPS 与服务端通信。

## Android 构建

使用 Flutter 3.50.0、JDK 21、Android SDK 36、Android Gradle Plugin 9.3.1、Build Tools 36.0.0 和 NDK 28.2.13676358。

```sh
flutter build apk --debug
```

APK 位于 `build/app/outputs/flutter-apk/app-debug.apk`。本机联调可指定 `--dart-define=GXTODO_DEV_HTTP=true`，该开关允许使用 localhost、127.0.0.1 和 10.0.2.2 的 HTTP 地址。Android 模拟器使用 `http://10.0.2.2:8765` 访问电脑服务，USB 调试可用 `adb reverse tcp:8765 tcp:8765` 转发后访问 `http://127.0.0.1:8765`。

正式发布前设置 `GXTODO_KEYSTORE`、`GXTODO_KEYSTORE_PASSWORD`、`GXTODO_KEY_ALIAS` 和 `GXTODO_KEY_PASSWORD` 环境变量，然后执行。

```sh
flutter build appbundle --release
```

包名为 `net.icycloud.fdtodolist`。覆盖原正式 APK 需要原签名密钥。版本名称和构建号在 `pubspec.yaml` 中修改。

## iOS 构建

Codemagic 配置位于仓库根目录的 `codemagic.yaml`。导入 `hysgit/gxtoudo-app` 后，推送 `main` 会在个人账户每月 500 分钟的免费 macOS 构建额度内构建 Android debug APK 和 iOS Simulator 包。仓库使用公开 Git URL 导入。

Codemagic 工作流当前会生成可安装的 Android debug APK 和 iOS Simulator 构建包。iPhone IPA 还需要 Apple Developer Program 账户及 App Store 签名配置，签名设置完成后可按 Codemagic 文档添加 IPA 发布工作流。Simulator 构建包不能直接安装到真机。

```sh
flutter pub get
flutter build ios --simulator --dart-define=GXTODO_SERVER=https://tudosrv.woslx.com
```

要构建可安装到 iPhone 的 IPA，需先在 Runner 目标配置 Apple Team 和签名，然后在 macOS 上运行 `flutter build ipa --release --dart-define=GXTODO_SERVER=https://tudosrv.woslx.com`。Bundle ID 为 `net.icycloud.fdtodolist`，部署目标为 iOS 15。

## API 联调

服务端需提供 `/api/v7` 下的账户、团队、消息、评论和同步接口。Flutter 请求使用 POST JSON，`_method` 表示逻辑 GET 或 PUT。成功响应为 `status: "0"`，登录响应包含 `user_id`、`login_id`、`token`、`data` 和 `teamData`。

使用独立的测试服务和数据库运行下面的命令，测试会创建临时账号。

```sh
flutter test test/live_api_test.dart --dart-define=GXTODO_TEST_SERVER=http://127.0.0.1:8765 --dart-define=GXTODO_DEV_HTTP=true
```

测试覆盖两个客户端会话之间的任务新增、修改和删除。未指定 `GXTODO_TEST_SERVER` 时，该项联调测试自动跳过。

## 当前功能范围

已实现时间轴、任务、项目、便签、重复日程、标签、地点字段、子任务、系统本地提醒、统计、个人备份和团队协作。原服务的会员支付、第三方登录、云头像、地图 SDK、语音、桌面小组件和后台推送仍需后续接入。
