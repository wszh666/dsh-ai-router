# dsh-ai-router

多模型分诊调度，为 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 提供统一的
OpenAI 兼容多路 provider 路由、文件系统 Skill 加载，以及一整套命令行工具（`ask` / `llm` / `fanout` /
`media` / `smoke` / `check-patch`）。

**一句话**：同一个 prompt，可以便宜地跑本地 Ollama、免费地跑免 Key 通道、或者扇出到 4 个模型交叉验证。

## 它解决什么问题

单一模型选型总有取舍：本地模型免费但弱，云端强但要钱。这个插件把「该谁干这件事」做成可配置的路由表：

| 场景 | 走哪条路 |
|---|---|
| 短问答、隐私内容 | 本地 Ollama（不出网） |
| 批量清洗、格式转换 | 免费档（智谱 `/api/paas/v4`、Pollinations 完全免 Key） |
| 需要质量的判断 | 付费档（DeepSeek / 豆包 Ark / 腾讯 TokenHub） |
| 需要交叉验证 | `fanout` 扇出到多个 provider，比对结果 |

## 5 分钟上手

### 1. 装

把本仓库放进 DSH 的 profile 插件目录，在 `cordis.patch.yml` 里启用（本仓库自带一份可直接参考的
`cordis.patch.yml`，含完整路由定义）。

### 2. 配 Key（只配你要用的）

所有 Key **一律走环境变量**，仓库里没有任何硬编码凭据：

```powershell
# 免费档，可不配
# zhipu / pollinations 部分模型免 Key

# 付费档按需
$env:DEEPSEEK_API_KEY    = 'sk-...'
$env:ARK_API_KEY         = '...'
$env:TOKENHUB_API_KEY    = '...'
$env:ZHIPU_API_KEY       = '...'
$env:MODELSCOPE_API_KEY  = '...'
$env:OPENROUTER_API_KEY  = '...'
$env:GROQ_API_KEY        = '...'
$env:SILICONFLOW_API_KEY = '...'
```

凭据读取顺序：环境变量 → `~/.dsh/.credentials.yaml`，任何目录、任何会话可用。

### 3. 验

```powershell
.\bin\check-patch.cmd      # 校验 cordis.patch.yml 语法 + 路由/白名单一致性
.\bin\smoke.cmd -Quick     # 只测免费/免 Key 通道；缺 Key 的显示 NOKEY 不报错
```

两条都过，说明路由注册正常。

### 4. 用

```powershell
# 单次问答
.\bin\ask.cmd -Prompt "Explain TCP slow start in one sentence" -MaxTokens 256

# 指定 provider
.\bin\llm.cmd -Provider zhipu -Model glm-4-flash -Prompt "你好"

# 列出某厂商目录里的全部模型 id
.\bin\llm.cmd -Provider zhipu -ListModels

# 扇出：同一任务并行 4 路，结果落盘比对
.\bin\fanout.cmd -TasksFile tasks.txt -OutDir out -MaxParallel 4
```

## 目录

```
bin/          命令行工具（.cmd 是入口，.ps1 是实现）
docs/
  DETAIL.md       架构与实现细节：路由表、preflight 解析、失败降级
  FREE-MODELS.md  免费/免 Key 通道清单与实测结果
  VERIFY.md       验收步骤与逐 provider 验证记录
worker-test/  子智能体任务的测试夹具（expected.json 为断言基准）
index.js      诊断探针：把每条路由的解析结果写成 JSON，供任意会话读取
```

## 设计要点

- **不猜 Key 是否有效**：`smoke` 区分「路由已注册」与「Key 能用」两件事，后者只有真打一次才知道。
- **降级不静默**：某 provider 失败会在输出里标注原因（`NOKEY` / `finish=length` / 空内容），不会被吞掉。
- **诊断不阻断**：`index.js` 的探针写报告失败也绝不让插件挂掉。
- **报告路径可配**：默认写到插件目录下的 `diagnostics/report.json`，可用 `AI_ROUTER_REPORT` 环境变量改。

## License

MIT
