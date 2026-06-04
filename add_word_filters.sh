#!/usr/bin/env bash
#
# add_word_filters.sh
# -----------------------------------------------------------------------------
# Adds a fixed list of competitor brand words to the Word Filters of an Amazon Q
# in Connect AI Guardrail, using only an Amazon Connect instance ARN.
#
# How it works:
#   `update-ai-guardrail` is a FULL replacement (not a partial patch). To ADD
#   words without losing the existing ones, the script reads the current
#   guardrail configuration, MERGES the existing custom words with the new word
#   list (de-duplicated, case-insensitive), and re-applies every policy that
#   already exists on the guardrail together with the merged word policy.
#
# The script:
#   1. Provide the Amazon Connect instance ARN (argument or interactive prompt)
#   2. Validate the ARN and derive region / account / instance-id
#   3. Check the AWS CLI, credentials, and jq dependency
#   4. Discover the Amazon Q in Connect (Wisdom) assistant for the instance
#   5. Select the target AI Guardrail (argument or interactive pick from a list)
#   6. Fetch the current guardrail configuration
#   7. Re-apply all policies, merging the new words into the Word Filters
#
# Usage:
#   Interactive : ./add_word_filters.sh
#   Arguments   : ./add_word_filters.sh <CONNECT_INSTANCE_ARN> [AI_GUARDRAIL_ID]
#
# Requirements: AWS CLI v2 and jq, with credentials that can call
#   connect:ListIntegrationAssociations, qconnect:ListAIGuardrails,
#   qconnect:GetAIGuardrail and qconnect:UpdateAIGuardrail.
# -----------------------------------------------------------------------------

set -euo pipefail

# The list of words to add to the Word Filters.
WORDS_TO_ADD=(
  "Gree" "TCL"
)

# -----------------------------------------------------------------------------
# Step 1: Provide the Amazon Connect instance ARN
# -----------------------------------------------------------------------------
echo "============================================================"
echo " Step 1/7: Provide the Amazon Connect instance ARN"
echo "============================================================"

INSTANCE_ARN="${1:-}"
GUARDRAIL_ID="${2:-}"

if [[ -z "${INSTANCE_ARN}" ]]; then
  echo "Enter your Amazon Connect instance ARN."
  echo "Format: arn:aws:connect:<region>:<account>:instance/<instance-id>"
  read -r -p "Connect instance ARN: " INSTANCE_ARN
fi

if [[ -z "${INSTANCE_ARN}" ]]; then
  echo "ERROR: Connect instance ARN is required." >&2
  echo "Usage: $0 <CONNECT_INSTANCE_ARN> [AI_GUARDRAIL_ID]" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 2: Validate the ARN and derive region / account / instance-id
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 2/7: Validate the ARN and derive region / account / instance-id"
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

# -----------------------------------------------------------------------------
# Step 3: Check AWS CLI, credentials, and jq
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 3/7: Check AWS CLI, credentials, and jq"
echo "============================================================"

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: AWS CLI not found. Install AWS CLI v2 and configure credentials." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found. Install jq (e.g. 'brew install jq') and try again." >&2
  exit 1
fi

if ! aws sts get-caller-identity --region "${REGION}" >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not configured or lack permission." >&2
  echo "       Run 'aws configure' (or set credentials) and try again." >&2
  exit 1
fi

echo "==> AWS CLI, jq, and credentials are all available."

# -----------------------------------------------------------------------------
# Step 4: Discover the Amazon Q in Connect (Wisdom) assistant for this instance
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 4/7: Discover the Amazon Q in Connect assistant"
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
# Step 5: Select the target AI Guardrail
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 5/7: Select the target AI Guardrail"
echo "============================================================"

if [[ -z "${GUARDRAIL_ID}" ]]; then
  echo "==> Listing AI Guardrails for this assistant..."
  aws qconnect list-ai-guardrails \
    --assistant-id "${ASSISTANT_ARN}" \
    --region "${REGION}" \
    --query 'aiGuardrailSummaries[].{Name:name,Id:aiGuardrailId}' \
    --output table

  echo ""
  echo "Enter the AI Guardrail ID whose Word Filters you want to add to."
  read -r -p "AI Guardrail ID: " GUARDRAIL_ID
fi

if [[ -z "${GUARDRAIL_ID}" ]]; then
  echo "ERROR: AI Guardrail ID is required." >&2
  exit 1
fi

echo "==> Target AI Guardrail ID: ${GUARDRAIL_ID}"

# -----------------------------------------------------------------------------
# Step 6: Fetch the current guardrail configuration
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 6/7: Fetch the current guardrail configuration"
echo "============================================================"

G="$(aws qconnect get-ai-guardrail \
  --assistant-id "${ASSISTANT_ARN}" \
  --ai-guardrail-id "${GUARDRAIL_ID}" \
  --region "${REGION}" \
  --query 'aiGuardrail' --output json)"

