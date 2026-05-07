# 微信读书伴侣 (WeRead Companion) - Flutter 版本 v2.1.0

微信读书的移动伴侣工具，支持书架管理、笔记浏览、金句卡片和阅读报告。

## 功能

- **我的书架** - 网格展示书籍封面，支持搜索和状态筛选（全部/读完/在读中/未读）
- **笔记管理** - 浏览、搜索、收藏所有笔记和划线，支持下拉刷新
- **金句卡片** - 将划线生成精美卡片预览，支持调节文字大小、导出为高清 PNG 图片
- **阅读报告** - 阅读数据可视化和统计
- **AI 摘要** - 使用 AI 为书籍生成摘要
- **笔记导出** - 将划线和笔记导出为 Markdown 格式
- **Cookie 登录** - 导入微信读书 Cookie 获取数据

## 开发环境搭建

### 1. 安装 Flutter SDK

```bash
# Windows: 下载 Flutter SDK
# https://docs.flutter.dev/get-started/install/windows

# 配置环境变量
export PATH="$PATH:/path/to/flutter/bin"

# 验证安装
flutter doctor
```

### 2. 创建 Android 项目配置

```bash
cd weread-companion-flutter
flutter create . --platforms=android
```

### 3. 安装依赖

```bash
flutter pub get
```

### 4. 运行

```bash
# 连接手机或启动模拟器后
flutter run
```

### 5. 打包 APK

```bash
flutter build apk --release
# 输出: build/app/outputs/flutter-apk/app-release.apk
```

## 项目结构

```
lib/
├── main.dart                  # 入口 + 底部导航
├── models/
│   ├── book.dart              # 书籍数据模型
│   └── bookmark.dart          # 笔记数据模型
├── services/
│   ├── api.dart               # 微信读书 API
│   ├── config.dart            # 配置管理
│   ├── database.dart          # SQLite 数据库
│   ├── ai_service.dart        # AI 摘要服务
│   └── export_service.dart    # 笔记导出服务
├── providers/
│   ├── bookshelf_provider.dart # 书架状态管理
│   ├── notes_provider.dart    # 笔记状态管理
│   └── app_config_provider.dart # 全局配置状态
└── pages/
    ├── bookshelf_page.dart    # 书架页面
    ├── book_detail_page.dart  # 书籍详情页面
    ├── notes_page.dart        # 笔记页面
    ├── cards_page.dart        # 金句卡片页面
    ├── report_page.dart       # 阅读报告页面
    ├── settings_page.dart     # 设置页面
    ├── sync_page.dart         # 数据同步页面
    └── cookie_login_page.dart # Cookie 登录页面
```

## 技术栈

- Flutter 3.x + Dart 3.x
- Material Design 3
- sqflite (本地数据库)
- dio (HTTP 请求)
- fl_chart (图表)
- provider (状态管理)
- flutter_secure_storage (安全存储)

## 从 PyQt6 版本迁移

核心逻辑（API、数据库、业务规则）从 Python 直接迁移到 Dart，UI 使用 Flutter 原生组件重写。

### 主要变化

| PyQt6 版 | Flutter 版 |
|----------|-----------|
| customtkinter / PyQt6 | Material Design 3 |
| SQLite + Python | sqflite + Dart |
| requests | dio |
| PIL/Pillow | Flutter Canvas |
| matplotlib | fl_chart |
| Selenium 扫码 | Cookie 导入 |
| Windows exe | Android APK |
