# 多模型路由

给 DSH 里已经装着的通用适配器 `@deepseek-ai/dsh-llm-pi-ai` 补上路由声明，并打开子代理的显式选模型授权。不新增任何运行时逻辑，包里的 `index.js` 是空壳。

## 做了什么

**七条 OpenAI 兼容路由**

| 路由键 | 端点 | 凭据引用 | 模型 |
|---|---|---|---|
| `ollama` | `http://127.0.0.1:11434/v1` | 无（本地） | `qwen2.5vl:7b`、`qwen2.5vl:3b` |
| `zhipu` | `https://open.bigmodel.cn/api/paas/v4` | `ZHIPU_API_KEY`（已配） | 免费档：`glm-4-flash`、`glm-4-flash-250414`、`glm-4.5-flash`、`glm-4.7-flash`、`glm-z1-flash`、`glm-4v-flash` |
| `pollinations` | `https://text.pollinations.ai/openai` | 无（免 Key） | `openai-fast`（GPT-OSS 20B） |
| `modelscope` | `https://api-inference.modelscope.cn/v1` | `MODELSCOPE_API_KEY`（待填） | `deepseek-ai/DeepSeek-V4.1-Flash`、`Qwen/Qwen3.8-Flash-Next`、`moonshotai/Kimi-K3.1-Pro` |
| `openrouter` | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY`（待填） | `baidu/ernie-5.5-flash-preview:free`、`nvidia/nemotron-3-ultra-550b-a55b:free`、`google/gemma-4-31b-it:free` |
| `doubao` | `https://ark.cn-beijing.volces.com/api/v3` | `ARK_API_KEY` | `doubao-seed-2-1-pro-260915` |
| `deepseek` | `https://api.deepseek.com` | `DEEPSEEK_API_KEY`（待填，付费） | `deepseek-v4-flash`、`deepseek-v4-pro` |
| `tokenhub` | `https://tokenhub.tencentmaas.com/v1` | `TOKENHUB_API_KEY` | `deepseek-v4-pro`、`hy3`、`glm-5.3`、`kimi-k3.1-pro` |

免费档的额度、限速、申请入口和失败码见 [FREE-MODELS.md](./FREE-MODELS.md)。`groq` / `gemini` / `siliconflow` 的配置段已写好但保持注释，拿到 Key 再放开。

**元宝 = 混元 = `tokenhub/hy3`**。`tokenhub` 是腾讯云现在的聚合入口，同一个 Key 能调多家模型，新开通走这条。

`hunyuan` 直连（旧平台入口 `https://api.hunyuan.cloud.tencent.com/v1`）已于 2026-11-14 **停用**：`HUNYUAN_API_KEY` 被腾讯云拒绝，连 `GET /v1/models` 都返回 401、响应体为空。补丁里该 provider 段已注释掉，白名单里两条记录也一并注释，换到有效 Key 后取消注释即可恢复。

**会话白名单**：`subagent-model-selection-settings` 打开 `enabled` 并列出上面这些路由（加上父路由 `deepseek-account/deepseek-flash`）。

这一步不是可选的：DSH 在**会话创建时**把白名单记进会话，没有记录时子代理只能继承父路由，点名别的模型会直接报 `child LLM route ... is not allowed for this Session`。所以配置只对**之后新建的会话**生效，当前已存在的会话不会改变。

## 填 Key

配置里只有引用名，没有密钥本身。拿到 Key 后二选一：

- 设置 → 模型，写入 `ARK_API_KEY` / `HUNYUAN_API_KEY`；
- 或在启动 DSH 的环境里导出同名环境变量。

适配器每个请求都重新解析凭据，**改 Key 不需要重启**。只有改「路由集合」（增删 provider、改 retryPolicy）才需要重载。

## 直连兜底通道

路由不可用（会话白名单没带上、注册没生效）时，`bin/llm.ps1`（Windows 上用 `bin/llm.cmd` 包一层绕执行策略）可以直连三家端点：

```powershell
bin\llm.cmd -Provider ollama -Model qwen2.5vl:7b -Prompt "1+1=?" -MaxTokens 64
```

退出码 0 成功 / 1 请求失败 / 2 正文为空 / 3 凭据缺失。它绕开 DSH 的模型路由，任何会话、任何目录都能用，适合单问单答和端点探活；多轮工具调用仍应走 DSH 路由。

同目录还有三个工具：

