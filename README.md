# 高效Todo App

Flutter 客户端使用一套 Dart 源码构建 Android 和 iOS 应用，版本为 `7.4.3+119`。本仓库包含 App 页面、离线数据、同步客户端和双端构建工程。Java 服务端在独立的 [gxtoudo-server](https://github.com/hysgit/gxtoudo-server) 仓库维护，使用 PostgreSQL 和 MinIO。

| 路径 | 内容 |
| --- | --- |
| `lib/home.dart` | 时间轴、任务列表、项目和便签首页 |
| `lib/task_editor.dart` · `lib/catalog.dart` | 任务、项目和分类编辑 |
| `lib/note_editor.dart` · `lib/notes.dart` | 便签文字、原图、录音、语音输入和日期筛选 |
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

Codemagic 配置位于仓库根目录的 `codemagic.yaml`。推送 `main` 会构建 iOS Simulator 包；Android APK 按本地构建流程生成，Codemagic 中的 Android debug 工作流仅手动运行。安装到 iPhone 使用手动工作流“高效Todo iOS TestFlight”：它以 App Store 分发签名生成 IPA，并上传到 TestFlight 内部测试，不会提交公开 App Store 审核。

首次启用 TestFlight 前，需在 App Store Connect 创建对应 App 记录和内部测试组“高效Todo 内测”，并在 Codemagic 连接可管理此 App 的 App Store Connect API key。测试者通过 TestFlight 安装，不需要开启 iPhone 开发者模式。

Bundle ID 为 `net.icycloud.fdtodolist`，部署目标为 iOS 15。iOS Simulator 工作流仍用于生成模拟器构建包，不能安装到真机。

## API 联调

服务端需提供 `/api/v7` 下的账户、团队、消息、评论和同步接口。Flutter 请求使用 POST JSON，`_method` 表示逻辑 GET 或 PUT。成功响应为 `status: "0"`，登录响应包含 `user_id`、`login_id`、`token`、`data` 和 `teamData`。

使用独立的测试服务和数据库运行下面的命令，测试会创建临时账号。

```sh
flutter test test/live_api_test.dart --dart-define=GXTODO_TEST_SERVER=http://127.0.0.1:8765 --dart-define=GXTODO_DEV_HTTP=true
```

测试覆盖两个客户端会话之间的任务新增、修改和删除。未指定 `GXTODO_TEST_SERVER` 时，该项联调测试自动跳过。

## 当前功能范围

已实现时间轴、任务、项目、多媒体便签、重复日程、标签、地点字段、子任务、系统闹钟、统计、个人文字备份和团队协作。原服务的会员支付、第三方登录、云头像、地图 SDK、桌面小组件和后台推送仍需后续接入。

便签有独立标题，外层列表显示标题与创建时间。进入便签后是按时间排列的文字、图片和语音会话，每条内容都有自己的时间，不显示附件的文件名或手机路径。输入文字后点击“发送”立即保存到本机；选择图片或结束录音后自动保存。标题修改自动保存，便签不再显示“保存”按钮。长按内容可以编辑文字或删除该条记录。

图片在加入时复制原始字节，录音结束后复制 AAC/M4A 文件至 Application Support 下的 `note-files` 持久目录。保存操作仅等待本机 SQLite 事务完成；不调用上传接口。附件原文和会话记录在 App 重启后仍可读取。清理系统相册缓存不会删除 App 自己的原图副本。

登录后，独立后台队列先上传附件，再提交对应消息；文字不必等待失败的图片上传。队列与本地数据一起持久化，上传回执只更新附件字段，重试复用稳定的客户端标识。下载的原图和录音会校验 SHA-256 并保留本地副本。未登录的便签照常本地保存，之后可通过“导入本机离线数据”迁入登录账号同步。

App 开着时自动同步并重试失败项；Android 使用 WorkManager 的联网任务和周期任务，iOS 使用 BGAppRefresh/BGProcessing。iOS 的执行时间由系统决定，强制结束 App 后无法承诺继续立即上传；重新打开或返回 App 会自动补同步。后台处理不持有 SQLite 事务进行网络传输。

“录音”保存声音文件；“语音转文字”使用手机系统语音识别，将结果插入光标处，可继续编辑。需要麦克风和系统语音识别权限，部分设备的识别服务需要网络；服务器不执行语音识别。识别与录音不能同时启动。App 进入后台会结束录音并把文件保留在本地编辑页，点击“保存”后加入同步队列。

旧版纯文字和附件便签按原创建时间显示，首次保存时迁入独立消息记录；标题可单独修改。继续支持全部、按年、按日期筛选以及便签标题和正文搜索。每张图片、每条录音最多 100 MB。

本机 JSON 备份包含会话数据和附件索引，不嵌入文件本体；完整备份还需保留本机文件目录，或服务端 PostgreSQL 与 MinIO 备份。

任务列表中，未完成任务按计划时间升序，未安排任务在待完成区末尾；已完成任务按实际完成时间降序，最近完成的位于最上方。

主列表采用紧凑平铺行，保留日期、提醒和任务优先级信息；没有日期的任务只占一行。新增按钮改为带语义提示的加号。四个主页面从屏幕左侧 24 点边缘向右滑切到下一个空间，从右侧边缘向左滑切到上一个空间，按空间菜单顺序循环。中央横滑、边缘短滑、反方向滑动和上下滚动不切换空间。左上角菜单仍可点开。

时间轴日历下方不再重复显示大号日期标题，任务行不再显示左侧优先级彩色竖线；优先级数据和任务编辑选项保留。
