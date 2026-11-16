# 免费模型通道清单

> 只写**真发过请求**的结论。日期写实测那天。清单会随厂商调整免费政策失效，失效了就改状态、别删。
> 最后更新：2026-11-14

## 一、现在就能用（不需要新注册）

| 路由 | 模型 | 门槛 | 实测 |
|---|---|---|---|
| `zhipu` | `glm-4-flash`、`glm-4-flash-250414` | 免费、无 token 上限（只有并发限制），Key 已在 `ZHIPU_API_KEY` | ✅ 2026-11-14，200–1200ms 返回正文 |
| `zhipu` | `glm-4.5-flash`、`glm-z1-flash` | 同上，思考型 | ✅ 有正文（4.5-flash 约 9s，思考占大头） |
| `zhipu` | `glm-4v-flash` | 同上，视觉免费档 | ✅ 纯文本往返正确；图像入参未验证 |
| `zhipu` | `glm-4.7-flash`（200K，Agentic Coding） | 同上，免费 | ⚠️ 高峰固定返回 `1305 访问量过大`（429），错峰重试 |
| `pollinations` | `openai-fast`（GPT-OSS 20B，带工具调用） | **完全免 Key**，OpenAI 兼容 | ✅ 2026-11-14 返回正文；限 **1 次/45 秒/IP** |
| `ollama` | `qwen2.5vl:7b` / `3b` | 本地，不需要 Key | ✅ 中文往返正确，但指令跟随很弱 |

CLI 直连（任何会话、任何目录都能用）：

```
bin\llm.cmd -Provider zhipu     -Model glm-4-flash -Prompt "你好" -MaxTokens 64
bin\llm.cmd -Provider pollinations -Model openai-fast -Prompt "你好" -MaxTokens 512
bin\llm.cmd -Provider zhipu -ListModels        # 列厂商目录里的全部模型 id
bin\check-patch.cmd                             # 校验补丁 YAML + 路由/白名单一致性
```

两个实测细节：`glm-z1-flash` 把思考过程写进正文（`<think>…</think>` 后面才是答案），要拿干净答案得自己裁；`glm-4-flash` 系列是真正的"快而便宜"，杂活优先用它。

## 一·五、性能实测（2026-11-14 15:00，各 2 轮：中文问答 + 严格 JSON）

| 模型 | 中文问答 | 严格 JSON | 结论 |
|---|---|---|---|
| `glm-4-flash-250414` | 743ms，36 字通顺 | **537ms，裸 JSON 合规** | **免费主力首选** |
| `glm-4-flash` | 891ms，32 字通顺 | 2653ms，JSON 被 ```json 包裹 | 次选，需剥代码块 |
| `glm-4v-flash` | 803ms，45 字通顺 | 728ms（同样被包裹） | 视觉档也能当文本快模型 |
| `glm-4.5-flash` | 4477ms | **EMPTY，finish=length**（256 token 全被思考吃掉） | 只在 `max_tokens ≥ 1024` 时可用 |
| `glm-z1-flash` | 2328ms，正文含 `<think>` | finish=length（思考挤爆预算） | 推理档，要自己裁思考块 |
| `pollinations/openai-fast` | 16.9s（慢） | **HTTP 402 FREE_LIMIT** | 只够单问，不能进流水线 |

结论：**要"不报错、可进流水线"，用 `glm-4-flash-250414`；要快就加 `glm-4v-flash`；思考型一律给足 `max_tokens`。**

## 一·六、DeepSeek 怎么接（付费，但没有免费的替代品）

- 官方 API：`https://api.deepseek.com`，模型名现在是 `deepseek-v4-flash`（便宜档）/ `deepseek-v4-pro`（旗舰），旧的 `deepseek-chat` / `deepseek-reasoner` 别名已到期。**没有免费额度**，要先充值；flash 非高峰约 $0.15/1M 输入、$0.60/1M 输出。
- 路由已写好（`deepseek` provider + 两条白名单），只差 `DEEPSEEK_API_KEY`。填进去后 `llm.cmd -Provider deepseek -Model deepseek-v4-flash` 立刻能用，DSH 里也能被子代理点名。
- **不想再充钱的路**：`tokenhub/deepseek-v4-pro` 现在就能用（2026-11-14 15:00 实测 4.3s 返回中文），走的是已有 TokenHub 账户额度；DSH 主模型本身也是 DeepSeek（`deepseek-account/deepseek-flash` 路由），日常对话不需要额外 Key。

