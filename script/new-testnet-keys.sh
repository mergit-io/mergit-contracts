#!/usr/bin/env bash
# Creates fresh Base Sepolia test keys straight into git-ignored files and prints only the addresses.
#   .env           what the forge scripts read (deployer key, role addresses, agent 0)
#   .env.services  the keys the hosted services and the worker need (GATEWAY_KEY, VALIDATOR_KEY, ...)
# Test keys only: never send real funds to them. Refuses to overwrite existing files.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in .env .env.services; do
  [ -e "$f" ] && { echo "$f already exists; move it away first" >&2; exit 1; }
done
umask 077

roles=(DEPLOYER GATEWAY VALIDATOR TREASURY ADJUDICATOR OPERATOR RUNTIME)
json=$(cast wallet new --number "${#roles[@]}" --json)
declare -A addr key
for i in "${!roles[@]}"; do
  addr[${roles[$i]}]=$(jq -r ".[$i].address" <<<"$json")
  key[${roles[$i]}]=$(jq -r ".[$i].private_key" <<<"$json")
done

cat >.env <<EOF
BASE_SEPOLIA_RPC=https://sepolia.base.org
USDC=0x036CbD53842c5426634e7929541eC2318f3dCF7e
DEPLOYER_KEY=${key[DEPLOYER]}
GATEWAY_ADDR=${addr[GATEWAY]}
VALIDATOR_ADDR=${addr[VALIDATOR]}
TREASURY_ADDR=${addr[TREASURY]}
ADJUDICATOR_ADDR=${addr[ADJUDICATOR]}
AGENT_COUNT=1
OPERATOR_KEY_0=${key[OPERATOR]}
RUNTIME_ADDR_0=${addr[RUNTIME]}
AGENT_NAME_0=mergit-coder-0
# 1.5 x V per open task, 5 open tasks, V = 1 USDC
STAKE_UNITS_0=7500000
EOF

cat >.env.services <<EOF
GATEWAY_KEY=${key[GATEWAY]}
VALIDATOR_KEY=${key[VALIDATOR]}
TREASURY_KEY=${key[TREASURY]}
ADJUDICATOR_KEY=${key[ADJUDICATOR]}
# The worker signs agent 1's receipts with this (control-plane reads MERGIT_AGENT_KEY_<agent id>). A fresh
# Identity gives the first agent id 1; check deployments/agents-base-sepolia.json after the deploy.
MERGIT_AGENT_KEY_1=${key[RUNTIME]}
EOF

echo "Wrote .env and .env.services (mode 600). Addresses to fund:"
for r in "${roles[@]}"; do printf '  %-12s %s\n' "$r" "${addr[$r]}"; done
