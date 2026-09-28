# llama.cpp Radeon 780M (gfx1103) Nightly 自动构建系统与版本记录

本项目配置了针对 **AMD Radeon 780M (`gfx1103`)** 的 GitHub Actions 每日凌晨自动滚动构建与版本发布流水线。

---

## ⏰ 构建规范与调度

- **定时触发**：每天北京时间凌晨 **03:00**（`cron: 0 19 * * *`）
- **llama.cpp 源码基准**：动态拉取官方主线 [`ggml-org/llama.cpp:master`](https://github.com/ggml-org/llama.cpp) 当天最新 Commit
- **ROCm SDK 基准**：动态从 AMD 官方源 [`nightly.repo.amd.com`](https://nightly.repo.amd.com/rocm/core/tarball/) 匹配下载当天最新的 Windows TheRock 10.2+ 发行包
- **输出产物**：自包含绿色便携包（内嵌 `.kpack` 完整矩阵算子包及核心驱动 DLL，解压即用）
- **发布位置**：GitHub Releases 标签 [`nightly-gfx1103`](https://github.com/Jiaocha/llama.cpp/releases/tag/nightly-gfx1103)

---

## 📋 历史构建版本对照记录

| 发布日期 | Release 标签 | llama.cpp Commit | TheRock ROCm SDK | 校验信息 | 说明 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **2026-09-28** | `nightly-gfx1103` | 自动跟进主线最新 | `10.2.0a20260927`+ | SHA256 随构建生成 | 正式启用新一代每日全自动构建与动态 SDK 探测 |
| 2026-09-24 | `gfx1103-hip-7.11.0` | `b1-43ac76e` | `7.11.0a20260120` | - | 旧版手工触发归档版本 |

---

## 🛠️ 便携包使用说明

下载解压后，无需安装任何 ROCm 或配置复杂环境变量：
- **终端对话**：`llama-cli.bat -m 模型.gguf -ngl 99 -fa on`
- **本地 API/WebUI 服务**：`llama-server.bat -m 模型.gguf -ngl 99 -fa on --port 8080`
- **基准性能压测**：`llama-bench.bat -m 模型.gguf -ngl 99 -fa on`
