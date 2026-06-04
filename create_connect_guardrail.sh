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
      "name": "competitor-product-inquiry",
      "definition": "The user asks about or seeks information on non-Midea brand home appliances, including product features, specifications, pricing, purchase channels, usage, or repair/maintenance.",
      "examples": [
        "How is the cooling performance of a Gree air conditioner?",
        "Which Haier refrigerator model is the best?",
        "Is a Dyson vacuum cleaner worth buying?",
        "Is a Panasonic dishwasher any good?",
        "How much is the latest Fotile range hood?"
      ],
      "type": "DENY"
    },
    {
      "name": "competitor-brand-comparison",
      "definition": "The user compares Midea products with products of other brands, including reviews, evaluations of pros and cons, value for money, and quality differences.",
      "examples": [
        "Which is better, a Midea or a Gree air conditioner?",
        "Is a Haier refrigerator more durable than a Midea one?",
        "Xiaomi robot vacuum versus Midea, which is better?",
        "How does a Supor rice cooker compare to a Midea one?",
        "Is there a big gap between a Siemens dishwasher and a Midea one?"
      ],
      "type": "DENY"
    },
    {
      "name": "competitor-recommendation",
      "definition": "The user asks for recommendations of non-Midea brand home appliances, or asks about recommendations, rankings, or reviews of other brands on the market.",
      "examples": [
        "Recommend a few good air conditioner brands.",
        "Besides Midea, what are some good washing machines?",
        "Which domestic kitchen appliance brand is the best?",
        "What are the top ten water purifier brands?",
        "Is there anything with better value for money than Midea?"
      ],
      "type": "DENY"
    },
    {
      "name": "competitor-technical-details",
      "definition": "The user asks about competitor brand products' technical specifications, patented technology, energy efficiency ratings, core technology, or manufacturing processes.",
      "examples": [
        "What is the working principle of Gree's inverter compressor?",
        "What freshness-preservation technologies do Haier refrigerators have?",
        "What is the rotation speed of the Dyson digital motor?",
        "What navigation technology does an Ecovacs robot vacuum use?",
        "What is the suction power spec of a Robam range hood?"
      ],
      "type": "DENY"
    },
    {
      "name": "competitor-sales",
      "definition": "The user asks about a competitor brand's after-sales policy, warranty period, repair service, return/exchange policy, or customer service contact information.",
      "examples": [
        "How many years of warranty does a Gree air conditioner have?",
        "What is Haier's after-sales phone number?",
        "Where do I go to repair a Dyson?",
        "How do I find after-sales service to replace a Xiaomi water purifier filter?",
        "Is repair free during the warranty period for a Fotile gas stove?"
      ],
      "type": "DENY"
    },
    {
      "name": "competitor-pricing",
      "definition": "The user asks about a competitor brand product's price, promotions, discount information, or recommended purchase channels.",
      "examples": [
        "What is the current price of a Gree air conditioner?",
        "What is the Double 11 discount on a Haier washing machine?",
        "Where can I buy a Dyson hair dryer the cheapest?",
        "What is the official flagship store price of a Supor blender?",
        "What promotions does TCL have on TVs this year?"
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
echo " Step 6/6: Create the AI Guardrail"
echo "============================================================"
BLOCKED_MSG="Sorry, I am Midea's official AI customer service assistant and can only help with Midea-branded products. How can I help you with a Midea product?"

echo "==> Creating AI Guardrail '${GUARDRAIL_NAME}'..."

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