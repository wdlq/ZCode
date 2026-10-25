#!/usr/bin/env node
// 修改 PE32+ 可执行文件的 OS / Subsystem 版本，让 Windows 7 加载器接受 Electron 41 的 exe。
//
// 用法：
//   node scripts/win7-port/patch-pe-subsystem.mjs <input.exe> [output.exe]
//
// 背景：
//   electron.exe 的可选头声明 SubsystemVersion = 10.0，Win7 加载器在映射镜像前就拒绝
//   （报"不是有效的 Win32 应用程序"），此时 VxKex 没有介入机会。改成 6.1 后才会进入
//   "缺 Win8/Win10 导出函数"的阶段，再由 VxKex 补齐。
//
// 等价命令：editbin /SUBSYSTEM:WINDOWS,6.01 <exe>
import { readFileSync, writeFileSync } from "node:fs";

const [input, output] = process.argv.slice(2);
if (!input) {
  console.error("用法: node scripts/win7-port/patch-pe-subsystem.mjs <input.exe> [output.exe]");
  process.exit(2);
}

const buffer = readFileSync(input);
if (buffer.readUInt16LE(0) !== 0x5a4d) throw new Error("不是 PE 文件（缺少 MZ 头）");

const peOffset = buffer.readUInt32LE(0x3c);
if (buffer.toString("ascii", peOffset, peOffset + 4) !== "PE\0\0") throw new Error("不是 PE 文件（缺少 PE 签名）");

const optionalHeader = peOffset + 24;
const magic = buffer.readUInt16LE(optionalHeader);
if (magic !== 0x20b) {
  throw new Error(`仅支持 PE32+（0x20b），当前可选头 magic=0x${magic.toString(16)}`);
}

const readPair = (offset) => `${buffer.readUInt16LE(offset)}.${buffer.readUInt16LE(offset + 2)}`;
console.log(
  JSON.stringify(
    {
      file: input,
      machine: "0x" + buffer.readUInt16LE(peOffset + 4).toString(16),
      osVersion: readPair(optionalHeader + 40),
      subsystemVersion: readPair(optionalHeader + 48),
    },
    null,
    2,
  ),
);

// OS 版本与子系统版本一起改成 6.1（Windows 7）
buffer.writeUInt16LE(6, optionalHeader + 40);
buffer.writeUInt16LE(1, optionalHeader + 42);
buffer.writeUInt16LE(6, optionalHeader + 48);
buffer.writeUInt16LE(1, optionalHeader + 50);

const target = output ?? input.replace(/\.exe$/i, "") + "-win7.exe";
writeFileSync(target, buffer);
console.log(`patched -> ${target} (os 6.1 / subsystem 6.1)`);
