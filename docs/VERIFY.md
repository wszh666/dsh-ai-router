# 验证清单

## 已验证（2026-11-14）

| 项 | 方法 | 结果 |
|---|---|---|
| Ollama `/v1/chat/completions` | 直连 POST | 200，中文往返正确 |
| 豆包端点 | 假 Key 探活 | **401**，260ms —— 端点与路径正确 |
| 混元端点 | 假 Key 探活 | **401**，1.4s —— 端点与路径正确 |
| TokenHub 端点 | 假 Key 探活 | **401**，434ms —— 端点与路径正确 |
| **路由注册** | Host 侧 `resolveCallConfig` | **9/9 全部解析成功** |
| 豆包真实推理 | `chat/completions` + 真 Key | 200，2.6s，中文正确；`finish=tool_calls` 工具调用正常 |
| TokenHub 真实推理 | `chat/completions` + 真 Key | 200；`deepseek-v4-pro`/`hy3`/`glm-5.3` 均返回正确中文；`/v1/models` 可列 132 个 |
| **豆包端到端（子代理）** | 2026-11-14 14:12 真 Key | **通过**，返回 `OK\|doubao-seed-2-1-pro-260915\|7*8=56` |
| **元宝/混元端到端（子代理）** | `tokenhub/hy3` 真 Key | **通过**，返回 `OK\|hy3\|7*8=56`；直连 TokenHub 200 |
| **混元直连** | `hunyuan` 真 Key | **失败 401**，`GET /v1/models` 同样 401、body 为空 → 已停用 |
| 补丁 YAML | js-yaml 解析 | 结构正确 |
| 路由 ↔ 白名单 | 脚本交叉比对 | 双向零差异 |
| skill 生效 | 技能目录 | 已出现在本会话目录并可加载 |
| 直连兜底脚本 | 实跑 | 中文往返正确，退出码 0/1/2/3 均符合预期 |
| **智谱免费档** | `llm.cmd` 真 Key | **通过**：`glm-4-flash`(1.2s)、`glm-4-flash-250414`(1.1s)、`glm-4.5-flash`、`glm-z1-flash`(@2048)、`glm-4v-flash`(0.6s) 均返回正文；`glm-4.7-flash` 高峰 `1305`；`glm-4.6-flash` `1220` 无权限 |
| **pollinations 免 Key 通道** | `llm.cmd` 无凭据 | **通过**：`openai-fast` 返回正文；限 1 次/45 秒（`402 FREE_LIMIT`） |
| 智谱模型目录 | `GET /api/paas/v4/models` | 200，列全量型号（含付费）；免费档按 4.x Flash 认 |
| 魔搭 / OpenRouter 目录 | `GET {base}/models`（免鉴权） | 200：魔搭 38 个、OpenRouter 14 个 `:free`；路由里的 id 已按此核实 |
| 补丁 YAML + 白名单 | `bin\check-patch.cmd` | YAML 可解析；21 条白名单与路由交叉零差异 |

`resolveCallConfig` 是子代理调用前执行的那道预检。它把 provider、model、maxTokens 都解析出来了，说明：

- `llm-pi-ai` 适配器**确实注册了** `ollama`、`doubao`、`tokenhub` 三条路由（`hunyuan` 已于 2026-11-14 因 401 停用）；
- 模型 id 在运行时**能被解析**（豆包那个日期型号写法也被接受了）；
- 剩下的只有"凭据"和"会话白名单"两件事。

## 未验证

| 项 | 为什么 | 怎么补 |
|---|---|---|
| 本会话内子代理点名非父路由 | 会话白名单在建会话时快照，本会话早于配置 | 开新会话 |
| 云端真实推理 | 没有 Key | 见下文"拿到 Key 之后" |

## 诊断探针

`diagnostics/report.json` 由插件在每次挂载时写入（**不发起任何网络请求**），记录五条路由的解析结果与 `llm` 服务的可用方法。它是排查"路由到底注册没有"的唯一自证手段，因为旧会话受白名单限制、问不出来。

局限：它只验证**路由可解析**，不验证凭据有效、也不验证真实推理。云端那条 `ok: true` 不代表 Key 能用。

## 拿到 Key 之后

1. 填凭据：设置 → 模型，写入 `ARK_API_KEY`、`TOKENHUB_API_KEY`；或启动前导出同名环境变量。**不需要重启**。
   `HUNYUAN_API_KEY` 目前是失效状态（401），要恢复混元直连得先去腾讯云控制台重新开通混元生文、拿新的 Key。
2. 真跑一次（在任意会话里让我执行）：
   ```
   bin\llm.cmd -Provider doubao -Model doubao-seed-2-1-pro-260915 -Prompt "你好" -MaxTokens 32
   ```
   退出码 0 且正文非空 = 凭据有效、端点通。
3. **模型 id 对不上就换**：把控制台「开通管理」里的名称，或 `ep-` 开头的接入点 id，填进 `cordis.patch.yml` 的 `models[].id`，**同时**改白名单里的同名条目——两处必须一致，否则会出现"路由声明了但选不了"。
4. 改完重新安装 bundle 才生效（改路由集合要重载；只改 Key 不用）。

## 新会话验证（最终确认）

新建会话后说：

> 调 list_subagent_models()，把结果原样贴出来

期望看到 `ollama`、`zhipu`、`pollinations`、`modelscope`、`openrouter`、`doubao`、`tokenhub`（外加 `deepseek-account`）；`hunyuan` 已停用，出现它才需要核对。若仍报 `not allowed`，说明补丁需要重启才重放，重启 DSH 再试。

**新增路由必须重开 DSH 才注册**（改 bundle 的 `cordis.patch.yml` 不触发热重载）。判断有没有生效：看 `diagnostics/report.json` 的 `at`，里面应该出现 `zhipu` / `pollinations` 的探针。

## 混元的额外限制

默认 **5 并发**，主子账号共享。并行扇出到混元不要超过 5 路。
