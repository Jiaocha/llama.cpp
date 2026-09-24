# llama.cpp HIP 便携版（AMD Radeon 780M / gfx1103）

这是为 **AMD Ryzen 7 8845HS 核显 Radeon 780M（gfx1103）** 从 llama.cpp 最新主线编译的
**自包含 HIP（ROCm）Windows x64 便携包**。解压即可运行，无需手动安装 ROCm、无需拷贝任何 DLL。

## 特性

- 基于 llama.cpp 最新主线（HIP 后端），原生支持 qwen3 / qwen3moe / qwen35 / qwen35moe / qwen3next / qwen3vl 等新架构。
- 内置 TheRock ROCm 7.11 运行时（amdhip64、rocblas、hipblas、amd_comgr、rocsolver 等）。
- 内置 **96 个 gfx1103 专用 rocBLAS 内核**，解决官方 ROCm 预编译包缺少 gfx1103 内核导致的 `invalid device function` 问题。
- 全部运行时与内核已打包进目录，解压即用。

## 使用方法

1. 解压 `llama-gfx1103-portable.zip` 到任意目录（路径不要有中文/空格更稳妥）。
2. 命令行进入该目录，直接运行：

```bat
:: 命令行对话
llama-cli.exe -m 你的模型.gguf -ngl 99 -fa on

:: 起 OpenAI 兼容 server（默认端口 8080）
llama-server.exe -m 你的模型.gguf -ngl 99 -fa on --port 8080
```

常用参数：
- `-ngl 99`：尽量把层卸载到 GPU。
- `-fa on`：开启 Flash Attention（新版必须带 `on`）。
- `-c 8192`：上下文长度。

## 实测性能（Radeon 780M，Qwen3.6-35B-A3B Q4_K_P）

- Prompt 处理：约 40+ t/s
- 文本生成：约 23–24 t/s

## 注意事项

- **首次启动较慢**：加载约 20GB 级模型 + HIP 内核预热需要几分钟，期间无输出属正常，不是卡死。
- 本包只适用于 gfx1103（Radeon 780M）。其他显卡请用官方对应发行版。
- 模型文件（.gguf）不包含在内，需自行下载。
- 本构建 `--spec-type draft-mtp` 已支持 MTP 投机采样，但需要配套的 MTP 头模型。

## 构建方式

由 GitHub Actions 从 llama.cpp 上游 master 自动编译：
- Runner：windows-2022（MSVC 14.4x，规避新版 MSVC `<cmath>` 与 ROCm clang 的冲突）
- TheRock：therock-dist-windows-gfx110X-all-7.11.0a20260120
- CMake：`-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1103 -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF`