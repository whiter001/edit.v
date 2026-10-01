# edit (V)

[microsoft/edit](https://github.com/microsoft/edit)（Rust）的 V 语言重写——一个简单、快速、跨平台的终端文本编辑器。

**当前范围（第一版）**：核心编辑器功能，支持 macOS / Linux / Windows（Windows 需真实控制台：cmd / PowerShell / Windows Terminal；mintty / Git Bash 的 MSYS pty 不是 Windows console，raw mode 会报 "needs a real console"，属预期），UTF-8 only，无 ICU / i18n / SIMD。

## 功能

- **多文档**：Ctrl+N 新建、Ctrl+O 打开、Ctrl+W 关闭、Ctrl+P / Ctrl+PgUp / PgDn 切换
- **搜索 / 替换**：常驻面板（Ctrl+F 搜索、Ctrl+R 替换），支持大小写 / 整词 / 正则（Alt+C/W/R）、F3 / Shift+F3 跳命中、Replace All 单次 undo group
- **文件选择器**：打开 / 另存（Ctrl+O / Ctrl+Shift+S），目录导航 + 鼠标点选
- **语法高亮**：lsh 引擎，打开文件时按 glob 自动检测语言
- **编码**：编码选择器，严格的 iconv 读写路径
- **菜单栏**：File / Edit / View / Help + About 对话框（F10 聚焦）
- **鼠标**：点击定位、滚轮、左键拖拽选择
- **其他**：跳转行（Ctrl+G）、脏文件关闭 / 退出二次确认、底部状态栏、剪贴板

## 构建与运行

需要 [V 编译器](https://vlang.io)（`v` 在 PATH 中）。

```bash
./build.sh          # dev build（默认），产物在 bin/edit
./build.sh prod     # prod build（-O3 + strip）
./build.sh test     # 跑单元测试
./build.sh install  # 安装到 PREFIX/bin（默认 /usr/local）
./build.sh help     # 全部模式与环境变量
```

运行：

```bash
bin/edit [文件...]
bin/edit -g 文件:行[:列]   # 打开并跳到指定位置
bin/edit -                 # 从 stdin 读入
bin/edit --help
```

## 常用快捷键

| 按键 | 功能 |
|---|---|
| Ctrl+N / Ctrl+O / Ctrl+W / Ctrl+S | 新建 / 打开 / 关闭 / 保存 |
| Ctrl+Shift+S | 另存为 |
| Ctrl+F / Ctrl+R | 搜索 / 替换面板 |
| F3 / Shift+F3 | 下一个 / 上一个命中 |
| Ctrl+G | 跳转行号 |
| Ctrl+P / Ctrl+PgUp / Ctrl+PgDn | 切换文档 |
| F10 | 聚焦菜单栏 |
| Alt+C / W / R（面板内） | 大小写 / 整词 / 正则 |

## 项目结构

扁平 `.v` 文件，统一 `module main`，测试为 `*_test.v`：

- `main.v` — 主循环、多文档、状态栏
- `text_buffer.v` / `gap_buffer.v` / `document.v` — 文本缓冲（gap buffer，移植自 Rust TextBuffer）
- `search_panel.v` / `menubar.v` / `filepicker.v` / `encoding_picker.v` / `goto_file.v` — UI 组件
- `lsh_runtime.v` / `highlighter.v` / `lsh_tables.v` — 语法高亮（`lsh_tables.v` 为离线生成，由 `tools/lsh_tables_to_v.py` 转换）
- `input.v` / `vt.v` / `framebuffer.v` — 输入解析与渲染
- `sys.v` / `sys_nix.c.v` / `sys_windows.c.v` — 平台层（raw mode、stdin、resize）
- `tools/` — 冒烟测试与表生成脚本（Python）

## 测试与冒烟

```bash
./build.sh test                      # 单元测试
python3 tools/smoke.py <文件> <hex按键>   # 端到端冒烟（pty 驱动，仅 Unix）
```

## 注意事项

- V 工具链偶发 CPU / 内存失控：跑 V 编译 / 测试 / fmt 时建议用 `cpulimit -l 200 -z --` 包一层（Windows Git Bash 无 cpulimit，直接跑）；`build.sh` 内置内存看门狗（`MEMLIMIT_MB`，默认 2048MB，测试 4096MB，`0` 关闭）。
- 参考源码（Rust 原版）为只读对照，不要修改。
- 更多移植状态与 V 工具链踩坑记录见 [AGENTS.md](AGENTS.md)。

## 许可

MIT
