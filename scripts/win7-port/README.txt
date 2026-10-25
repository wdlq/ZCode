ZCode for Windows 7 —— 离线安装包
==================================

适用：Windows 7 SP1 x64（离线可用），LLM 使用局域网内自建模型服务。


一、安装前需要什么
------------------
1. Windows 7 SP1 64 位。
2. PowerShell 5.1（WMF 5.1，Win7 需手动装；本安装包不会联网下载）。
3. VxKex-NEXT（必需）。安装包内附 KexSetup 安装程序；若未安装，安装脚本会提示并拉起它。
   Win7 上 Electron 41 与 Node 24 都依赖它补齐 Win8/Win10 导出函数。
4. 局域网内可访问的模型服务（OpenAI 兼容 /anthropic 兼容均可），以及对应 API Key。


二、安装
--------
方式 A（单文件安装器，推荐）
  双击 ZCode-Win7-Offline-Setup.exe
  安装器会请求管理员权限，然后自动完成解压、注册、快捷方式创建。

方式 B（目录形态）
  解压本目录后，右键「安装.cmd」→ 以管理员身份运行。

默认安装目录：C:\Program Files\ZCode-Win7
可用 -TargetDir 指定其它目录：
  install.ps1 -TargetDir "D:\ZCode"

安装过程做了什么：
  1. 解压 desktop（Electron 原生端）与 web（Node 服务 + Web UI）
  2. 为 desktop\ZCode.exe 与 web\runtime\node.exe 注册 VxKex 过滤项（按绝对路径）
  3. 创建桌面与开始菜单快捷方式
  4. 写 install.json（版本、安装时间、payload 哈希）

注意：VxKex 的过滤项绑定绝对路径。如果手动移动了安装目录，必须重新运行安装，
或在 HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\
对应 exe 名下更新 FilterFullPath，否则程序会以 0xC0000139 秒退且没有提示。


三、启动
--------
桌面端（原生，自带内置浏览器 IAB）
  双击桌面「ZCode 桌面版」
  数据目录：%APPDATA%\ZCode

Web 端（浏览器 UI，无 IAB）
  双击「ZCode Web 版」→ 默认打开 http://127.0.0.1:3030/
  默认只监听回环地址；需要局域网访问时：
    <安装目录>\web\launcher\start-zcode.ps1 -LanAccess
  token 写入 <安装目录>\web\logs\lan-token.txt
  数据目录：%USERPROFILE%\.zcode


四、配置局域网模型（离线关键步骤）
----------------------------------
桌面版 / Web 版都是同一套配置入口：设置 → 模型设置 → 添加供应商 → 创建自定义供应商。

OpenAI 兼容（常见本地部署：vLLM / Ollama / LM Studio / one-api）
  Base URL：http://<模型服务器 IP>:<端口>/v1
  API 格式：OpenAI Compatible
  API Key：按服务端要求填写（本地无鉴权时可随便填一个非空值）
  模型 ID：服务端实际暴露的模型名

Anthropic 兼容
  Base URL：http://<模型服务器 IP>:<端口>
  API 格式：Anthropic Messages (/v1/messages)

保存后务必把「供应商」和「模型」两个开关都打开（界面显示“禁用”即表示已启用）。
配置保存后不会联网校验，可完全离线使用。


五、目录说明
------------
desktop\              原生端（ZCode.exe 已打过 PE 补丁，资源在 resources\）
web\app\zcode\        Web 端运行包（web / server / agent）
web\runtime\node.exe  Node 24（已注册 VxKex）
web\launcher\         Web 端启动/停止脚本
tools\                browser-verify.mjs（无 IAB 时的浏览器验证）、desktop-ui-check.mjs
AGENTS.md             浏览器后端选择约定（供 Agent 读取）
install.json          安装记录


六、卸载
--------
1. 停止正在运行的 ZCode（桌面端直接关窗口；Web 端运行 web\launcher\stop-zcode.ps1）
2. 删除安装目录（默认 C:\Program Files\ZCode-Win7）
3. 可选：删除 %APPDATA%\ZCode 与 %USERPROFILE%\.zcode（用户数据，谨慎）
4. 可选：删除注册表
   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ZCode.exe
   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\node.exe\VxKex_ZCODE_WEB
   
   注意 node.exe 下可能还有其它程序的 VxKex 项，只删 VxKex_ZCODE_WEB 这一项。


七、已知问题
------------
1. 从 SSH / 计划任务等无交互桌面会话启动桌面端时，日志会出现
   "Unable to find a primary display"，且内置浏览器可能无法挂载。请在桌面里双击启动。
2. VxKex 下 DPAPI 受限，日志可能报 os_crypt "Failed to encrypt: 0x5"，
   影响 Chrome cookie 导入等非核心功能。
3. 内置浏览器（IAB）在 Web 端不可用（设计如此）：Web 端请用 tools\browser-verify.mjs，
   或按 AGENTS.md 的约定使用 Tabbit。
4. 首次启动如果任务是空列表，是因为桌面端与 Web 端数据目录不同，不是安装失败。
