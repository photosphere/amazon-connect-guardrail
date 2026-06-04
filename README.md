# Amazon Q in Connect AI Guardrail 脚本说明

本目录包含两个用于管理 Amazon Q in Connect（Wisdom）AI Guardrail 的 Shell 脚本，用于创建“美的竞品过滤”护栏以及清空护栏中的自定义敏感词。

| 脚本 | 作用 |
| --- | --- |
| `create_connect_guardrail.sh` | 创建一个 AI Guardrail（拒绝主题 Denied Topics + 敏感词过滤 Word Filters） |
| `delete_word_filters.sh` | 清空指定 AI Guardrail 中所有自定义敏感词，同时保留其他策略 |

两个脚本都只需要传入 **Amazon Connect 实例 ARN**，脚本会自动解析出 region / account / instance-id，并发现该实例关联的 Amazon Q in Connect 助手（assistant）。

---

## 前置条件

- **AWS CLI v2**：已安装并完成凭证配置（`aws configure`），凭证需具备相应权限。
- **jq**：仅 `delete_word_filters.sh` 需要（用于解析 JSON 配置）。macOS 安装：`brew install jq`。
- **Amazon Q in Connect 已启用**：目标 Connect 实例必须已关联 Wisdom 助手（集成类型 `WISDOM_ASSISTANT`）。

### 所需 IAM 权限

`create_connect_guardrail.sh`：

- `connect:ListIntegrationAssociations`
- `qconnect:CreateAIGuardrail`

`delete_word_filters.sh`：

- `connect:ListIntegrationAssociations`
- `qconnect:ListAIGuardrails`
- `qconnect:GetAIGuardrail`
- `qconnect:UpdateAIGuardrail`

### 赋予执行权限

```bash
chmod +x create_connect_guardrail.sh delete_word_filters.sh
```

---

## 1. create_connect_guardrail.sh — 创建 AI Guardrail

仅根据 Connect 实例 ARN 创建一个“美的竞品过滤”护栏，包含两类策略：

- **拒绝主题（Denied Topics）**：6 个主题，覆盖竞品产品咨询、品牌对比、推荐、技术参数、售后、价格等（主题定义来源于 `connect_guardrails_en.md`，为英文）。
- **敏感词过滤（Word Filters）**：内置一批竞品品牌名（如 Gree、Haier、Dyson、Xiaomi 等）。

命中护栏时，输入/输出都会被替换为统一的拦截话术：

> Sorry, I am Midea's official AI customer service assistant and can only help with Midea-branded products. How can I help you with a Midea product?

### 用法

```bash
# 交互式：脚本会提示你输入 Connect 实例 ARN
./create_connect_guardrail.sh

# 传参方式
./create_connect_guardrail.sh <CONNECT_INSTANCE_ARN> [GUARDRAIL_NAME]
```

### 参数说明

| 位置 | 参数 | 是否必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `$1` | `CONNECT_INSTANCE_ARN` | 是 | 无（缺省时交互式提示输入） | Amazon Connect 实例 ARN，格式：`arn:aws:connect:<region>:<account>:instance/<instance-id>` |
| `$2` | `GUARDRAIL_NAME` | 否 | `Midea-Competitor-Filter` | 要创建的 AI Guardrail 名称 |

### 示例

```bash
./create_connect_guardrail.sh \
  arn:aws:connect:us-east-1:123456789012:instance/11111111-2222-3333-4444-555555555555 \
  Midea-Competitor-Filter
```

### 执行步骤

1. 提供 Connect 实例 ARN（参数或交互式输入）
2. 校验 ARN 并解析出 region / account / instance-id
3. 检查 AWS CLI 是否安装、凭证是否有效
4. 发现该实例关联的 Amazon Q in Connect 助手
5. 生成拒绝主题与敏感词的策略 JSON 文件（临时目录，结束后自动清理）
6. 调用 `aws qconnect create-ai-guardrail` 创建护栏（`visibility-status` 为 `PUBLISHED`）

---

## 2. delete_word_filters.sh — 清空敏感词过滤

清空指定 AI Guardrail 中**所有自定义敏感词**，并保留其余策略（拒绝主题、内容过滤、敏感信息、上下文接地等）。

> 原理：`update-ai-guardrail` 是**整体替换**而非局部更新，且 `wordsConfig` 列表最小长度为 1（不能传空列表）。因此脚本读取当前护栏配置后，重新应用除自定义敏感词外的所有策略，从而达到清空效果。如果存在托管词表（如 `PROFANITY`），会被保留。

### 用法

```bash
# 交互式：提示输入实例 ARN，并从列表中选择目标护栏
./delete_word_filters.sh

# 传参方式
./delete_word_filters.sh <CONNECT_INSTANCE_ARN> [AI_GUARDRAIL_ID]
```

### 参数说明

| 位置 | 参数 | 是否必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `$1` | `CONNECT_INSTANCE_ARN` | 是 | 无（缺省时交互式提示输入） | Amazon Connect 实例 ARN，格式同上 |
| `$2` | `AI_GUARDRAIL_ID` | 否 | 无（缺省时列出全部护栏供选择） | 要清空敏感词的 AI Guardrail ID |

### 示例

```bash
# 指定护栏 ID
./delete_word_filters.sh \
  arn:aws:connect:us-east-1:123456789012:instance/11111111-2222-3333-4444-555555555555 \
  abcdef12-3456-7890-abcd-ef1234567890

# 不指定 ID，交互式从表格中挑选
./delete_word_filters.sh \
  arn:aws:connect:us-east-1:123456789012:instance/11111111-2222-3333-4444-555555555555
```

### 执行步骤

1. 提供 Connect 实例 ARN（参数或交互式输入）
2. 校验 ARN 并解析出 region / account / instance-id
3. 检查 AWS CLI、凭证以及 jq 依赖
4. 发现该实例关联的 Amazon Q in Connect 助手
5. 选择目标 AI Guardrail（传参或从列表中交互式选择）
6. 拉取当前护栏配置；若自定义敏感词数量为 0，则直接退出
7. 二次确认后，重新应用除自定义敏感词外的所有策略（即清空敏感词）

> 注意：第 7 步会提示 `Proceed? (yes/no)`，必须输入 `yes` 才会执行覆盖更新；输入其他内容则中止且不做任何修改。

---

## 常见问题

- **报错 “is not a valid Connect instance ARN”**：检查 ARN 格式是否为 `arn:aws:connect:<region>:<account>:instance/<instance-id>`。
- **报错 “No Amazon Q in Connect (Wisdom) assistant is associated”**：该 Connect 实例尚未启用 Amazon Q in Connect，请先在控制台启用后重试。
- **报错 “AWS credentials are not configured or lack permission”**：运行 `aws configure` 配置凭证，或确认当前凭证具备上文列出的 IAM 权限。
- **报错 “jq not found”**：仅 `delete_word_filters.sh` 需要，执行 `brew install jq` 安装。
