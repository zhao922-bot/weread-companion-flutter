<p align="center">
  <img src="assets/branding/readamber-v1/readamber-icon-256.png" width="112" height="112" alt="阅珀 ReadAmber 应用图标">
</p>

<h1 align="center">阅珀 ReadAmber</h1>

<p align="center"><strong>让读过的，留下来。</strong><br>Keep the words that stay with you.</p>
<p align="center">书摘 · 笔记 · 阅读回顾<br>Android / Windows · Flutter</p>

阅珀是一款面向微信读书用户的阅读整理工具。将书架、划线和笔记同步到本地，随时查找与回顾；把喜欢的句子做成卡片，或借助带原文引用的 AI 摘要重新梳理一本书。

项目原名 **微信读书伴侣（WeRead Companion）**，自 **v2.8.0** 起使用 **阅珀 ReadAmber** 作为正式名称。「阅」是阅读，「珀」取自琥珀，寓意留住阅读中值得珍藏的文字与思考。图标将书页与引号融为一体，以墨青、琥珀金和纸白呈现。

## 下载与安装

当前版本：**v2.8.0 · 构建号 22**。全部安装包和校验文件见 [GitHub Releases](https://github.com/zhao922-bot/weread-companion-flutter/releases/tag/v2.8.0)。

| 平台 | 下载 | 使用方式 |
| --- | --- | --- |
| Android 7.0 及以上 | [通用 APK](https://github.com/zhao922-bot/weread-companion-flutter/releases/download/v2.8.0/readamber-v2.8.0-android.apk) | 下载后安装，支持 ARMv7、ARM64 和 x86_64 |
| Windows x64 | [EXE 安装包](https://github.com/zhao922-bot/weread-companion-flutter/releases/download/v2.8.0/readamber-v2.8.0-windows-x64-setup.exe) | 双击解压部署，创建「阅珀 ReadAmber」开始菜单快捷方式并启动 |
| Windows x64 | [便携 ZIP](https://github.com/zhao922-bot/weread-companion-flutter/releases/download/v2.8.0/readamber-v2.8.0-windows-x64.zip) | 完整解压后运行 `weread_companion.exe`，保留同目录的 DLL 和 `data` 文件夹 |
| 文件校验 | [SHA256SUMS.txt](https://github.com/zhao922-bot/weread-companion-flutter/releases/download/v2.8.0/SHA256SUMS.txt) | 用于核对下载文件的 SHA-256 |

### 从旧版升级

- **Android v2.7.0 → v2.8.0**：沿用 v2.7.0 的发布签名和应用包名，可直接覆盖升级。更早版本使用不同签名；若系统提示签名冲突，应先导出需要保留的笔记，再卸载旧版安装。Markdown 导出不是可还原全部应用状态的备份。
- **Windows**：先关闭正在运行的程序，再运行新版安装包。为兼容已有安装，仍部署到 `%LOCALAPPDATA%\Programs\WeReadCompanion`，并将本安装对应的旧开始菜单快捷方式替换为新名称。
- **数据兼容**：本次品牌更新保留 Android 包名、配置键、数据库文件名和 Windows 存储标识。Windows 数据仍位于 `%APPDATA%\zhao922-bot\WeRead Companion`；程序目录与数据目录分离。便携版也使用该用户数据目录。

## 用阅珀做什么

### 把阅读收获留在手边

- 扫码登录，或导入微信读书 Cookie。
- 同步书架、阅读进度、划线和笔记；已同步内容可离线浏览。
- 按书名、作者和阅读状态筛选书籍。
- 搜索全部笔记、收藏重要内容，并按书籍查看上下文。

### 回到原文，重新理解一本书

- 使用自选的 AI 服务生成读书摘要；支持兼容 OpenAI 接口的 API 地址、模型和 Key。
- 摘要中的引用可跳回对应笔记，方便核对依据。
- 按书籍保存摘要历史；响应中断或截断时明确提示，便于重试。
- 阅读报告展示趋势、书籍排行和笔记统计。

### 把好句分享出去

- 金句卡片支持调整字号、导出 PNG；较长内容会拆成多张图片。
- 全部笔记或单本书笔记可导出为 Markdown。
- 导出使用固定快照，导出期间的同步与页面切换不会改变正在生成的内容。

## 开始使用

1. 安装后进入 **设置**，选择扫码登录或 Cookie 导入，完成账号验证。
2. 打开 **书架** 执行同步；失败的书籍会列出，可单独重试。
3. 在 **笔记** 中搜索、收藏、查看原文，或在 **卡片** 中制作金句图片。
4. 如需 AI 摘要，在设置中填写自己的 API 地址、模型和 Key，再进入书籍详情使用。

Cookie 导入：在电脑浏览器登录 [微信读书](https://weread.qq.com/)，打开开发者工具 Console，执行 `copy(document.cookie)`，将结果粘贴到应用的 Cookie 导入页。Cookie 和 API Key 属于敏感凭据，请勿贴到公开 Issue、截图或日志中。

## 数据与隐私

- 书架、划线、笔记与摘要保存在本机 SQLite；这些阅读数据未额外加密。
- Cookie、登录令牌和 AI Key 通过系统安全存储保存，签名密钥和密码不进入仓库或发布包。
- 使用同步功能时连接微信读书服务；使用 AI 摘要时，会把相关笔记发送到你配置的 AI 服务，请根据自己的需要选择服务商。
- 退出登录或切换账号会清理当前账号的本地数据和应用管理的导出文件。需要保留的内容应提前导出并另存。
- 阅珀是独立第三方工具，与微信读书及腾讯无隶属或官方合作关系。上游接口或登录规则变化可能影响同步；认证失效时需要重新登录。

## 可靠性与性能

- **增量同步**：按书籍保存游标，最多 4 路并发；支持取消、失败重试与会话隔离。
- **长列表与搜索**：游标分页、搜索防抖、中文 trigram 索引、封面缓存与按需解码。
- **控制内存使用**：统计在数据库内聚合；Markdown 按批处理并流式写入；卡片导出限制渲染像素预算。
- **保护导出结果**：先写临时文件，成功后发布；失败或取消时清理临时资源。
- **兼容数据库升级**：索引分批回填并保存进度，避免每次启动重新处理全库。

自动化检查要求 `flutter analyze` 零问题、全部测试通过，且 `lib` 中可执行 Dart 代码的**行覆盖率和分支覆盖率均为 100%**。检查包含认证、同步、数据库、导出及页面生命周期的异常与取消路径，详见 [更新日志](CHANGELOG.md) 和 [覆盖率门槛](tool/coverage_audit.json)。

覆盖率衡量测试执行过的代码，不代表所有并发时序、真实服务响应和原生平台交互都已验证；真机登录、系统分享等仍需要设备验证。

## 开发与构建

已验证工具链：**Flutter 3.44.0 / Dart 3.12.0**。Android 构建需要 Android SDK 与 JDK；Windows 构建需要 Visual Studio 的 C++ 桌面开发工具和 Windows SDK。

```bash
flutter pub get
flutter run

# Android 发布包
flutter build apk --release

# Windows 发布目录，包含 Flutter、SQLite 与 VC++ 运行库
flutter build windows --release
```

Android 发布签名通过本地 `android/key.properties` 配置：

```properties
storeFile=your-release.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

相对路径以 `android/` 为基准。将 keystore 与密码安全备份；覆盖安装旧版本必须使用同一签名。仓库已忽略签名文件和 `key.properties`。

Windows 构建后，在 PowerShell 中运行：

```powershell
./tool/package_windows.ps1
```

脚本使用 Windows 自带的 .NET Framework 编译器，生成自解压 EXE 和完整 ZIP，写入 `build/releases/`。这是按用户部署的安装包，不需要管理员权限；不注册系统卸载项。EXE 和应用程序目前未做 Authenticode 签名。

### 运行完整质量检查

```powershell
# 静态分析 + 全量测试 + 100% 行/分支覆盖门槛
./tool/check.ps1

# 额外验证 Android Debug 构建
./tool/check.ps1 -BuildApk

# Flutter 不在 PATH 时指定可执行文件
./tool/check.ps1 -Flutter 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat'
```

报告输出到 `build/coverage/report.txt`、`report.json` 和 `lcov.info`。未覆盖的行、分支或遗漏的可执行 `lib` 文件会使检查失败。无可执行记录的纯常量文件单独列出，不使用覆盖率排除标记。

### 品牌资源

图标母版、PNG、ICO、配色、品牌展示页和生成提示词位于 [`assets/branding/readamber-v1/`](assets/branding/readamber-v1/)。图标为位图资源。修改母版后，可在 Windows PowerShell 中重新生成并安装各平台图标：

```powershell
./assets/branding/readamber-v1/export-icons.ps1 -Install
```

应用内部 Dart 包名 `weread_companion`、Android applicationId、Windows 可执行文件名与存储用 `ProductName` 是兼容性标识，继续保留；面向用户的应用名称为「阅珀 ReadAmber」。请勿仅为修改显示名称而更改这些存储标识。

## 代码结构

| 目录 | 内容 |
| --- | --- |
| `lib/pages/` | 书架、笔记、卡片、报告、登录与设置页面 |
| `lib/providers/` | 账号会话、书架和笔记状态 |
| `lib/services/` | 认证、同步、SQLite、AI、导出与平台初始化 |
| `lib/models/` | 书籍、笔记、摘要等数据模型 |
| `lib/widgets/` | 设置分区等复用组件 |
| `test/` | 单元测试、Widget 测试与回归测试 |
| `tool/` | 覆盖率报告、质量检查与 Windows 打包工具 |
| `assets/branding/` | 正式品牌与图标资源 |

技术栈：Flutter / Material 3、Provider、SQLite、Dio / HTTP、flutter_secure_storage、shared_preferences、fl_chart、share_plus。

## 反馈与更新

查看 [版本记录](CHANGELOG.md)、[发布列表](https://github.com/zhao922-bot/weread-companion-flutter/releases)，或通过 [GitHub Issues](https://github.com/zhao922-bot/weread-companion-flutter/issues) 反馈问题。请提供应用版本、系统版本、复现步骤和经过脱敏的错误信息。
