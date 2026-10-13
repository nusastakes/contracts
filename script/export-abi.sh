#!/usr/bin/env bash
# Writes the ABI of every deployed contract to abi/<Name>.json, for the frontend and the relayer.
#   ./script/export-abi.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p abi
for c in CityVault CityFactory CityGuardian ApyFeed YieldReserve MirrorYieldAdapter ERC4626Adapter AgentMarketplace; do
  forge inspect "$c" abi --json > "abi/$c.json"
  echo "abi/$c.json ($(python3 -c "import json,sys;print(len(json.load(open('abi/$c.json'))))") entries)"
done