| 脚本 | 用途 |
|---|---|
| `bin\smoke.cmd` | 一次列出所有通道的存活状态（`OK` / `HTTP 4xx` / `NOKEY` / `EMPTY`）与耗时，`-Quick` 只测免费档 |
| `bin\ask.cmd` | 单问入口：一个问题交给免费模型，通道按 `250414 → glm-4-flash → z1-flash → pollinations` 自动切换，正文到 stdout、耗时到 stderr |
| `bin\fanout.cmd` | 把 N 条互不依赖的**文字**任务并行派给免费模型，结果落盘；`-Workers "a/b,c/d,e/f"` 轮流用多个工人（限流通道自动排队），`-PromptFile` 传单条多行提示 |
| `bin\check-patch.cmd` | 校验本文件 `cordis.patch.yml` 的 YAML 结构与「路由 ↔ 白名单」一致性 |
| `bin\grade-extract.cmd` | 用同一道 10.6KB 抽取题给所有模型打分（`-Light` 只测免费档，`-Only 名字` 跑单个），用来判断某个免费模型能不能干结构化活 |
| `bin\media.cmd` | Ark 付费出图（Seedream）/出视频（Seedance，账号未开通）；凭据先读环境变量再读 `~/.dsh/.credentials.yaml` |
| `bin\free-media.cmd` | 免费出图/出视频（默认 pollinations，`-Provider zhipu` 走智谱免费档）。**动手前先问用户走哪条通道**：出图消耗额度，出视频贵一到两个数量级 |

实现上刻意用了 `System.Net.Http` 而不是 `Invoke-RestMethod`：Windows PowerShell 对不带 charset 的 `application/json` 按 Latin-1 解码，中文会整段变乱码。脚本源码也全是 ASCII，因为无 BOM 的 `.ps1` 会被按 ANSI 读取。

## 需要核对的地方

- **豆包型号 id**：写的 `doubao-seed-2-1-pro-260915` 是官方 OpenAI 兼容文档里的示例写法。控制台「开通管理」里复制到的名称可能不同；若用自建推理接入点，id 是 `ep-` 开头的。对不上时只改 `models[].id`，并在白名单里同步改。
- **混元默认 5 并发**（主子账号共享），并行扇出到 `tokenhub/hy3` 不要超过 5 路。
- 云端模型 id 写错不会影响启动，只会在真正调用该模型时失败。

## 已验证 / 未验证

- 已验证（2026-11-14 14:12，真 Key 端到端）：**豆包** `doubao/doubao-seed-2-1-pro-260915` 子代理实跑返回 `OK|doubao-seed-2-1-pro-260915|7*8=56`，直连 ARK `HTTP 200`；**元宝/混元** `tokenhub/hy3` 子代理实跑返回 `OK|hy3|7*8=56`，直连 TokenHub `HTTP 200`。
- 已验证（2026-11-14 15:0x，`llm.cmd` 直连）：**智谱免费档** `glm-4-flash`（1215ms）、`glm-4v-flash`（581ms）、`glm-4.5-flash`、`glm-4-flash-250414`、`glm-z1-flash` 均返回正文；**pollinations 免 Key 通道** `openai-fast` 返回正文（限 1 次/45 秒）；`glm-4.7-flash` 高峰 `1305`。缺 Key 时退出码 3，符合预期。
- 已验证（配置层）：Host 侧 `resolveCallConfig` 解析路由成功；Ollama `/v1` 中文往返正确；补丁 YAML 可解析；路由与白名单交叉比对零差异；直连兜底脚本退出码符合预期。
- **已失效**：`hunyuan` 直连在真 Key 下返回 `401 Unauthorized`（`GET /v1/models` 同样 401、body 为空），已从路由表与白名单移除，元宝改走 `tokenhub/hy3`。
- 未验证：**本会话内**的子代理点名（会话白名单为建会话时快照，且新增路由要重开 DSH 才注册）；`modelscope` / `openrouter` 的真实推理（没有 Key）；`glm-4v-flash` 在 DSH 路由里的图像入参。细节见 [VERIFY.md](./VERIFY.md)。

## 诊断探针

`diagnostics/report.json` 由本包在每次挂载时写入，记录各路由的解析结果。它不发起网络请求，只回答"路由注册没有"——这是旧会话受白名单限制时唯一的自证手段。**它不验证凭据**：`ok: true` 只代表路由能解析，Key 失效要真发一次请求才暴露（`hunyuan` 的 401 就是这样查出来的）。

## 边界

- 本地三个模型都很小（3B–7B）。实测 `qwen2.5vl:7b` 能用但中文指令跟随很弱（会用英文反问你），`qwen2.5vl:3b` 更弱，`qwen3-vl:8b` 在 OpenAI 端点上会把 token 全花在思考上、正文返回空，已排除。本地路由只适合看图、OCR、批量打标这类窄任务。
- 云端路由按量计费，且会把请求内容发到对应厂商；涉及不能外传的数据时走本地路由或不要外发。
- 本包只声明路由，不包含任何厂商 SDK，也不代理请求。

## 卸载

在插件管理里移除本 bundle 即可，两条被覆盖的配置随之还原。
