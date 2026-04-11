# ClassEcho

ClassEcho 是一个面向课堂场景的实时听写与复盘工具，支持录音转写、要点总结、问题追踪、深度解答与历史回看。

## 核心功能

- 实时录音转写（ASR）
- 自动生成课堂要点
- 课堂问题标记与后续深度解答
- 历史记录保存与回放
- 白板快照（图文时间轴）
- 离线失败片段补偿重试
- Anki CSV 导出
- 自定义 OpenAI 兼容 Base URL

## 运行环境

- Flutter 3.x
- Dart 3.x
- Android 手机（推荐用于真机验证）

## 快速启动

```bash
flutter pub get
flutter run
```

## 发布打包

```bash
flutter build apk --release
```

生成文件：

- `build/app/outputs/flutter-apk/app-release.apk`

## 首次使用配置

在应用设置页配置：

- API Key
- ASR 模型
- 总结模型
- Base URL（可选，默认 SiliconFlow）

## 30 秒上手

1. 打开应用，进入设置页填写 API Key。
2. 回到首页，点击麦克风按钮，输入课程名称后开始录音。
3. 讲课过程中可点击拍照按钮插入白板快照。
4. 右侧会持续生成要点，遇到疑难可加入待解问题清单。
5. 结束后自动保存到历史记录，可继续查看和导出。

## 界面截图

建议将截图放到 `docs/screenshots/` 目录，并按下列命名：

- `home.png`：监听主界面
- `history.png`：历史列表页
- `detail.png`：历史详情页
- `settings.png`：设置页

示例占位：

```md
![监听主界面](docs/screenshots/home.png)
![历史列表](docs/screenshots/history.png)
![历史详情](docs/screenshots/detail.png)
![设置页](docs/screenshots/settings.png)
```

## 主要目录

- `lib/main.dart`：主流程与页面逻辑
- `lib/widgets/enhanced_markdown_view.dart`：Markdown/LaTeX 渲染组件
- `android/`、`ios/`：平台配置与权限

## 常见问题

1. 手机上无法识别语音
- 检查麦克风权限是否授予
- 检查网络可用性与 API Key

2. 没有生成总结
- 确认模型与 Base URL 配置正确
- 检查是否有可用课堂内容

3. 断网后数据丢失
- 应用会缓存失败片段，可在历史页触发重试补偿

## 许可证

仅供学习与个人项目使用，商业使用请按实际依赖协议自行评估。
