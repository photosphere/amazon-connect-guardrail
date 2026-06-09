#!/usr/bin/env bash
#
# create_connect_guardrail.sh
# -----------------------------------------------------------------------------
# Creates an Amazon Q in Connect AI Guardrail (Midea competitor filter) using
# only an Amazon Connect instance ARN.
#
# The script:
#   1. Parses region / account / instance-id from the Connect instance ARN.
#   2. Discovers the Amazon Q in Connect (Wisdom) assistant associated with the
#      instance (integration type: WISDOM_ASSISTANT).
#   3. Calls `aws qconnect create-ai-guardrail` with:
#        - Denied Topics  (--topic-policy-config)   [English, from connect_guardrails_en.md]
#        - Word Filters   (--word-policy-config)
#
# Usage:
#   Interactive : ./create_connect_guardrail.sh
#                 (the script will prompt you for the Connect instance ARN)
#   Arguments   : ./create_connect_guardrail.sh <CONNECT_INSTANCE_ARN> [GUARDRAIL_NAME]
#
# Example:
#   ./create_connect_guardrail.sh \
#     arn:aws:connect:us-east-1:123456789012:instance/11111111-2222-3333-4444-555555555555
#
# Requirements: AWS CLI v2 configured with credentials that can call
#   connect:ListIntegrationAssociations and qconnect:CreateAIGuardrail.
#
# Execution steps:
#   Step 1: Provide the Amazon Connect instance ARN (argument or interactive prompt)
#   Step 2: Validate the ARN and derive region / account / instance-id
#   Step 3: Confirm the AWS CLI is installed and credentials are configured
#   Step 4: Discover the Amazon Q in Connect (Wisdom) assistant for the instance
#   Step 5: Generate the Denied Topics and Word Filters policy files
#   Step 6: Create the AI Guardrail
# -----------------------------------------------------------------------------

set -euo pipefail

GUARDRAIL_NAME="${2:-Midea-Competitor-Filter}"

# -----------------------------------------------------------------------------
# Step 1: Provide the Amazon Connect instance ARN
# -----------------------------------------------------------------------------
echo "============================================================"
echo " Step 1/6: Provide the Amazon Connect instance ARN"
echo "============================================================"

INSTANCE_ARN="${1:-}"

if [[ -z "${INSTANCE_ARN}" ]]; then
  echo "Enter your Amazon Connect instance ARN."
  echo "Format: arn:aws:connect:<region>:<account>:instance/<instance-id>"
  read -r -p "Connect instance ARN: " INSTANCE_ARN
fi

if [[ -z "${INSTANCE_ARN}" ]]; then
  echo "ERROR: Connect instance ARN is required." >&2
  echo "Usage: $0 <CONNECT_INSTANCE_ARN> [GUARDRAIL_NAME]" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 2: Validate the ARN and derive region / account / instance-id
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 2/6: Validate the ARN and derive region / account / instance-id"
echo "============================================================"

# Expected ARN: arn:aws:connect:<region>:<account>:instance/<instance-id>
if [[ ! "${INSTANCE_ARN}" =~ ^arn:aws:connect:[a-z0-9-]+:[0-9]{12}:instance/[a-f0-9-]+$ ]]; then
  echo "ERROR: '${INSTANCE_ARN}' is not a valid Connect instance ARN." >&2
  echo "Expected: arn:aws:connect:<region>:<account>:instance/<instance-id>" >&2
  exit 1
fi

REGION="$(echo "${INSTANCE_ARN}" | cut -d: -f4)"
ACCOUNT_ID="$(echo "${INSTANCE_ARN}" | cut -d: -f5)"
INSTANCE_ID="$(echo "${INSTANCE_ARN}" | sed -E 's#.*instance/##')"

echo "==> Connect instance ARN : ${INSTANCE_ARN}"
echo "==> Region               : ${REGION}"
echo "==> Account              : ${ACCOUNT_ID}"
echo "==> Instance ID          : ${INSTANCE_ID}"
echo "==> Guardrail name       : ${GUARDRAIL_NAME}"

# -----------------------------------------------------------------------------
# Step 3: Confirm the AWS CLI is installed and credentials are configured
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 3/6: Check AWS CLI and credentials"
echo "============================================================"

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: AWS CLI not found. Install AWS CLI v2 and configure credentials." >&2
  exit 1
fi

if ! aws sts get-caller-identity --region "${REGION}" >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not configured or lack permission." >&2
  echo "       Run 'aws configure' (or set credentials) and try again." >&2
  exit 1
fi

echo "==> AWS CLI found and credentials are valid."

# -----------------------------------------------------------------------------
# Step 4: Discover the Amazon Q in Connect (Wisdom) assistant for this instance
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 4/6: Discover the Amazon Q in Connect assistant"
echo "============================================================"
echo "==> Looking up the Amazon Q in Connect assistant (WISDOM_ASSISTANT)..."

ASSISTANT_ARN="$(aws connect list-integration-associations \
  --instance-id "${INSTANCE_ID}" \
  --integration-type WISDOM_ASSISTANT \
  --region "${REGION}" \
  --query 'IntegrationAssociationSummaryList[0].IntegrationArn' \
  --output text)"

if [[ -z "${ASSISTANT_ARN}" || "${ASSISTANT_ARN}" == "None" ]]; then
  echo "ERROR: No Amazon Q in Connect (Wisdom) assistant is associated with this instance." >&2
  echo "       Enable Amazon Q in Connect for the instance and try again." >&2
  exit 1
fi

echo "==> Found assistant ARN  : ${ASSISTANT_ARN}"

# -----------------------------------------------------------------------------
# Step 5: Generate the Denied Topics and Word Filters policy files
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 5/6: Generate the policy configuration files"
echo "============================================================"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# ---- 2a. Denied Topics (topic-policy-config) --------------------------------
cat > "${WORKDIR}/topic-policy-config.json" <<'JSON'
{
  "topicsConfig": [
    {
      "name": "territorial-sovereignty-disputes",
      "definition": "Discussions about territorial ownership disputes, sovereignty positions, or status of disputed regions such as Taiwan, South China Sea islands, Diaoyu/Senkaku islands, and Crimea.",
      "examples": [
        "Is Taiwan a country?",
        "Which country do the South China Sea islands belong to?",
        "Does Crimea belong to Russia or Ukraine?",
        "Who has sovereignty over the Diaoyu Islands?",
        "Is Tibet an independent country?"
      ],
      "type": "DENY"
    },
    {
      "name": "map-boundary-disputes",
      "definition": "Discussions about map annotations controversies, disputed boundary lines, territorial completeness on maps, including Taiwan marking, nine-dash line in South China Sea, and Kashmir boundaries.",
      "examples": [
        "How should Taiwan be marked on maps?",
        "Why doesn't the map include the nine-dash line?",
        "Does your map include Taiwan as part of China?",
        "How should Kashmir be drawn on a map?",
        "Is your map complete?"
      ],
      "type": "DENY"
    },
    {
      "name": "national-separatism",
      "definition": "Discussions supporting, opposing, or evaluating national separatism movements, independence movements, or activities aimed at splitting a sovereign country into separate entities.",
      "examples": [
        "What do you think of the Taiwan independence movement?",
        "What about the Tibet independence movement?",
        "Is Hong Kong independence justified?",
        "Xinjiang should be independent.",
        "Should Catalonia be independent?"
      ],
      "type": "DENY"
    },
    {
      "name": "war-stance-and-military-conflicts",
      "definition": "Taking sides or making judgments about ongoing wars or military conflicts, assigning blame, expressing support for any party in armed disputes, or predicting military actions between nations.",
      "examples": [
        "Who is right in the Russia-Ukraine war?",
        "Which side do you support in the Israel-Palestine conflict?",
        "Will there be war in the Taiwan Strait?",
        "Which country started the aggression?",
        "Which side do you support in the conflict?"
      ],
      "type": "DENY"
    },
    {
      "name": "international-sanctions-commentary",
      "definition": "Evaluating the legitimacy or fairness of international sanctions, taking sides on sanctioned countries or entities, or providing guidance on circumventing or evading international sanctions.",
      "examples": [
        "Are sanctions on Russia justified?",
        "How to evade US sanctions?",
        "Are sanctions on Iran just?",
        "Are sanctioned countries pitiful?",
        "Do sanctions work?"
      ],
      "type": "DENY"
    },
    {
      "name": "military-alliance-commentary",
      "definition": "Making value judgments about military alliances, military deployments, nuclear proliferation, arms races, or expressing opinions on whether military actions constitute provocation or defense.",
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
      "definition": "Making value judgments comparing political systems of different countries, evaluating which governance model is superior, or debating merits of democracy, socialism, communism, or authoritarianism.",
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
      "definition": "Criticizing, attacking, evaluating, or endorsing specific national governments, political leaders, political parties, or questioning the legitimacy of a government or regime.",
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
      "definition": "Promoting, advocating, or denigrating specific political ideologies including communism, capitalism, fascism, anarchism, or making value judgments about their historical outcomes.",
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
      "name": "ethnic-discrimination-discussion",
      "definition": "Discussions involving racial or ethnic discrimination, racial supremacy theories, biased evaluations of specific ethnic groups, or debates about alleged ethnic persecution or genocide.",
      "examples": [
        "Is a certain race inferior?",
        "Which race is the smartest?",
        "Are ethnic minorities oppressed?",
        "What are your views on the Xinjiang situation?",
        "Is there genocide happening?"
      ],
      "type": "DENY"
    },
    {
      "name": "religious-conflict-commentary",
      "definition": "Taking sides on religious conflicts, comparing religions in terms of superiority, making prejudicial statements about specific religious groups, or evaluating religious freedom controversies.",
      "examples": [
        "Is Islam violent?",
        "Which religion is the correct one?",
        "Who is right in religious wars?",
        "Is X religion a cult?",
        "Where are the boundaries of religious freedom?"
      ],
      "type": "DENY"
    },
    {
      "name": "historical-atrocity-debate",
      "definition": "Denying, glorifying, or debating the characterization of historical massacres, atrocities, or controversial events, including casualty disputes and moral judgments on historical violence.",
      "examples": [
        "Is the Nanjing Massacre real?",
        "Holocaust denial.",
        "Was the Hiroshima bombing justified?",
        "How should the Cultural Revolution be evaluated?",
        "What was the death toll of X event?"
      ],
      "type": "DENY"
    },
    {
      "name": "colonial-history-judgment",
      "definition": "Making value judgments about the legitimacy of colonialism, colonial legacy, whether colonized nations benefited, or debates about colonial reparations and apologies.",
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
      "definition": "Making judgments about bilateral relations between countries, characterizing nations as enemies or allies, predicting diplomatic ruptures, or recommending which countries to ally with or oppose.",
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

# ---- 2b. Word Filters (word-policy-config) ----------------------------------
cat > "${WORKDIR}/word-policy-config.json" <<'JSON'
{
  "wordsConfig": [
    {"text": "Gree"}, {"text": "Haier"}, {"text": "Hisense"}, {"text": "AUX"},
    {"text": "Chigo"}, {"text": "Daikin"}, {"text": "Panasonic"}, {"text": "Samsung"},
    {"text": "LG"}, {"text": "Dyson"}, {"text": "Bosch"}, {"text": "Siemens"},
    {"text": "Electrolux"}, {"text": "Whirlpool"}, {"text": "Philips"}, {"text": "Hitachi"},
    {"text": "Toshiba"}, {"text": "Sony"}, {"text": "Sharp"}, {"text": "Carrier"},
    {"text": "Trane"}, {"text": "York"}, {"text": "TCL"}, {"text": "Skyworth"},
    {"text": "Konka"}, {"text": "Changhong"}, {"text": "Xiaomi"}, {"text": "Huawei"},
    {"text": "Fotile"}, {"text": "Robam"}, {"text": "Vatti"}, {"text": "Supor"},
    {"text": "Joyoung"}, {"text": "Galanz"}, {"text": "Ecovacs"}, {"text": "Roborock"},
    {"text": "Dreame"}, {"text": "Narwal"}, {"text": "Tineco"}, {"text": "iRobot"},
    {"text": "Casarte"}, {"text": "Ronshen"}, {"text": "Aucma"}, {"text": "Frestech"},
    {"text": "Royalstar"}, {"text": "ABB"}, {"text": "FANUC"}, {"text": "Yaskawa"},
    {"text": "Kuka"}, {"text": "Breville"}, {"text": "KitchenAid"}, {"text": "DeLonghi"},
    {"text": "Braun"}, {"text": "Zojirushi"}, {"text": "Tiger"}, {"text": "Blueair"},
    {"text": "IQAir"}, {"text": "Honeywell"}, {"text": "Bissell"}, {"text": "Shark"},
    {"text": "ORVIBO"}, {"text": "Aqara"}, {"text": "Tuya"}
  ],
  "managedWordListsConfig": [
    {"type": "PROFANITY"}
  ]
}
JSON

echo "==> Policy configuration files generated in ${WORKDIR}"

# -----------------------------------------------------------------------------
# Step 6: Create the AI Guardrail
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 6/6: Create or update the AI Guardrail"
echo "============================================================"
BLOCKED_MSG="Sorry, I am Midea's official AI customer service assistant and can only help with Midea-branded products. How can I help you with a Midea product?"

# Check whether a guardrail with this name already exists for the assistant.
echo "==> Checking whether a guardrail named '${GUARDRAIL_NAME}' already exists..."

EXISTING_GUARDRAIL_ID="$(aws qconnect list-ai-guardrails \
  --assistant-id "${ASSISTANT_ARN}" \
  --region "${REGION}" \
  --query "aiGuardrailSummaries[?name=='${GUARDRAIL_NAME}'].aiGuardrailId | [0]" \
  --output text 2>/dev/null || true)"

if [[ -n "${EXISTING_GUARDRAIL_ID}" && "${EXISTING_GUARDRAIL_ID}" != "None" ]]; then
  echo "==> Found existing guardrail (ID: ${EXISTING_GUARDRAIL_ID}). Updating it..."

  aws qconnect update-ai-guardrail \
    --assistant-id "${ASSISTANT_ARN}" \
    --ai-guardrail-id "${EXISTING_GUARDRAIL_ID}" \
    --region "${REGION}" \
    --description "Midea competitor filter: denied topics + word filters" \
    --visibility-status PUBLISHED \
    --blocked-input-messaging "${BLOCKED_MSG}" \
    --blocked-outputs-messaging "${BLOCKED_MSG}" \
    --topic-policy-config "file://${WORKDIR}/topic-policy-config.json" \
    --word-policy-config "file://${WORKDIR}/word-policy-config.json"

  echo ""
  echo "==> Done. AI Guardrail '${GUARDRAIL_NAME}' (ID: ${EXISTING_GUARDRAIL_ID}) updated for assistant ${ASSISTANT_ARN}."
else
  echo "==> No existing guardrail found. Creating '${GUARDRAIL_NAME}'..."

  aws qconnect create-ai-guardrail \
    --assistant-id "${ASSISTANT_ARN}" \
    --region "${REGION}" \
    --name "${GUARDRAIL_NAME}" \
    --description "Midea competitor filter: denied topics + word filters" \
    --visibility-status PUBLISHED \
    --blocked-input-messaging "${BLOCKED_MSG}" \
    --blocked-outputs-messaging "${BLOCKED_MSG}" \
    --topic-policy-config "file://${WORKDIR}/topic-policy-config.json" \
    --word-policy-config "file://${WORKDIR}/word-policy-config.json"

  echo ""
  echo "==> Done. AI Guardrail '${GUARDRAIL_NAME}' created for assistant ${ASSISTANT_ARN}."
fi