#!/usr/bin/env bash
# Fills the YieldReserve with testnet AUSD from the public Agora faucet.
#
#   ./script/fund-reserve.sh <reserve-address> [drips]
#
# Each drip gives 10,000 AUSD (faucetDripAmount), the faucet allows one drip per 60 s (maxDripFrequency) and stops
# at 100,000 AUSD held (maxAmountToOwn), so at most 10 drips. Everything the deployer then holds is transferred to
# the reserve. Reads DEPLOYER_PRIVATE_KEY and MONAD_TESTNET_RPC from the environment (for example `set -a; . ../.env`);
# the key is never printed. DRY_RUN=1 prints what would be sent and sends nothing.
set -euo pipefail

RESERVE="${1:?usage: fund-reserve.sh <reserve-address> [drips]}"
DRIPS="${2:-3}"
RPC="${MONAD_TESTNET_RPC:-https://testnet-rpc.monad.xyz}"
AUSD="${ASSET_ADDRESS:-0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC}"
FAUCET="${AUSD_FAUCET:-0xd236c18D274E54FAccC3dd9DDA4b27965a73ee6C}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY is not set}"

ME="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
send() { if [ "${DRY_RUN:-0}" = "1" ]; then echo "DRY_RUN cast send $*"; else cast send "$@" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null; fi; }

echo "deployer $ME, reserve $RESERVE, drips $DRIPS"
for i in $(seq 1 "$DRIPS"); do
  echo "drip $i/$DRIPS"
  send "$FAUCET" "requestFunds(address)" "$ME"
  if [ "$i" -lt "$DRIPS" ]; then [ "${DRY_RUN:-0}" = "1" ] || sleep 61; fi
done

BAL="$(cast call "$AUSD" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')"
echo "deployer AUSD balance (6 decimals): $BAL"
if [ "$BAL" != "0" ]; then
  send "$AUSD" "transfer(address,uint256)" "$RESERVE" "$BAL"
  echo "transferred $BAL to the reserve"
fi
echo "reserve now holds: $(cast call "$AUSD" "balanceOf(address)(uint256)" "$RESERVE" --rpc-url "$RPC")"
