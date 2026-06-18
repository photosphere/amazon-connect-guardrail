#!/usr/bin/env bash
#
# create_bedrock_guardrail_v2.sh
# ------------------------------------------------------------------------------
# 在 Bedrock 中创建/更新生产就绪的 Guardrail（CLASSIC tier），并导入 denied topics。
# 由 create_and_test_bedrock_guardrail_classic_good.py 转换而来（仅保留创建逻辑，
# 去掉了测试部分）。
#
# 该配置经过人工调优并验证，满足 Midea denied-topics 需求，用于 Amazon Connect
# （CLASSIC 层级，Amazon Connect AI Guardrail 仅支持 CLASSIC）。
#
# 相比原始 denied topics，做了以下调整以抑制真实世界的误报
# （例如 "lam"、"xietian" 这类很短的拼音/姓名输入被错误拦截）:
#   1. 移除整个 `ethnic-discrimination-discussion` 主题。
#   2. `territorial-sovereignty-disputes` 定义不再提及 Taiwan / Tibet，删除相应示例。
#   3. `national-separatism` 定义不再提及 Taiwan, Tibet, Xinjiang，删除相应三个示例。
#   4. `religious-conflict-commentary` 删除两个会误报的示例
#      （"Is Islam violent?" / "Is X religion a cult?"）。
#   其余 10 个主题与 V2 基线保持一致。
#
# 行为:
#   - 默认按名字查找是否已存在同名 guardrail:
#       * 存在  -> 自动走 update-guardrail（幂等，不会冲突）
#       * 不存在 -> create-guardrail
#   - 显式指定 GUARDRAIL_ID=xxx  -> 直接 update 该 id
#   - RECREATE=1                 -> 先删除同名 guardrail，等名字释放后再 create
#
# 用法:
#   ./create_bedrock_guardrail_v2.sh                    # 没有就建，有就更新（推荐）
#   GUARDRAIL_ID=xxx ./create_bedrock_guardrail_v2.sh   # 更新指定 id
#   RECREATE=1 ./create_bedrock_guardrail_v2.sh         # 删除重建
#
set -euo pipefail

# 解析 region，按以下优先级（同时兼容本地和 AWS CloudShell）:
#   1. 显式传入的 REGION 环境变量
#   2. AWS_REGION / AWS_DEFAULT_REGION（CloudShell 会自动设置为控制台当前 region）
#   3. aws configure get region（本地 aws configure 配置）
REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}}"
if [[ -z "${REGION}" ]]; then
  echo "ERROR: 未检测到 AWS region。请设置 AWS_REGION，或运行 'aws configure' 设置 region，或显式指定 REGION=xxx。" >&2
  exit 1
fi
NAME="${NAME:-Midea-Connect-Denied-Topics-Classic-Good}"
DESCRIPTION="Midea Connect denied-topics guardrail (CLASSIC tier, hand-tuned for low FP)."

BLOCKED_INPUT="Sorry, I am Midea's official AI customer service assistant and can only help with Midea-branded products. How can I help you with a Midea product?"
BLOCKED_OUTPUT="${BLOCKED_INPUT}"

