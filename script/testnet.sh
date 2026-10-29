#!/usr/bin/env bash
# Base Sepolia helper. Reads .env and .env.services (make them with script/new-testnet-keys.sh).
#   script/testnet.sh status   ETH and USDC balance of every role
#   script/testnet.sh fund     deployer sends gas ETH to the other roles; treasury sends the operator its stake USDC
#   script/testnet.sh deploy   Deploy.s.sol, then SeedAgents.s.sol; writes deployments/base-sepolia.json
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
. ./.env
. ./.env.services
set +a
RPC=$BASE_SEPOLIA_RPC
GAS_ETH=0.005

addr_of() { cast wallet address --private-key "$1"; }
DEPLOYER_ADDR=$(addr_of "$DEPLOYER_KEY")
OPERATOR_ADDR=$(addr_of "$OPERATOR_KEY_0")

usdc_of() { cast call "$USDC" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" | cut -d' ' -f1; }

status() {
  printf '%-12s %-44s %12s %12s\n' ROLE ADDRESS ETH USDC
  for pair in DEPLOYER:$DEPLOYER_ADDR GATEWAY:$GATEWAY_ADDR VALIDATOR:$VALIDATOR_ADDR TREASURY:$TREASURY_ADDR \
    ADJUDICATOR:$ADJUDICATOR_ADDR OPERATOR:$OPERATOR_ADDR; do
    a=${pair#*:}
    eth=$(cast balance "$a" --ether --rpc-url "$RPC")
    usdc=$(usdc_of "$a")
    printf '%-12s %-44s %12.6f %12.6f\n' "${pair%%:*}" "$a" "$eth" "$(echo "$usdc / 1000000" | bc -l)"
  done
}

fund() {
  for a in "$GATEWAY_ADDR" "$VALIDATOR_ADDR" "$TREASURY_ADDR" "$ADJUDICATOR_ADDR" "$OPERATOR_ADDR"; do
    echo "gas: $GAS_ETH ETH -> $a"
    cast send "$a" --value "${GAS_ETH}ether" --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
  done
  echo "stake: $STAKE_UNITS_0 USDC units treasury -> operator"
  cast send "$USDC" "transfer(address,uint256)" "$OPERATOR_ADDR" "$STAKE_UNITS_0" \
    --private-key "$TREASURY_KEY" --rpc-url "$RPC" >/dev/null
  status
}

deploy() {
  [ "$(cast chain-id --rpc-url "$RPC")" = 84532 ] || { echo "RPC is not Base Sepolia" >&2; exit 1; }
  forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$DEPLOYER_KEY"
  forge script script/SeedAgents.s.sol --rpc-url "$RPC" --broadcast --slow
  echo "Wrote deployments/base-sepolia.json and deployments/agents-base-sepolia.json"
}

case "${1:-}" in
  status) status ;;
  fund) fund ;;
  deploy) deploy ;;
  *) echo "usage: $0 status|fund|deploy" >&2; exit 2 ;;
esac