GUARDRAIL_NAME="$(echo "${G}" | jq -r '.name')"
WORD_COUNT="$(echo "${G}" | jq -r '(.wordPolicyConfig.wordsConfig // []) | length')"
VIS="$(echo "${G}" | jq -r '.visibilityStatus')"
BLOCK_IN="$(echo "${G}" | jq -r '.blockedInputMessaging')"
BLOCK_OUT="$(echo "${G}" | jq -r '.blockedOutputsMessaging')"

echo "==> Guardrail name        : ${GUARDRAIL_NAME}"
echo "==> Current custom words  : ${WORD_COUNT}"
echo "==> Words to add (max)    : ${#WORDS_TO_ADD[@]}"

# Build a JSON array of the words to add.
NEW_WORDS_JSON="$(printf '%s\n' "${WORDS_TO_ADD[@]}" | jq -R . | jq -s '[.[] | {text: .}]')"

# Recursive cleaner: drops any object key whose value is an empty array, empty
# object, or null. AWS rejects empty arrays on min-length-1 fields such as
# wordPolicyConfig.managedWordListsConfig, so we strip them everywhere before
# re-applying the policies.
CLEAN='walk(if type == "object" then with_entries(select(.value != [] and .value != {} and .value != null)) else . end)'

# Build the policy arguments to KEEP (everything except the word policy, which
# is rebuilt below as a merge of existing + new words). Each policy is passed
# through the cleaner to remove empty arrays/objects.
UPDATE_ARGS=()

TOPIC="$(echo "${G}" | jq -c "(.topicPolicyConfig // empty) | ${CLEAN}")"
[[ -n "${TOPIC}" ]] && UPDATE_ARGS+=(--topic-policy-config "${TOPIC}")

CONTENT="$(echo "${G}" | jq -c "(.contentPolicyConfig // empty) | ${CLEAN}")"
[[ -n "${CONTENT}" ]] && UPDATE_ARGS+=(--content-policy-config "${CONTENT}")

SENSITIVE="$(echo "${G}" | jq -c "(.sensitiveInformationPolicyConfig // empty) | ${CLEAN}")"
[[ -n "${SENSITIVE}" ]] && UPDATE_ARGS+=(--sensitive-information-policy-config "${SENSITIVE}")

GROUNDING="$(echo "${G}" | jq -c "(.contextualGroundingPolicyConfig // empty) | ${CLEAN}")"
[[ -n "${GROUNDING}" ]] && UPDATE_ARGS+=(--contextual-grounding-policy-config "${GROUNDING}")

# Merge existing custom words with the new words (de-duplicated, case-insensitive
# on the "text" field), always enable the PROFANITY managed word list (merged
# with any managed lists already configured, de-duplicated by type), and strip
# any empty arrays/objects from the result.
WORD_POLICY="$(echo "${G}" | jq -c \
  --argjson add "${NEW_WORDS_JSON}" "
    . as \$g
    | ((\$g.wordPolicyConfig.wordsConfig // []) + \$add | unique_by(.text | ascii_downcase)) as \$merged
    | ((\$g.wordPolicyConfig.managedWordListsConfig // []) + [{\"type\": \"PROFANITY\"}] | unique_by(.type)) as \$managed
    | {wordsConfig: \$merged, managedWordListsConfig: \$managed}
    | ${CLEAN}
  ")"

MERGED_COUNT="$(echo "${WORD_POLICY}" | jq -r '.wordsConfig | length')"
ADDED_COUNT="$(( MERGED_COUNT - WORD_COUNT ))"

UPDATE_ARGS+=(--word-policy-config "${WORD_POLICY}")

# -----------------------------------------------------------------------------
# Step 7: Re-apply all policies, with the merged Word Filters
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Step 7/7: Add words to the Word Filters"
echo "============================================================"
echo "This will OVERWRITE the guardrail, keeping all other policies and"
echo "setting the Word Filters to ${MERGED_COUNT} word(s)"
echo "(was ${WORD_COUNT}, ${ADDED_COUNT} new word(s) added after de-duplication)."
read -r -p "Proceed? (yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Aborted. No changes were made."
  exit 0
fi

aws qconnect update-ai-guardrail \
  --assistant-id "${ASSISTANT_ARN}" \
  --ai-guardrail-id "${GUARDRAIL_ID}" \
  --region "${REGION}" \
  --visibility-status "${VIS}" \
  --blocked-input-messaging "${BLOCK_IN}" \
  --blocked-outputs-messaging "${BLOCK_OUT}" \
  ${UPDATE_ARGS[@]+"${UPDATE_ARGS[@]}"}

echo ""
echo "==> Done. Word Filters of '${GUARDRAIL_NAME}' (${GUARDRAIL_ID}) now contain ${MERGED_COUNT} custom word(s)."