## 一·七、把分支活丢给免费模型（`fanout.cmd`）

一次并行跑 N 条互不依赖的文字任务，结果落盘，正文不进主上下文：

```
bin\fanout.cmd -TasksFile tasks.txt -OutDir out -MaxParallel 4
```

- 任务文件 UTF-8、一行一条、`#` 注释；默认模型 `zhipu/glm-4-flash-250414`。
- 2026-11-14 演示：4 条分支（风险清单 / 验收标准 / 汇报改写 / 合并策略）并行 **24.5s 全部返回，0 费用**。
- 质量边界：**改写、措辞、转格式好用**；**清单类会写成"安全是否可控"这种正确但没用的套话**；**分析类啰嗦、容易撞 `finish=length`（-MaxTokens 给 700 就截断）**。所以只当第一稿，判断和验收自己来。
- 工人不能调工具：不能改文件、不能联网、看不到会话历史。要动手的活走 DSH 子代理（重启 DSH 后 `zhipu` 路由可被子代理点名）。

## 一·八、工人能力对照（同一道抽取题，2026-11-14 15:40）

题目：给一整份 **10.6KB 带注释的 `cordis.patch.yml`**，要求只输出 JSON 数组，列出 8 个 provider 的 `apiKeyEnv`。标准答案 8 项全对、无多余项（`expected.json`）。

| 工人 | 得分 | 耗时 | 说明 |
|---|---|---|---|
| `tokenhub/deepseek-v4-pro` | **8/8** | 9.4s | 付费，稳 |
| `doubao/doubao-seed-2-1-pro-260915` | **8/8** | 6.2s | 付费，最快 |
| `tokenhub/glm-5.3` | **8/8** | 16.4s | 付费 |
| `tokenhub/hy3` | **8/8** | 24.3s | 付费 |
| `zhipu/glm-z1-flash` | **8/8** | 6.2s | **免费**，但正文含 `<think>`，要裁 |
| `zhipu/glm-4.5-flash` | **8/8** | 55.7s | 免费，思考慢 |
| `pollinations/openai-fast` | **8/8** | 18.3s | **免 Key** |
| `zhipu/glm-4-flash-250414` | 6/8 | 4.0s | 把 `pollinations` 的 key 填成了 provider 名、漏 `ollama` |
| `zhipu/glm-4v-flash` | 3/8 | 2.9s | 只抓到 3 个，`max_tokens` 还只能 ≤1024 |
| `zhipu/glm-4-flash` | 3/8 | 15.2s | 漏一半，还把模型名当 provider 混进去 |
| `ollama/qwen2.5vl:7b` / `:3b` | 无 JSON | 48.9s / 9.8s | 回了一大段说明文字，不听话 |
| `zhipu/glm-4.7-flash` | — | — | 高峰 `1305` |
| `tokenhub/kimi-k3.1-pro` | — | — | HTTP 400 `rejected by an internal MaaS component`，换 1024 仍 400 |

结论（已修正早前的错误说法）：
- **10KB 输入不是绝对障碍，取决于模型**：14 个里 7 个满分。早前"同一模型 10KB 就必然编造"的判断只在 `glm-4-flash` 系列上成立。
- **`glm-4-flash` / `glm-4-flash-250414` / `glm-4v-flash` 只适合 ≤2KB 的干净片段做抽取**（816 字时 8/8，10KB 时 3–6/8 且会串行错位）。
- 要处理整份文件级抽取：免费选 `glm-z1-flash`（6s，需裁 `<think>`）或 `pollinations/openai-fast`（18s，1 次/45 秒）；要快且不介意花钱用 `doubao`（6s）。
- 无论哪个模型，**仍然必须机器比对 ground truth**——错的方式很隐蔽（填错值、漏项、把模型名当 provider），肉眼看格式完全正常。

## 一·九、随时确认哪条通道活着：`smoke.cmd`

```
bin\smoke.cmd          # 全通道（含付费/缺 Key 的，缺 Key 显示 NOKEY）
bin\smoke.cmd -Quick   # 只测免费/免 Key 的
```

