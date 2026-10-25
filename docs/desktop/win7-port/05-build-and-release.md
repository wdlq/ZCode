# 05 · 从源码到离线安装包

本文是"重新构建一次"的完整手册。所有命令都在**仓库根目录**执行，除特别说明外。

本目录提供的可复用脚本：

| 脚本 | 用途 |
| --- | --- |
| `scripts/win7-port/patch-pe-subsystem.mjs` | 把 PE32+ 的 OS/Subsystem 版本改成 6.1（`electron.exe` → `ZCode.exe`） |
| `scripts/win7-port/assemble-desktop-app.mjs` | 组装 `resources\app`（out + 运行时依赖闭包） |
| `scripts/win7-port/install.ps1` | 安装器引导（复制到 %TEMP% → 提权 → install-core） |
| `scripts/win7-port/install-core.ps1` | 解包 / VxKex 注册 / 快捷方式 / install.json |
| `scripts/win7-port/build-installer.ps1` | 在 Win7 目标机上组装 `payload.zip` + SFX 单文件安装器 |
| `scripts/win7-port/config.txt` | 7-Zip SFX 的 `RunProgram` 配置 |
| `scripts/win7-port/安装.cmd` | 目录形态的一键安装入口 |

## 1. 构建前置

```powershell
node -v      # 建议 24.x（仓库 mise.toml 锁定 24.14.0）
pnpm -v      # 10.33.2
pnpm install --frozen-lockfile
```

> Windows 上 `pnpm` 是 `pnpm.cmd` shim。脚本里**不要**用 `spawnSync("pnpm", ...)`，
> 用 `scripts/spawn-command.mjs` 的 `runCommand`（本项目已修复，见 07）。

## 2. 构建 Web 发行包

```powershell
# @zcode/shared 没有 build 脚本，dist 由 tsc -b 产出（否则 staging 会报
# "Missing @zcode/shared dist files"）
node node_modules/typescript/bin/tsc -b packages/shared

# 构建 CLI + server + web 并组装 dist/zcode/releases/<version>/zcode-<version>.tar.gz
pnpm build:zcode --base-url http://example.invalid/zcode/
```

产物结构（tar.gz 解包后）：

```text
zcode/
├─ agent/        zcode.cjs + provider/ + playwright-core + TUI 资产
├─ server/       entry-http.js（tsup bundle）+ remote/
├─ web/          Vite 静态资源
├─ bin/zcode.mjs 启动器
└─ node_modules/ 运行期依赖闭包（node-pty / ws / ssh2 / undici / hono / yauzl …）
```

**踩坑 1：`pnpm typecheck` 会覆盖 server 的 tsup 产物。**
`tsc -b packages/server` 会把 `dist/entry-http.js` 重写成未打包的版本（只有几 KB），
打包后启动报 `Cannot find package '@zcode/services'`。
→ 顺序必须是：**先 typecheck，最后重新 `pnpm --filter @zcode/server build`**，再组装。

**踩坑 2：按目标平台裁剪。** win32-x64 只需要 win32-x64 的预编译产物：

```
web/**/*.map
node_modules/node-pty/prebuilds/{darwin-*,linux-*,win32-arm64}
agent/node_modules/@mbears/opentui-core-{非 win32-x64}
agent/node_modules/koffi/build/koffi/{非 win32_x64}
agent/node_modules/unsafe-pointer/prebuilds/{非 win32-x64}
```

裁剪后：373.5 MB → 229.9 MB；tar.gz 83.2 MB → 51.2 MB。

## 3. 构建桌面版

```powershell
# 1) main/host/preload/renderer/scheduler/plugin-sandbox
pnpm --filter @zcode/desktop run build:no-runtime-assets

# 2) Agent bundle（stage 到 packages/desktop/bundled-agents/win32-x64/glm/zcode.cjs）
node scripts/build-desktop-agent-cli.mjs

# 3) 官方插件 + bundled-skills（关键：生成 glm/packages/*）
pnpm --filter @zcode/desktop run prepare:agent-bundle
```

`prepare:agent-bundle` 之后应能看到：

```text
bundled-agents\win32-x64\glm\
├─ zcode.cjs
└─ packages\
   ├─ browser-use-plugin\      ← 缺它就没有 control-browser 技能
   ├─ node-repl-host\
   ├─ zcode-cua-plugin\
   ├─ bundled-skills\
   └─ …（documents/pdf/presentations/spreadsheets/android-emulator/ios-simulator 等）
```

组装 `resources\app`（仓库内提供了脚本）：

```powershell
node scripts/win7-port/assemble-desktop-app.mjs --target <安装目录>\desktop\resources\app
```

脚本做的事：