# 拒绝主题配置（内联）。CLASSIC tier 通过 tierConfig 指定。
read -r -d '' TOPIC_POLICY_CONFIG <<'JSON' || true
{
  "topicsConfig": [
    {
      "name": "territorial-sovereignty-disputes",
      "definition": "Asking the assistant to declare or judge which country owns a disputed region (HK, S.China Sea, Crimea, Kashmir). Not customer questions about shipping, warranty, or purchase location.",
      "examples": [
        "Which country do the South China Sea islands belong to?",
        "Does Crimea belong to Russia or Ukraine?",
        "Who has sovereignty over the Diaoyu Islands?"
      ],
      "type": "DENY"
    },
    {
      "name": "map-boundary-disputes",
      "definition": "Asking how disputed borders should be drawn or labeled on a map (Taiwan, nine-dash line, Kashmir, Crimea). Not product manuals or service-coverage maps.",
      "examples": [
        "How should Taiwan be marked on maps?",
        "Why doesn't the map include the nine-dash line?",
        "Does your map include Taiwan as part of China?",
        "How should Kashmir be drawn on a map?"
      ],
      "type": "DENY"
    },
    {
      "name": "national-separatism",
      "definition": "Asking the assistant to support, oppose, or judge separatist/independence movements (HK, Catalonia). Not product/shipping mentions of these regions.",
      "examples": [
        "Is Hong Kong independence justified?",
        "Should Catalonia be independent?"
      ],
      "type": "DENY"
    },
    {
      "name": "war-stance-and-military-conflicts",
      "definition": "Asking the assistant to take sides, assign blame, predict, or morally judge wars or military conflicts (Russia-Ukraine, Israel-Palestine, Taiwan Strait). Not product questions about those regions.",
      "examples": [
        "Who is right in the Russia-Ukraine war?",
        "Which side do you support in the Israel-Palestine conflict?",
        "Will there be war in the Taiwan Strait?",
        "Which country started the aggression?"
      ],
      "type": "DENY"
    },
    {
      "name": "international-sanctions-commentary",
      "definition": "Asking the assistant to judge the legitimacy of international sanctions, take sides, or advise on evading sanctions. Not logistics or shipping/service availability questions.",
      "examples": [
        "Are sanctions on Russia justified?",
        "How to evade US sanctions?",
        "Are sanctions on Iran just?",
        "Do sanctions work?"
      ],
      "type": "DENY"
    },
    {
      "name": "military-alliance-commentary",
      "definition": "Asking the assistant to value-judge military alliances, deployments, nuclear weapons, arms races, or whether military actions are provocative or defensive (NATO, AUKUS, US bases).",
      "examples": [
        "Is NATO expansion justified?",
        "Should China increase its nuclear weapons?",
        "Is the US military presence in South Korea reasonable?",
        "Who is AUKUS targeting?",
        "Are military drills provocative?"
      ],
      "type": "DENY"
    },
    {
      "name": "political-system-comparison",
      "definition": "Asking the assistant to rank or judge the superiority of political systems (democracy vs one-party rule, socialism vs capitalism, authoritarianism).",
      "examples": [
        "Is democracy the best system?",
        "Is a one-party system better or a multi-party system?",
        "Which is better, China's system or the US system?",
        "Is socialism better or capitalism?",
        "Why does China not have democracy?"
      ],
      "type": "DENY"
    },
    {
      "name": "government-criticism",
      "definition": "Asking the assistant to criticize, attack, or endorse a national government, political leader, or party, or to question regime legitimacy. Not Midea's own company policies or service procedures.",
      "examples": [
        "Is leader X a dictator?",
        "Is the government doing a good job?",
        "Is this regime legitimate?",
        "Which president is the worst?",
        "What is the government hiding?"
      ],
      "type": "DENY"
    },
    {
      "name": "political-ideology-advocacy",
      "definition": "Asking the assistant to promote, denounce, or value-judge political ideologies (communism, capitalism, fascism, anarchism, Marxism) or their historical track record.",
      "examples": [
        "Has communism failed?",
        "Is capitalism evil?",
        "Does fascism have merits?",
        "Is anarchism viable?",
        "Is Marxism outdated?"
      ],
      "type": "DENY"
    },
    {
      "name": "religious-conflict-commentary",
      "definition": "Asking the assistant to take sides on religious conflicts, rank religions, make prejudicial statements about a religious group, or judge religious-freedom issues.",
      "examples": [
        "Which religion is the correct one?",
        "Who is right in religious wars?",
        "Where are the boundaries of religious freedom?"
      ],
      "type": "DENY"
    },
    {
      "name": "historical-atrocity-debate",
      "definition": "Asking the assistant to deny, glorify, or debate the framing or casualty count of historical massacres/atrocities (Nanjing, Holocaust, Hiroshima, Cultural Revolution).",
      "examples": [
        "Is the Nanjing Massacre real?",
        "Holocaust denial.",
        "Was the Hiroshima bombing justified?",
        "How should the Cultural Revolution be evaluated?"
      ],
      "type": "DENY"
    },
    {
      "name": "colonial-history-judgment",
      "definition": "Asking the assistant to judge whether colonialism was beneficial/justified, who should apologize, or whether colonized peoples deserved their fate or independence.",
      "examples": [
        "Did colonialism bring progress?",
        "Which country should apologize for colonialism?",
        "Was the independence of colonies justified?",
        "Did imperialism contribute?",
        "Did colonized peoples deserve it?"
      ],
      "type": "DENY"
    },
    {
      "name": "bilateral-relations-commentary",
      "definition": "Asking the assistant to characterize country relations as friendly/hostile, label nations as enemies/allies, predict diplomatic ruptures, or pick alliances. Not shipping/service questions.",
      "examples": [
        "Will China-US relations worsen?",
        "Which country is the enemy?",
        "Is Japan a bad country?",
        "Which country should we ally with?",
        "Will the two countries sever diplomatic ties?"
      ],
      "type": "DENY"
    }
  ]
}
JSON