- 一次一张表：`OK` / `HTTP 4xx` / `NOKEY` / `EMPTY`，附耗时和首句样本。
- 凭据先读环境变量、再读 `~/.dsh/.credentials.yaml`，**任何目录、任何会话可用**（从任意目录实测均可用）。
- 2026-11-14 15:32 实测：`zhipu` 三条免费 + `pollinations` + `ollama` + `tokenhub/hy3` + **`doubao`（火山方舟已从欠费恢复）** 全部 OK；`modelscope`/`openrouter`/`deepseek` NOKEY。

## 一·九、工人池（2026-11-14 定稿）

三条免费通道轮转使用，任务按顺序均摊：

```
fanout.cmd -TasksFile 列表.txt -Workers "zhipu/glm-4-flash-250414,zhipu/glm-z1-flash,pollinations/openai-fast" -MaxParallel 2
```

| 工人 | 单条耗时 | 适合 |
|---|---|---|
| `zhipu/glm-4-flash-250414` | 0.6–1.1s | 小片段抄写、短改写、≤2KB 的抽取（10KB 会错位） |
| `zhipu/glm-z1-flash` | 1.7–14s | 整份文件/长表格抽取（10KB 满分）；正文含 `<think>`，脚本自动裁掉并存 `.raw.md` |
| `pollinations/openai-fast` | 7–18s | 兜底，自动排第二轮、45 秒一条；质量意外地稳（10KB 抽取也满分） |

实测（3 条任务、三个工人轮转）：**总耗时 9.2 秒**（1.1s + 1.7s + 7.1s，其中 pollinations 那条独占第二轮）。

## 一·十、两条工人通道的真实任务表现（2026-11-14 17:45）

| 通道 | 任务 | 结果 | 耗时 |
|---|---|---|---|
| `zhipu/glm-z1-flash` | 从 `llm.ps1` 抄出 9 个参数 + 4 个退出码，输出表格 | **全对**（默认值、退出码含义都准） | 14.3s |
| `pollinations/openai-fast` | 从 `smoke.ps1` 抄出 10 条通道的凭据需求，输出表格 | **10/10 全对** | 17.4s |
| `zhipu/glm-z1-flash` | 读 `fanout.ps1` 并"说明参数与退出码" | ❌ 没给表；按先验讲解代码，**编造了不存在的 `Start-Job`/`ForEach-Job`**，随后 `finish=length` 截断 | 16.3s |
| `zhipu/glm-4-flash-250414` | 同上，但换成我裁剪过的 param 块 + exit 行 | 🟡 7.2s 出表，但**我的裁剪漏了单行 `if { … exit 3 }`**，且它把 MaxParallel 的默认值看丢了 | 7.2s |

结论：
- **两家都擅长"抄"（抽取、列表、转格式），都不擅长"解释代码"**——后者会滑向先验讲解并编造 API 名。
- 派分析类任务给免费工人 = 拿到看似专业、实则虚构的内容，比不给答案更危险。
- 裁剪要认真：漏一行分支，表就错位；能整份给就整份给（10KB 在能力范围内），裁剪只在模型确实吃不下时才用。

## 一·十一、图片与视频通道（2026-11-14 复核）

| 需求 | 通道 | 花钱 | 现状 |
|---|---|---|---|
| 图片 | 智谱 `cogview-3-flash` | 0 元 | ✅ 8.8s、1024×1024、右下角「AI生成」合规标识；中文提示词跟随好 |
| 图片 | pollinations | 0 元 | ✅ 可出图，但 768×768、强制水印、中文提示词差 |
| 图片 | Ark `seedream-5-5` | 按 token（4096/张） | 账号欠费已恢复，可出图（出图前先问用户） |
| 视频 | 智谱 `cogvideox-flash` | 0 元 | ⚠️ 高峰固定 `429 / 1305`，8 次重试全失败，只能错峰 |
| 视频 | Ark `seedance-2-5` | 按秒×分辨率 | ❌ `ModelNotOpen`：该账号未开通此模型，需在控制台申请开通 |
| 视频 | Agnes AI（`apihub.agnes-ai.com/v1`） | 号称免费无限期 | 未验证：需邮箱注册换 Key，OpenAI 兼容，模型 `agnes-video-v2.0` |

规矩：**出图/出视频前先问用户走哪条**（免费优先），因为出图会消耗额度、出视频贵一到两个数量级。

## 二、免费但要先注册（填好 Key 即生效）

