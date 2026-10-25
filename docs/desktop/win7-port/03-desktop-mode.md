# 03 · 桌面形态（Electron 41 原生窗口）

## 1. 核心事实：不是"缺 DLL"，是加载器先拒绝

`electron.exe` 的 PE 可选头写着 `SubsystemVersion = 10.0`。Windows 7 的加载器看到高于自身的
子系统版本会**在映射镜像前**直接拒绝，返回 `不是有效的 Win32 应用程序`——此时 VxKex 还没有介入机会。

只有把子系统版本改成 6.1 之后，才会进入"缺 Win8/Win10 导出函数"的阶段，VxKex 才能补。

三段对照实验（同一份 41.0.3）：

| 条件 | 结果 |
| --- | --- |
| 原样运行 | ❌ `The specified executable is not a valid application for this OS platform` |
| 只改 PE 子系统版本 | ❌ `0xC0000139`（STATUS_ENTRYPOINT_NOT_FOUND） |
| 改 PE + 按路径注册 VxKex | ✅ `--version` 正常、窗口可创建、页面可渲染 |

## 2. PE 补丁怎么做

PE32+ 可选头（`e_lfanew + 24` 起）里的四个 WORD：

| 偏移 | 字段 | 原值 | 改为 |
| --- | --- | --- | --- |
| +40 / +42 | Major/MinorOperatingSystemVersion | 10.0 | 6.1 |
| +48 / +50 | Major/MinorSubsystemVersion | 10.0 | 6.1 |

等价命令：`editbin /SUBSYSTEM:WINDOWS,6.01 ZCode.exe`。

本项目用仓库内脚本完成：`node scripts/win7-port/patch-pe-subsystem.mjs <electron.exe> <ZCode.exe>`
（读 `e_lfanew` → 校验 `PE\0\0` 与 PE32+ → 覆写四个 WORD）。补丁后必须保留原 `electron.exe`
的 DLL/资源同目录，否则加载失败。

验证方法：

```powershell
# 读 PE 头（或直接运行 ZCode.exe --version，应为 v41.0.3）
```

## 3. VxKex 注册

格式见 [01-environment.md](./01-environment.md#4-vxkex-注册格式必须背下来)。
本项目按**路径哈希**生成过滤项名（`VxKex_ZCODE_<8位哈希>`），这样同一台机器上可以并存
多份安装（测试目录 + 正式目录）而不会互相覆盖 `FilterFullPath`。

## 4. 解包布局（为什么不用 electron-builder）

`pnpm --filter @zcode/desktop exec electron-builder --dir` 会触发该项目里大量原生资产校验
（sharp/koffi/node-pty 预编译、third-party notices、asar repack、NSIS 补丁…），
对"离线 + 非官方平台"的移植并不合适。本项目改为**手工组装**：

```text
desktop\
├─ ZCode.exe                  electron.exe 改名 + 打补丁（原 electron.exe 不随包，省 212 MB）
├─ *.dll / *.pak / locales\   Electron 运行时原样
└─ resources\
   ├─ app\
   │  ├─ package.json         main = out/main/index.js, type = module
   │  ├─ out\                 main / host / preload / renderer / scheduler / plugin-sandbox
   │  ├─ node_modules\        仅主/宿主运行时的外部依赖
   │  └─ bundled-agents\      开发态回退用（打包态走 resources\glm）
   ├─ glm\                    Agent 运行时：zcode.cjs + packages\（官方插件）
   └─ config\                 default.json + provider\zcode-builtin.json
```

三条硬性要求（漏一条就会出现难查的症状）：

| 必须存在 | 缺失时 |
| --- | --- |
| `resources\config\default.json` | 主进程启动即 `ENOENT ... resources\config\default.json` |
| `resources\glm\packages\browser-use-plugin` | Browser Use 桥仍在（`list` 通），但模型没有 `control-browser` 技能，会退化成调用 Tabbit |
| `resources\glm\zcode.cjs` | Agent 起不来，所有对话失败 |

`resources\app\node_modules` 的依赖名单：取 `packages/desktop` 的 `dependencies`，
**排除** `@zcode/*`（已被 tsup 内联）与 `react`/`react-dom`（只服务渲染器）。
包含 `node-pty`、`ssh2`、`undici`、`ws`、`yaml`、`yauzl`、`yazl`、`node-forge`、
`electron-updater`、`playwright-core`、`@modelcontextprotocol/*`、`@opentelemetry/*`、
`@arms/rum-electron`、`@babel/runtime`、`@larksuiteoapi/node-sdk` 等。

## 5. 构建与组装（命令）

```powershell
# 1) 依赖与共享类型产物（@zcode/shared 没有 build 脚本，dist 由 tsc -b 产出）
pnpm install
node node_modules/typescript/bin/tsc -b packages/shared

# 2) 桌面产物（tsup + vite）
pnpm --filter @zcode/desktop run build:no-runtime-assets

# 3) Agent bundle + 官方插件（关键：会产生 resources\glm\packages）
node scripts/build-desktop-agent-cli.mjs
pnpm --filter @zcode/desktop run prepare:agent-bundle

# 4) 组装 resources\app：拷贝 out/ + 生产依赖闭包（排除 @zcode/* 与 react）
#    参考 05-build-and-release.md 的 assemble 步骤

# 5) 打 PE 补丁 → ZCode.exe
# 6) 按 4 的布局放进安装目录
```

## 6. 实测矩阵（Win7 SP1 x64）

| 项 | 结果 |
| --- | --- |
| `ZCode.exe --version` | ✅ v41.0.3 |
| 主进程 / `app.whenReady` | ✅ |
| BrowserWindow（`sandbox: false` / `true`） | ✅ 均能加载页面并执行 JS |
| 真实应用 | ✅ main + host + 8 进程，标题 `ZCode` |
| 渲染进程 | ✅ `v4 conversation subscribe` 正常，无 JS 异常 |
| 模型对话 | ✅ 自定义供应商 `GLM-5.3-Flash`，约 5 秒 |
| Bash 工具 + 权限确认 | ✅ 执行 `ver` 返回 `6.1.7601` |
| 内置浏览器 IAB | ⚠️ 控制面 `list`/`newTab` 成功；**无交互桌面会话**时 `<webview>` 不挂载 |
| 托盘 / 通知 / 自动更新 / 多窗口 | 未验证 |

## 7. 已知噪音与限制

| 现象 | 影响 |
| --- | --- |
| `Unable to find a primary display. Fallback to fake display` | 仅日志；无桌面会话时出现，真实桌面不会 |
| `os_crypt: Failed to encrypt: 0x5` | VxKex 下 DPAPI 受限，影响 Chrome cookie 导入等非核心功能 |
| `读取 task index meta_json 非法 taskId=...` | 历史数据告警；干净数据目录不会出现 |
| 非官方路径 | 升级 Electron 必须重打 PE 补丁 + 更新 FilterFullPath |

## 8. 一定要在桌面会话里启动

通过 SSH / 计划任务 / 服务启动时，进程落在 session 0：窗口不可见，`<webview>` 可能挂不上。
正确做法是本地双击 `启动 ZCode 桌面版.cmd`。

排障时可以用 `启动 ZCode 桌面版（调试）.cmd`（带 `--remote-debugging-port=9333`），
然后用 `tools/desktop-ui-check.mjs` 读界面/点击/截图。
