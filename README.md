# 模型资源管理

统一模型目录、后台下载队列、并发去重、取消、断点续传、任务恢复、镜像、大小与 SHA-256 校验、安全安装、目录导入、检查、删除和磁盘清理。模型使用期间的文件替换继续通过运行时资源释放协议协调。

App 与语音 SDK 共用一个配置好的 `ModelManager.instance`。包不依赖 App 设置、账号、计费、任务数据库或本地化；App 通过 `onInstalled` / `onRemoved` 保存业务绑定，通过 `onJobChanged` 投影任务列表。任务列表不重复调度模型安装，取消和重试转发模型包。

生产环境传入持久化 `ResourceStringStorage`；`FileResourceStorage.open` 提供文件存储，测试可使用 `MemoryResourceStorage`。App 可以注入已有数据库存储、Dio 和目录提供器。默认模型目录资源由宿主提供，默认读取 `assets/offline_resources/catalog.json`，也可配置其他资源目录源。

UI 使用 `list`、`queueInstall`、`addJobListener`、`cancelInstall`、`verify` 和 `remove`。任务独立于页面生命周期；应用启动调用 `resumeInterruptedInstalls` 恢复仍匹配目录版本的可续传任务。安装不由引擎初始化隐式触发。

这里的后台是进程内后台队列及下次启动恢复。操作系统终止进程后不会继续运行 Dart 下载；系统自身管理的语音语言包也不纳入此模型目录。