配置段已经写好（`cordis.patch.yml`），只差 Key。**Key 一律存进 `~/.dsh/.credentials.yaml` 的 `refs` 下**（或设置 → 模型），不需要改代码。

| 路由 | 免费额度 | 申请 | 要填的凭据名 | 状态 |
|---|---|---|---|---|
| `modelscope` | 每日 **2000 次**推理，注册即送 | <https://modelscope.cn> → 账号设置 → 访问令牌 | `MODELSCOPE_API_KEY` | 路由已声明；模型 id 已按公开目录核实（38 个），**待 Key 实测** |
| `openrouter` | `:free` 后缀模型全部 0 元，限速较紧 | <https://openrouter.ai> → Keys | `OPENROUTER_API_KEY` | 路由已声明；模型 id 已按公开目录核实（14 个 `:free`），**待 Key 实测** |
| `groq` | 30 次/分、1000 次/日，出字极快 | <https://console.groq.com> | `GROQ_API_KEY` | 配置段被注释，拿到 Key 再放开 |
| `gemini` | 免费档含 `gemini-3.8-flash` 等（不给账单就按免费档走） | <https://aistudio.google.com/apikey> | `GEMINI_API_KEY` | 配置段被注释 |
| `siliconflow` | 9B 以下模型长期 0 元，新用户另有代金券 | <https://siliconflow.cn> | `SILICONFLOW_API_KEY` | 配置段被注释 |

- 已声明并填进白名单的型号：魔搭 `deepseek-ai/DeepSeek-V4.1-Flash`、`Qwen/Qwen3.8-Flash-Next`、`moonshotai/Kimi-K3.1-Pro`；OpenRouter `baidu/ernie-5.5-flash-preview:free`、`nvidia/nemotron-3-ultra-550b-a55b:free`、`google/gemma-4-31b-it:free`。
- 这两家的模型目录**免鉴权可列**（`GET {base}/models`），所以 id 是核实过的；但"有 Key 时能不能真跑"还没验证。

拿到 Key 之后的三步：

1. 填凭据（`~/.dsh/.credentials.yaml` 的 `refs:` 下加一行，或设置 → 模型）。
2. 核实模型 id：`llm.cmd -Provider modelscope -ListModels`，把真实 id 写进 `cordis.patch.yml` 的 `models[].id`，**同时**同步 `allowedModels` 里的同名条目（两处必须一致）。
3. 路由集合变了要重载 DSH（重开应用）；只改 Key 不用重启。

被注释的 provider 放开方法：把 `cordis.patch.yml` 里对应的 `# groq:` 等整段去掉注释，补 `allowedModels`，再重启。

## 三、失败码速查

| 现象 | 含义 | 怎么办 |
|---|---|---|
| `MISSING_CREDENTIAL` / CLI 退出码 3 | 该路由的 Key 名没配 | 填 `~/.dsh/.credentials.yaml` |
| 智谱 `1305 该模型当前访问量过大` | 免费档高峰排队（不是封号、不是欠费） | 等 1–2 分钟重试，或换 `glm-4-flash` |
| 智谱 `1220 您无权访问 xxx` | 那个型号不在这张 Key 的权限里（如 `glm-4.6-flash`） | 换免费 flash 型号 |
| pollinations `402 FREE_LIMIT` | 匿名配额 1 次/45 秒用完了 | 等 45 秒；别做扇出 |
| `finish=length` 且正文为空 | 思考型模型把预算全烧在思考上 | 调大 `-MaxTokens`（≥2048）或换非思考型号 |
| 火山方舟 `AccountOverdueError` | 账号欠费，整条线停服 | 充值，不用改配置 |

## 四、不要接的

- **hunyuan 直连**（`api.hunyuan.cloud.tencent.com`）：2026-11-14 起该 Key 一律 401，改用 `tokenhub/hy3`。
- **Updream（B 站 AI 视频平台，`updream.cn` / `updream.bilibili.com`）**：官方**不对外开放公共 API**（`api.updream.cn` 域名不存在，`/api/v1/models` 404）。它是「把外部 API 接进自己的画布」的方向，不是「对外提供模型」。要利用它，只能反过来：在它的「技能广场 → 外部模型直连器」里填我们的 OpenAI 兼容 Base URL + Key，让它调用智谱免费出图/出视频；或等它开放 API 再谈接入。
- **TokenHub 生图**：返回 `402 / code 401007`，需要开付费，不是免费替代。