# 按名字查找已存在的 guardrail id（找不到返回空）。
find_guardrail_id() {
  aws bedrock list-guardrails \
    --region "${REGION}" \
    --query "guardrails[?name=='${NAME}'] | [0].id" \
    --output text 2>/dev/null | sed 's/^None$//'
}

do_create() {
  echo "Creating new guardrail ${NAME} in ${REGION} ..."
  aws bedrock create-guardrail \
    --region "${REGION}" \
    --name "${NAME}" \
    --description "${DESCRIPTION}" \
    --topic-policy-config "${TOPIC_POLICY_CONFIG}" \
    --blocked-input-messaging "${BLOCKED_INPUT}" \
    --blocked-outputs-messaging "${BLOCKED_OUTPUT}"
}

do_update() {
  local gid="$1"
  echo "Updating existing guardrail ${gid} ..."
  aws bedrock update-guardrail \
    --region "${REGION}" \
    --guardrail-identifier "${gid}" \
    --name "${NAME}" \
    --description "${DESCRIPTION}" \
    --topic-policy-config "${TOPIC_POLICY_CONFIG}" \
    --blocked-input-messaging "${BLOCKED_INPUT}" \
    --blocked-outputs-messaging "${BLOCKED_OUTPUT}"
}

# 等待同名 guardrail 从列表中消失（删除是异步的，名字释放有延迟）。
wait_until_gone() {
  local tries=30
  while [[ $tries -gt 0 ]]; do
    if [[ -z "$(find_guardrail_id)" ]]; then
      return 0
    fi
    echo "  waiting for guardrail name to be released ..."
    sleep 3
    tries=$((tries - 1))
  done
  echo "WARN: guardrail name still in use after waiting; create may fail." >&2
}

# 显式指定 id：直接更新。
if [[ -n "${GUARDRAIL_ID:-}" ]]; then
  do_update "${GUARDRAIL_ID}"
  exit $?
fi

EXISTING_ID="$(find_guardrail_id)"

# 删除重建模式。
if [[ "${RECREATE:-0}" == "1" ]]; then
  if [[ -n "${EXISTING_ID}" ]]; then
    echo "Deleting existing guardrail ${EXISTING_ID} ..."
    aws bedrock delete-guardrail --region "${REGION}" --guardrail-identifier "${EXISTING_ID}"
    wait_until_gone
  fi
  do_create
  exit $?
fi

# 默认：有则更新，无则创建。
if [[ -n "${EXISTING_ID}" ]]; then
  echo "Found existing guardrail named '${NAME}' (id ${EXISTING_ID}); updating instead of creating."
  do_update "${EXISTING_ID}"
else
  do_create
fi

# 创建/更新后，发布一个版本以便在运行时引用:
#   aws bedrock create-guardrail-version --region "${REGION}" \
#     --guardrail-identifier <GUARDRAIL_ID> --description "v1 GA"
# 然后把 Amazon Connect AI Guardrail 集成指向该版本。
