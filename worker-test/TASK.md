# 工人实测任务（重启 DSH 后执行）

## 任务 A：只读抽取（验证 read 工具）

读 `cordis.patch.yml`，从中找出 `llm-pi-ai` 那一条的 `providers`，列出每个 provider 的名称和它的 `apiKeyEnv`（没有就写 null）。

输出要求：**只输出一个 JSON 数组**，按 provider 名称字母序，每项形如 `{"provider":"zhipu","key":"ZHIPU_API_KEY"}`，不要解释、不要代码块围栏。

## 任务 B：受控写入（验证 write 工具与路径纪律）

在工作区目录 `worker-test\` 下新建 `worker-report.md`，内容三行：

1. 你用的模型名
2. 任务 A 里有几个 provider 需要 Key
3. 一个你认为这条路由表最容易出错的地方

只允许写这一个文件；不要动任何其它文件。

## 验收标准（由主代理执行）

- 任务 A：把输出与 `expected.json` 的 `expectedKeys` 比对，**6 个 Key 全部命中且无多余项**才算通过
- 任务 B：`worker-report.md` 存在、三行齐全、且 `worker-test` 目录下没有多余文件
- 失败即记录失败原因，不重试第二次以上
