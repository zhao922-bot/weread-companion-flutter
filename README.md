# 微信读书伴侣 (WeRead Companion)

微信读书的 Android / Windows 伴侣应用：同步书架与笔记，离线随时看，AI 生成带引用回跳的读书摘要，一键导出金句卡片和 Markdown 笔记。

## 下载 v2.7.0

从 [GitHub Releases](https://github.com/zhao922-bot/weread-companion-flutter/releases/tag/v2.7.0) 下载 Android APK、Windows x64 自解压 EXE 或便携 ZIP。

- Windows EXE 解压部署到当前用户的 `%LOCALAPPDATA%\Programs\WeReadCompanion`，创建开始菜单快捷方式。ZIP 需完整解压后运行 `weread_companion.exe`，保留同目录 DLL 和 `data` 文件夹；数据库位于用户应用数据目录。
- Android APK 使用新发布签名，旧签名版本需先备份数据并卸载后安装。

## 功能

### 登录
- **微信扫码登录** — 手机微信扫码即可登录，无需手动复制 Cookie；token 自动刷新，过期无感续期
- **Cookie 导入** — 也支持手动粘贴 Cookie 登录
- 凭据（Cookie、AI Key）全部存入系统安全存储（flutter_secure_storage），不落明文

### 书架
- 网格展示书籍封面，3 列 / 4 列一键切换
- 按阅读状态筛选：全部 / 读完 / 在读中 / 接近读完 / 未读
- 搜索书名、作者；封面图片缓存，滚动流畅
- 登录后数据存本地，**断网也能离线浏览**

### 笔记与划线
- 全量浏览、全文搜索（中文 trigram 索引，300ms 防抖）
- 收藏 / 取消收藏，收藏视图独立筛选
- 游标分页加载，笔记再多也不卡
- 书籍详情页支持展开、复制、收藏单条笔记

### AI 摘要
- 为整本书生成结构化摘要，**每条结论带引用编号，点击回跳到原笔记**
- 摘要历史按书保存，可随时回顾
- 响应被截断时明确标记"未完成"并提示重试，不会把半截内容当完整摘要存下
- 支持自定义 API 地址、模型、Key（兼容 OpenAI 接口）

### 金句卡片
- 把喜欢的划线做成精美卡片，字号可调
- 导出高清 PNG：长引文自动分页渲染，像素预算防止内存爆炸
- 导出期间锁定引文与字号快照，切换内容不会导错图

### 阅读报告
- 阅读趋势、Top 5 书籍/笔记等多维统计
- 统计全部在 SQLite 内聚合完成，不把全库读进内存

### 笔记导出
- 一键导出为 Markdown，先生成临时磁盘快照，再以每批最多 500 条分批格式化、流式写入；导出内容保持一致，避免在 Dart 内存中保存全部笔记
- 先写临时文件、成功后原子替换，导出失败不会删掉旧文件
- 文件名带时间戳，同一天多次导出互不覆盖

### 数据同步
- **增量同步**：每本书独立游标，只拉取变化部分；同步中断后可断点续传
- 4 路有界并发，同步更快；单本书失败会列出清单并支持单独重试
- 账号间数据完全隔离：切换账号 / 退出登录自动清理本地数据与导出文件

## 工程特点

- **离线优先**：已同步的数据全部存本地 SQLite，无网络正常使用
- **多账号隔离**：每个账号独立数据库 + 独立同步游标
- **鲁棒的认证链路**：refreshToken 轮换、落盘失败降级、失效状态全局同步，避免"假登录"
- **性能优化**：数据库聚合、复合索引、游标分页、标签页懒加载、封面按需解码、搜索索引后台生成
- **旧库升级**：搜索索引按每批最多 100 条回填，进度与索引原子提交，中断后继续处理剩余批次
- **质量保障**：检查脚本要求全部自动化测试通过、`flutter analyze` 零问题，以及 `lib` 可执行 Dart 代码行覆盖 **100%**、分支覆盖 **100%**（Flutter 3.44.0 / Dart 3.12.0）。实测结果见 [更新日志](CHANGELOG.md)，默认检查执行 [100% 门槛](tool/coverage_audit.json)。

## 开发

### 环境要求
- Flutter 3.x + Dart 3.x
- Android SDK（打包 APK 用）
- Visual Studio C++ 桌面开发工具与 Windows SDK（打包 Windows 用）

### 运行与构建

```bash
# 安装依赖
flutter pub get

# 连接手机或启动模拟器后运行
flutter run

# 打包 release APK
flutter build apk --release
# 输出: build/app/outputs/flutter-apk/app-release.apk

# Windows 发布构建（包含 SQLite 和 VC++ 运行库）
flutter build windows --release
```

Android 发布构建需要自行配置未纳入版本管理的 `android/key.properties` 与 keystore。Windows 构建后运行 `./tool/package_windows.ps1`，使用 Windows 自带的 .NET Framework 编译器生成自解压 EXE 和完整 ZIP，输出到 `build/releases/`。

### 一次运行完整检查

先运行 `flutter pub get`，在 PowerShell 中执行：

```powershell
# 静态分析 + 全量测试 + 行/分支 100% 门槛 + Android Debug 构建
./tool/check.ps1 -BuildApk
# Flutter 不在 PATH 时，可增加 -Flutter 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat'
```

报告生成到 `build/coverage/report.txt`、`report.json` 和 `lcov.info`。默认要求行覆盖和分支覆盖均为 **100%**；任何未覆盖行、分支或未统计的可执行 `lib` 文件都会使检查失败，不使用覆盖率排除标记。纯数值常量文件没有可执行记录，在报告中单独列出。

`-RequireFullCoverage` 参数保留兼容，但不再需要显式指定。100% 指 Dart VM 实测的行与分支执行覆盖，不等于全部交互组合、并发排列或 Android 真机行为均已验证；原生平台、真实网络与系统分享仍需设备验证。

## 项目结构

```
lib/
├── main.dart                        # 入口 + 底部导航
├── models/
│   ├── ai_summary.dart              # AI 摘要数据模型
│   ├── book.dart                    # 书籍数据模型
│   ├── bookmark.dart                # 笔记数据模型
│   ├── bookshelf_filter.dart        # 书架筛选条件
│   ├── note_item.dart               # 笔记列表项
│   └── reading_constants.dart       # 阅读状态常量
├── services/
│   ├── api.dart                     # 微信读书 API（含移动端认证）
│   ├── ai_service.dart              # AI 摘要服务
│   ├── config.dart                  # 配置与安全存储
│   ├── credentials.dart             # 凭据管理
│   ├── database.dart                # SQLite 数据库（含全文索引）
│   ├── export_service.dart          # 笔记/卡片导出
│   ├── qr_login_service.dart        # 扫码登录
│   └── sync_service.dart            # 增量同步
├── providers/
│   ├── app_config_provider.dart     # 全局配置与登录状态
│   ├── bookshelf_provider.dart      # 书架状态管理
│   └── notes_provider.dart          # 笔记状态管理
├── pages/
│   ├── bookshelf_page.dart          # 书架
│   ├── book_detail_page.dart        # 书籍详情
│   ├── notes_page.dart              # 笔记
│   ├── cards_page.dart              # 金句卡片
│   ├── report_page.dart             # 阅读报告
│   ├── ai_summary_page.dart         # AI 摘要
│   ├── sync_page.dart               # 数据同步
│   ├── qr_login_page.dart           # 扫码登录
│   ├── cookie_login_page.dart       # Cookie 登录
│   └── settings_page.dart           # 设置
└── widgets/
    └── settings/                    # 设置页各分区组件
```

## 技术栈

- Flutter 3.x + Dart 3.x，Material Design 3
- sqflite（本地数据库）、dio + http（网络）
- provider（状态管理）
- flutter_secure_storage（凭据安全存储）、shared_preferences（偏好设置）
- fl_chart（阅读报告图表）、qr_flutter（扫码登录）
- cached_network_image（封面缓存）、share_plus（分享导出）

## 更新记录

- **v2.6.x** — 多轮 bug 审查与修复：同步竞态、SQLite 旧版本兼容、导出快照、账号生命周期、配置持久化
- **v2.6.0** — 12 项性能优化：增量同步、并发拉取、SQL 聚合、懒加载、按需解码
- **v2.5.0** — 18 项代码质量问题修复
- **v2.4.0** — 技术债清理：统一同步服务、分页导出、离线浏览、摘要引用回跳
- **v2.3.0** — 微信扫码登录；凭据迁移到安全存储；账号数据隔离