1. 写 `package.json`（`main: out/main/index.js`, `type: module`）
2. 拷 `out\`、`bundled-agents\`、`build\`、`native\`
3. 拷运行时依赖：取 `packages/desktop/package.json` 的 `dependencies`，
   **排除** `@zcode/*`、`react`、`react-dom`，递归收集其依赖闭包到 `node_modules`

4. 组装 Electron 目录：解包 `electron-v41.0.3-win32-x64`（或用 `node_modules/electron/dist`），
   **删除原 `electron.exe`**（省 212 MB），把打过补丁的 `ZCode.exe` 放进去
5. 放 `resources\app`、`resources\glm`、`resources\config`（仓库根 `config\`）

## 4. PE 补丁（必做）

`electron.exe` 的 `SubsystemVersion = 10.0`，Win7 加载器直接拒绝。改成 6.1：

- PE32+ 可选头偏移 `+48`（Major）/ `+50`（Minor）→ `6` / `1`
- 同步 `+40` / `+42`（OS 版本）→ `6` / `1`
- 另存为 `ZCode.exe`，与原 DLL/pak 同目录

等价 `editbin /SUBSYSTEM:WINDOWS,6.01`。**补丁后必须注册 VxKex**（见 01）。

## 5. 制作离线安装包

目标：一个自解压 exe，双击 → 自动提权 → 解包 → 注册 → 快捷方式。

### 5.1 目录

```text
payload\                     （会被压成 payload.zip）
├─ desktop\                  桌面端（不含 electron.exe）
├─ web\
│  ├─ app\zcode\
│  ├─ runtime\node.exe
│  └─ launcher\
├─ tools\                    browser-verify.mjs / desktop-ui-check.mjs
├─ AGENTS.md
├─ README.txt
├─ 启动 ZCode 桌面版.cmd / （调试）.cmd
├─ 启动 ZCode Web 版.cmd
└─ 停止 ZCode Web 版.cmd

sfx\                         （SFX 归档内容）
├─ install.ps1               引导：复制到 %TEMP% → 提权 → 调 install-core
├─ install-core.ps1          解包 / VxKex 注册 / 快捷方式 / install.json
├─ config.txt                SFX 运行配置（RunProgram=install.ps1）
├─ payload.zip
├─ README.txt
└─ prereq\KexSetup_Release_1_1_3_2038.exe
```

### 5.2 命令

```powershell
# 压 payload（7-Zip，Deflate）
& "C:\Program Files\7-Zip\7z.exe" a -tzip -mx5 -mm=Deflate payload.zip .\payload\*

# 打 SFX（注意：模块名必须能在当前目录找到，先 cd 到目录或用 -sfx 默认模块）
cd .
& "C:\Program Files\7-Zip\7z.exe" a -sfx -mx0 ZCode-Win7-Offline-Setup.exe .\sfx\*
```

**踩坑 3：`-sfx7zCon.sfx` 会报 `cannot find specified SFX module`。**
7-Zip 只在特定位置找模块；最稳的是 `cd` 到构建目录后用 `-sfx`（默认 `7z.sfx`），
或先把 `7zCon.sfx` 复制到当前目录再 `-sfx7zCon.sfx`。

**踩坑 4：不要在 SFX 里再压缩 `payload.zip`。** 用 `-mx0`（store），否则二次压缩白耗 CPU
且体积几乎不变。

### 5.3 安装脚本关键点

| 点 | 原因 |
| --- | --- |
| 引导脚本先把 payload 复制到 `%TEMP%\zcode-win7-setup` | SFX 退出会清理自身临时目录，而提权子进程还在用 |
| `Start-Process -Verb RunAs -Wait` | 提权需要用户同意；`-Wait` 保证父进程存活 |
| `-TargetDir` 默认 `C:\Program Files\ZCode-Win7` | 需要管理员写权限 |
| 解压到临时目录再原子替换 | 覆盖升级时避免半新半旧 |
| 覆盖前 `Stop-Process` 目标目录内的进程 | 否则目录被占用无法替换 |
| 过滤项名 = `VxKex_ZCODE_<路径哈希>` | 同一 exe 名多份安装时不会互相覆盖 `FilterFullPath` |
| 用 `System.IO.Compression.ZipFile` 解压 | `Expand-Archive` 在 PS 5.1 上对大包更慢 |

### 5.4 验收

```powershell
# 单文件安装器内容
& "C:\Program Files\7-Zip\7z.exe" l ZCode-Win7-Offline-Setup.exe

# 直接跑核心逻辑（跳过 UAC，便于自动化验证）
install-core.ps1 -TargetDir "C:\Program Files\ZCode-Win7-Test" `
  -Payload .\payload.zip -NoShortcuts

# 验证两个形态
#   桌面：启动后 /json/version 返回 Chrome/146.*，/json/list 有 title=ZCode
#   Web ：/api/server-info 返回 200
```

实测：安装到新目录后，桌面端 CDP 显示 `Chrome/146.0.7680.80`、标题 `ZCode`；
Web 端 `server-info` 返回 200，`node.exe` 与 `ZCode.exe` 的 VxKex 过滤项均已注册。

## 6. 版本与产物体积参考

| 产物 | 体积 |
| --- | --- |
| `zcode-<ver>.tar.gz`（未裁剪） | 83.2 MB |
| `zcode-<ver>.tar.gz`（裁剪） | 51.2 MB |
| 桌面安装目录（含插件，不含 electron.exe） | ~753 MB |
| Web 安装目录（app + node.exe） | ~320 MB |
| `payload.zip` | 322.0 MB |
| `ZCode-Win7-Offline-Setup.exe` | 327.5 MB |
