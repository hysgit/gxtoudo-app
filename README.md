# 高效Todo App

Android 和 iOS 使用 Flutter。网页版位于 `web/`，在浏览器中使用移动 App 扫码登录。Java 服务端在独立的仓库维护，使用 PostgreSQL 和 MinIO。[gxtoudo-server](https://github.com/hysgit/gxtoudo-server)

| 路径 | 内容 |
| --- | --- |
| `lib/home.dart` | 任务列表、时间轴、记账和便签首页 |
| `lib/task_editor.dart` · `lib/catalog.dart` | 任务、标签和地点编辑 |
| `lib/note_editor.dart` · `lib/notes.dart` | 便签文字、原图、录音、语音输入和日期筛选 |
| `lib/tasks.dart` · `lib/schedule.dart` | 任务、完成记录和重复日程规则 |
| `lib/repository.dart` · `lib/domain.dart` | SQLite 本地存储及数据模型 |
| `lib/api.dart` · `lib/sync.dart` · `lib/controller.dart` | 账户、服务端地址和增量同步 |
| `lib/cloud_pages.dart` | 团队、消息、评论和参与人 |
| `lib/reminders.dart` · `lib/backup_page.dart` | 系统提醒和个人空间备份 |
| `android/` · `ios/` | 手机端平台工程和签名配置 |
| `web/` | 网页界面、同源 API 代理、浏览器持久化和测试 |
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

## 启动网页版

使用 Node.js 24。从 App 仓库根目录运行。

```powershell
node web/server.mjs
```

打开 [本机网页版](http://127.0.0.1:18120)。在已登录的手机 App 打开「账户与服务端」→「扫码登录桌面端」，核对页面与手机显示的六位数字后确认。该菜单沿用旧名称，二维码两分钟内有效。

网页版支持任务、周时间轴、精确金额记账、速记、精髓、内核和 AI 对话。登录后编辑先写入当前浏览器的 IndexedDB，页面打开期间自动同步到 Java 服务。离线时已打开的工作台可以继续编辑。旧桌面版已同步的记录会从同一账号下载。旧桌面版独有的本地数据需要从旧版导出或用旧版同步。

网页代理默认请求 `https://tudosrv.woslx.com`。容器部署时设置 `GXTODO_WEB_ORIGIN` 为用户实际访问的 HTTPS 来源，通过反向代理转发公网请求。按需设置 `GXTODO_UPSTREAM` 和手机端已配置的 `GXTODO_QR_ORIGIN`。代理持有会话并通过 HttpOnly Cookie 标识浏览器，重启后用户需要重新扫码。

```powershell
docker build -t gxtodo-web web
docker run --rm -p 127.0.0.1:18120:18120 -e GXTODO_WEB_ORIGIN=https://todo.example.com gxtodo-web
node --test web/test/gateway.test.mjs
```

浏览器测试可运行 `node web/test/browser.mjs "<Chrome 或 Edge 的可执行文件路径>" "<截图目录>"`。它启动隔离的测试服务和浏览器配置。二维码绘制使用 [Nayuki QR Code generator](https://www.nayuki.io/page/qr-code-generator-library) 的 MIT 许可实现，声明见 `web/public/qrcodegen.mjs`。

## API 联调

服务端需提供 `/api/v7` 下的账户、团队、消息、评论和同步接口。Flutter 请求使用 POST JSON，`_method` 表示逻辑 GET 或 PUT。成功响应为 `status: "0"`，登录响应包含 `user_id`、`login_id`、`token`、`data` 和 `teamData`。

使用独立的测试服务和数据库运行下面的命令，测试会创建临时账号。

```sh
flutter test test/live_api_test.dart --dart-define=GXTODO_TEST_SERVER=http://127.0.0.1:8765 --dart-define=GXTODO_DEV_HTTP=true
```

测试覆盖两个客户端会话之间的任务新增、修改和删除。未指定 `GXTODO_TEST_SERVER` 时，该项联调测试自动跳过。

## 当前功能范围

已实现任务、时间轴、记账、多媒体便签、重复日程、标签、地点字段、子任务、系统闹钟、统计、个人文字备份和团队协作。原服务的会员支付、第三方登录、云头像、地图 SDK 和桌面小组件仍需后续接入。

任务的「系统推送」由服务端读取已同步的提醒，并在到点时通过 APNs 或 FCM 投递。手机首次使用需要打开 App 登录、允许通知并完成设备注册。Android 构建前把 Firebase Android 应用的 `google-services.json` 放在 `android/app/`，包名为 `net.icycloud.fdtodolist`，接收端需要 Google Play 服务。iOS 构建需要在 Apple Developer 的 App ID 开启 Push Notifications，并使用包含 `aps-environment` 的描述文件。发布前分别在两端验证锁屏、退出 App 和跨设备修改提醒。

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

## 记账

底部顺序为“任务、时间轴、记账、便签”。项目入口和任务编辑页的项目选择移除，现有任务和历史数据仍可读取。

记账按当前空间保存，默认仅所属账号可见，自己的设备间自动同步。本月显示当月账单；已归档按“年 → 月”展开，选择月份后显示该月明细和汇总。账单列表仅展示日期、类型、金额、途径、支出方/收入方、事项。

新增账单依次录入日期（默认当天）、支出/收入/内转、金额、途径、支出方/收入方、事项、地点、备注及附件。定位使用系统的仅使用期间权限；拒绝或暂时失败时仍能保存。定位结果仅在新增或手动刷新时请求，历史账单编辑不会自动覆盖原地点。新增途径和收支方作为账号内通用选项持久保存并同步。

金额以十进制字符串保存，客户端使用 BigInt 定点运算，Java 使用 BigDecimal 校验。至少显示两位小数，保留输入的更高小数精度，最多 30 位整数和 18 位小数。月汇总显示总支出、总收入及各支出方支出；内转单独记录，不计入收支合计。

备注附件支持多张原图、拍照、多条录音及多个普通文件。单文件上限 100 MB。保存先写本地 SQLite 与持久文件目录，后台队列上传到私有 MinIO；下载校验后在本机保留副本。普通文件按原文件扩展名保存，可交给手机支持的应用打开。
