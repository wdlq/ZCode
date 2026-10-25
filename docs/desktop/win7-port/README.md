# ZCode × Windows 7 移植文档（总览）

> 目标读者：第一次接手本项目的工程师，或需要按文档复现的入门级 Agent。
> 读完本目录后，你应当能够：在 Win7 上从零构建、打包、安装、排障，并知道每一处改动为什么存在。

## 0. 一句话结论

ZCode 官方**不支持** Windows 7。本项目通过两条路径让它在 Win7 SP1 x64 上可用：

| 形态 | 做法 | 代价 | 适用 |
| --- | --- | --- | --- |
| **Web 版** `zcode --web` | Node 24 直接跑 server + Web UI + Agent，浏览器（Supermium）访问 | 没有 Electron 外壳能力（IAB、托盘、自动更新） | 求稳、长期可维护 |
| **桌面版** Electron 41 | 改 `electron.exe` 的 PE 子系统版本 + 按路径注册 VxKex | 每次升级 Electron 都要重打补丁；非官方支持 | 需要原生窗口与内置浏览器 |

两条路径都已在 **Windows 7 Professional SP1 x64**（VMware）实机验证，含模型对话与 Bash 工具调用。

## 1. 文档地图

| 文档 | 内容 | 什么时候读 |
| --- | --- | --- |
| [01-environment.md](./01-environment.md) | 目标机环境、必须装的运行库、版本矩阵、VxKex 注册格式 | 拿到一台新 Win7 机器时 |
| [02-web-mode.md](./02-web-mode.md) | Web 形态的原理、部署布局、启动器设计、能力边界 | 部署 Web 版时 |
| [03-desktop-mode.md](./03-desktop-mode.md) | Electron 41 为什么打不开、两处二进制改造、解包布局、验证矩阵 | 部署原生版时 |
| [04-browser-automation.md](./04-browser-automation.md) | IAB / Tabbit / Playwright 三种浏览器后端与选择策略 | Agent 要"打开网页测试"时 |
| [05-build-and-release.md](./05-build-and-release.md) | 从源码构建、组装发行包、制作离线安装器 | 需要重新构建时 |
| [06-troubleshooting.md](./06-troubleshooting.md) | 症状 → 根因 → 修复 的排障清单 | 出问题时先查这里 |
| [07-code-changes.md](./07-code-changes.md) | 对仓库源码的全部改动与理由 | 代码评审 / 升级合并时 |

相关但更早的专题文档（内容已吸收进本目录，保留作为细节参考）：

- [../windows7-web-mode.md](../windows7-web-mode.md)
- [../windows7-electron-shell.md](../windows7-electron-shell.md)
- [../browser-automation-backends.md](../browser-automation-backends.md)

## 2. 目录与数据位置（记住这两张表，排障事半功倍）

### 2.1 安装布局（离线安装器默认路径）

```text
C:\Program Files\ZCode-Win7\
├─ desktop\                 Electron 原生端
│  ├─ ZCode.exe             已打 PE 补丁（子系统 6.1）
│  ├─ *.dll / *.pak / locales\
│  └─ resources\
│     ├─ app\               main/host/preload/renderer + 运行时依赖
│     ├─ glm\               Agent 运行时 + packages\（官方插件）
│     └─ config\            default.json / provider\
├─ web\
│  ├─ app\zcode\            Web 运行包（web/server/agent）
│  ├─ runtime\node.exe      Node 24
│  ├─ launcher\             启动/停止脚本
│  └─ logs\                 server 日志、lan-token.txt
├─ tools\                   browser-verify.mjs / desktop-ui-check.mjs
├─ AGENTS.md                浏览器后端选择约定
├─ 启动 ZCode 桌面版.cmd
├─ 启动 ZCode Web 版.cmd
├─ 停止 ZCode Web 版.cmd
└─ install.json
```

### 2.2 用户数据

| 形态 | 数据目录 | 说明 |
| --- | --- | --- |
| 桌面版 | `%APPDATA%\ZCode` | 任务索引、窗口状态、Chromium profile |
| Web 版 | `%USERPROFILE%\.zcode` | 会话、SQLite、设置、provider 配置 |
| 两者共享的配置 | `~/.zcode` 下的 provider / setting | 因此在一边配好的模型，另一边通常也能看到 |

> 常见误解：装完桌面版发现"任务列表是空的"——不是安装失败，是两个形态的数据目录不同。

## 3. 10 分钟快速开始

```text
① 确认目标机：Win7 SP1 x64 + PowerShell 5.1 + VxKex-NEXT（安装包内附安装器）
② 运行 ZCode-Win7-Offline-Setup.exe（会请求管理员权限）
③ 桌面「ZCode 桌面版」→ 设置 → 模型设置 → 创建自定义供应商 → 填局域网模型地址
④ 需要浏览器 UI 时用「ZCode Web 版」，默认 http://127.0.0.1:3030/
```

## 4. 改动清单（只有两处产品代码）

| 文件 | 改动 | 目的 |
| --- | --- | --- |
| `scripts/build-zcode.mjs` | 用 `scripts/spawn-command.mjs` 的 `runCommand` 替换本地 `spawnSync` | Windows 上 `pnpm` 是 `.cmd` shim，`spawnSync` 只找 `.exe` 会 ENOENT |
| `packages/services/src/project/index.ts` | `route()` / `saveProject()` 对 `"local"` 做 owner 归一 | 独立 Server 的持库 identity 是 `remote:server:<id>`，浏览器只传 `"local"`，否则建不了项目/会话 |

其余全部是**部署与打包层面的改造**（PE 补丁、VxKex 注册、启动器、安装器），不修改产品行为。
详见 [07-code-changes.md](./07-code-changes.md)。

## 5. 三条铁律（血泪教训）

1. **VxKex 过滤项按绝对路径匹配**。移动 `node.exe` / `ZCode.exe` 后必须重注册，否则进程
   `0xC0000139` 秒退、无任何输出。
2. **不要 `chcp 65001`**。Win7 点阵字体下 PowerShell 写中文会抛
   `Win32 internal error ... 0x1F`；真实控制台保持本机代码页（936）。
3. **`resources\glm\packages` 必须随包**。缺它时 Browser Use 的桥还在（`list` 能通），
   但模型没有 `control-browser` 技能，会退化成调用第三方浏览器（Tabbit）。
