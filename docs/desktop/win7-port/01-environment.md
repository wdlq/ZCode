# 01 · 目标机环境与依赖

## 1. 已验证环境（基线）

| 项 | 实测值 | 备注 |
| --- | --- | --- |
| 系统 | Windows 7 Professional **SP1** x64（6.1.7601） | 必须是 SP1 + 64 位 |
| PowerShell | 5.1.14409.1005 | 需要 WMF 5.1；PS 2.0 跑不了本项目的脚本 |
| CPU / 内存 | 6 vCPU / 12 GB（VMware） | 4 GB 也能跑，构建建议 ≥8 GB |
| 磁盘 | C: 67 GB，剩余 ≥35 GB | 安装后占用约 1.1 GB，构建另需 3 GB 临时空间 |
| VxKex | **1.2.3.2463**（`C:\Program Files\VxKex`） | 必需；仓库内另附 1.1.3 安装器 |
| 浏览器 | Supermium 150（Chromium 150）/ BrowserOS 155 | Web 版 UI 与浏览器验证用 |
| 其他 | 7-Zip、.NET Framework 4.5.2、VC++ 2015-2022 (x64) | 解包、VxKex、原生模块依赖 |

> 没有交互式桌面会话（例如只通过 SSH 登录）时，桌面版会出现
> `Unable to find a primary display. Fallback to fake display`，且内置浏览器 guest 可能挂不上。
> **桌面版必须在本地桌面会话里启动。**

## 2. 版本矩阵（写死，不要凭印象）

| 组件 | 版本 | 说明 |
| --- | --- | --- |
| Electron | **41.0.3** | ZCode 桌面版固定版本，锁定在 `packages/desktop/package.json` |
| Chromium（Electron 内置） | **146.0.7680.80** | 远超 Win7 支持上限（最后一个支持 Win7 的是 Chromium 109） |
| Node（Electron 内置） | 24.14.0，ABI 145 | 主进程 `node:sqlite` 等能力来自这里 |
| Node（Web 版随包） | **24.21.0** | `runtime\node.exe`，`node:sqlite` 3.53.4 |
| Agent bundle | `zcode.cjs`（CLI 构建产物） | 由 `scripts/build-desktop-agent-cli.mjs` 产出 |
| electron-builder | ^26.8.1 | 本项目**没有**用它打包 Win7 版（见 03/05） |

读取 Electron 实际版本的方法（在仓库里执行）：

```powershell
node -e "console.log(JSON.stringify(require('./node_modules/electron/package.json').version))"
# 或在 Electron 里：const v = process.versions  → electron / chrome / node / v8 / modules
```

## 3. 必须装的东西（离线安装包会自动检查）

1. **PowerShell 5.1（WMF 5.1）**：安装脚本使用 `Expand-Archive`/`ZipFile`、`Start-Process -Verb RunAs` 等。
2. **VxKex-NEXT**：为两个 exe 提供 Win8/Win10 导出函数。
   - 安装目录：`C:\Program Files\VxKex`，判定文件 `Kex64\KxBase.dll`
   - 安装包内附 `KexSetup_Release_1_1_3_2038.exe`；检测不到时会提示并拉起安装器
3. **VC++ 2015-2022 x64 运行库**：Electron 与 node-pty 等原生模块依赖。
4. **.NET Framework 4.5+**：PowerShell 与部分脚本依赖。

> 不需要：Git、Python、Visual Studio、node-gyp、7-Zip（安装器用 .NET 解压）。
> 目标机也不要求预装 Node——Web 版自带 `node.exe`。

## 4. VxKex 注册格式（必须背下来）

VxKex NEXT 的过滤项**按可执行文件绝对路径**匹配。注册位置：

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<exe 文件名>
├─ UseFilter = 1                      (DWORD)
└─ VxKex_<自定义名>
   ├─ FilterFullPath        = <exe 绝对路径>   (SZ)
   ├─ KEX_DisableForChild   = 0               (DWORD)
   ├─ KEX_DisableAppSpecific= 0               (DWORD)
   ├─ KEX_WinVerSpoof       = 0               (DWORD)
   ├─ KEX_StrongVersionSpoof= 0               (DWORD)
   ├─ GlobalFlag            = 0x100           (DWORD 256)
   ├─ VerifierFlags         = 0x80000000      (DWORD 2147483648)
   └─ VerifierDlls          = kexdll.dll      (SZ)
```

本项目需要两条（安装器自动写）：

| exe | 过滤项名 |
| --- | --- |
| `...\desktop\ZCode.exe` | `VxKex_ZCODE_DESKTOP` |
| `...\web\runtime\node.exe` | `VxKex_ZCODE_WEB` |

排查用的读取命令：

```powershell
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ZCode.exe" /s
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\node.exe" /s
```

> 同一台机器上 `node.exe` 下可能还有别的程序的过滤项（如 BrowserOS），**只删本项目那一条**。

## 5. 为什么必须是 VxKex

| 程序 | 缺什么 | 现象 |
| --- | --- | --- |
| Node 24（`node.exe`） | Win8/Win10 的 kernel32 导出 | 未注册时 `0xC0000139`（STATUS_ENTRYPOINT_NOT_FOUND）秒退 |
| Electron 41（`ZCode.exe`） | 同上，且 PE 头声明子系统 10.0 | 未改 PE：`不是有效的 Win32 应用程序`；改了 PE 未注册：`0xC0000139` |

两处缺一不可，详见 [03-desktop-mode.md](./03-desktop-mode.md)。
