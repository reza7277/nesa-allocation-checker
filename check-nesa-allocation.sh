#!/usr/bin/env bash
# Nesa miner allocation checker and alternate-key claim launcher.
#
# The claim path intentionally delegates signing and submission to Nesa's
# official alternate-key CLI. That method accepts the real Node ID separately
# and proves ownership with the secp256k1 key used to sign miner requests.

set -euo pipefail

readonly APP_NAME="nesa-allocation-checker"
readonly ALLOCATION_ENDPOINT="https://rewards-proxy.nesa.ai/api/allocation"

# Audited official Nesa alternate-key release (2026-07-17). Pinning both the
# commit and digest prevents a future branch change from silently executing
# different code on a machine that holds a private key.
readonly OFFICIAL_COMMIT="b204312dd53104df9680f08438c15e25177c0dc8"
readonly OFFICIAL_ALT_URL="https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/${OFFICIAL_COMMIT}/claim-rewards-alt.sh"
readonly OFFICIAL_ALT_SHA256="9e040755e5633957aa47807adbebb5c8ad9b4fcd86c5fc8228197942d46ce41d"
readonly PATCHED_ALT_SHA256="29bc7697950c014fdd590723fe18893ae2efa75a59fbe04385d173340eb01708"

if [[ -t 1 ]]; then
  readonly B=$'\033[1m' DIM=$'\033[2m' R=$'\033[0m'
  readonly RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m'
  readonly CYN=$'\033[36m' MAG=$'\033[35m'
else
  readonly B="" DIM="" R="" RED="" GRN="" YEL="" CYN="" MAG=""
fi

err() { printf '%sError:%s %s\n' "$RED" "$R" "$*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

for required in bash curl python3; do
  if ! have_cmd "$required"; then
    err "$required is required but was not found."
    exit 1
  fi
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.XXXXXX")"
chmod 700 "$WORKDIR"
OFFICIAL_ALT_SH="$WORKDIR/claim-rewards-alt.sh"
KEY_FILE=""

cleanup() {
  if [[ -n "$KEY_FILE" ]]; then
    rm -f -- "$KEY_FILE"
  fi
  rm -f -- "$OFFICIAL_ALT_SH"
  rmdir -- "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

normalize_node_id() {
  local value="$1"
  value="${value//[[:space:]]/}"
  printf '%s' "$value"
}

valid_node_id() {
  local value="$1"
  [[ ${#value} -ge 32 && ${#value} -le 64 && "$value" =~ ^[1-9A-HJ-NP-Za-km-z]+$ ]]
}

looks_like_private_key() {
  local value="${1#0x}"
  [[ "$value" =~ ^[0-9a-fA-F]{64}$ ]]
}

file_sha256() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
digest = hashlib.sha256(path.read_bytes()).hexdigest()
print(digest)
PY
}

patch_official_amount_display() {
  # The pinned official CLI strips every trailing zero from formatted values,
  # including integer zeros (30 -> 3, 100 -> 1). Apply one exact, fail-closed
  # display-only replacement. Claim payloads, signing, and endpoints are not
  # touched.
  python3 - "$1" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_bytes()
old = b'    nes_str = format(nes, "f").rstrip("0").rstrip(".")\n'
new = (
    b'    nes_str = format(nes, "f")\n'
    b'    if "." in nes_str:\n'
    b'        nes_str = nes_str.rstrip("0").rstrip(".")\n'
)

if content.count(old) != 1:
    raise SystemExit("expected official display line was not found exactly once")

path.write_bytes(content.replace(old, new))
PY
}

download_official_alt_cli() {
  if [[ -s "$OFFICIAL_ALT_SH" ]]; then
    return 0
  fi

  printf '%sDownloading the pinned official Nesa alternate-claim CLI...%s\n' "$DIM" "$R"
  if ! curl --proto '=https' --tlsv1.2 -fsSL \
    --retry 3 --retry-delay 2 \
    "$OFFICIAL_ALT_URL" -o "$OFFICIAL_ALT_SH"; then
    err "Could not download the official Nesa alternate-claim CLI."
    return 1
  fi

  local actual_sha
  actual_sha="$(file_sha256 "$OFFICIAL_ALT_SH")"
  if [[ "$actual_sha" != "$OFFICIAL_ALT_SHA256" ]]; then
    rm -f -- "$OFFICIAL_ALT_SH"
    err "Official CLI integrity check failed; refusing to handle a private key."
    err "Expected SHA-256: $OFFICIAL_ALT_SHA256"
    err "Received SHA-256: $actual_sha"
    return 1
  fi

  if ! patch_official_amount_display "$OFFICIAL_ALT_SH"; then
    rm -f -- "$OFFICIAL_ALT_SH"
    err "Could not apply the audited amount-display fix; refusing to continue."
    return 1
  fi

  actual_sha="$(file_sha256 "$OFFICIAL_ALT_SH")"
  if [[ "$actual_sha" != "$PATCHED_ALT_SHA256" ]]; then
    rm -f -- "$OFFICIAL_ALT_SH"
    err "Patched official CLI integrity check failed; refusing to continue."
    err "Expected SHA-256: $PATCHED_ALT_SHA256"
    err "Received SHA-256: $actual_sha"
    return 1
  fi

  chmod 500 "$OFFICIAL_ALT_SH"
}

render_allocation() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
from decimal import Decimal, InvalidOperation

node_id = sys.argv[1]

try:
    response = json.loads(sys.argv[2])
except (json.JSONDecodeError, TypeError) as exc:
    print(f"  ERROR {node_id}: invalid server response ({exc})")
    raise SystemExit(2)

data = response.get("allocation")
if not isinstance(data, dict):
    data = {}

value = None
for source in (response, data):
    for field in (
        "remaining_allocation",
        "claimable_allocation",
        "allocation",
        "amount",
        "total_allocation",
    ):
        candidate = source.get(field)
        if candidate is not None and not isinstance(candidate, dict):
            value = candidate
            break
    if value is not None:
        break

if value is None:
    print(f"  ERROR {node_id}: allocation amount missing from server response")
    raise SystemExit(2)

try:
    nes = Decimal(str(value)) / (Decimal(10) ** 18)
except (InvalidOperation, ValueError):
    print(f"  ERROR {node_id}: invalid allocation amount: {value}")
    raise SystemExit(2)

claimed = response.get("claimed")
if claimed is None:
    claimed = data.get("claimed")

claimed_status = response.get("claimed_status") or data.get("claimed_status")
if isinstance(claimed_status, dict):
    if claimed_status.get("claimed") is True:
        claimed = True
    try:
        if Decimal(str(claimed_status.get("claimed_amount", 0))) > 0:
            claimed = True
    except InvalidOperation:
        pass

if claimed is True:
    status = "already claimed"
elif nes > 0:
    status = "CLAIMABLE"
else:
    status = "no allocation"

amount = format(nes, "f")
if "." in amount:
    amount = amount.rstrip("0").rstrip(".")
amount = amount or "0"
print(f"  {node_id}  ->  {amount} NES  [{status}]")
PY
}

check_one_node() {
  local node_id="$1" response
  printf '  Checking %s...\n' "$node_id"

  if ! response="$(curl --proto '=https' --tlsv1.2 -fsS \
    --retry 3 --retry-delay 2 \
    --get --data-urlencode "node_id=$node_id" \
    "$ALLOCATION_ENDPOINT")"; then
    err "Allocation lookup failed for $node_id"
    return 1
  fi

  if ! render_allocation "$node_id" "$response"; then
    err "Could not interpret the allocation response for $node_id"
    return 1
  fi
}

check_allocations() {
  printf '\n%sEnter Node ID(s)%s, one per line. Submit an empty line to start checking.\n' "$B" "$R"

  local node_id
  local -a node_ids=()
  while true; do
    printf '  Node ID #%d: ' "$(( ${#node_ids[@]} + 1 ))"
    IFS= read -r node_id || break
    node_id="$(normalize_node_id "$node_id")"
    [[ -z "$node_id" ]] && break

    if looks_like_private_key "$node_id"; then
      err "That looks like a private key, not a Node ID. Nothing was sent."
      continue
    fi
    if ! valid_node_id "$node_id"; then
      err "Invalid Node ID format."
      continue
    fi
    node_ids+=("$node_id")
  done

  if [[ ${#node_ids[@]} -eq 0 ]]; then
    err "No valid Node IDs entered."
    return 1
  fi

  printf '\n%sAllocation results%s\n' "$CYN" "$R"
  local failed=0
  for node_id in "${node_ids[@]}"; do
    check_one_node "$node_id" || failed=$((failed + 1))
  done

  if [[ $failed -gt 0 ]]; then
    printf '%s%d lookup(s) failed. You can retry safely.%s\n' "$YEL" "$failed" "$R"
  fi
}

claim_alternate() {
  printf '\n%s%sALTERNATE CLAIM%s\n' "$YEL" "$B" "$R"
  printf '%sThis submits a real claim through Nesa\047s official alternate-key CLI.%s\n' "$YEL" "$R"
  printf 'You will confirm the Node ID, Terms, destination address, and final submission.\n\n'

  local node_id private_key evm_address
  printf 'Node ID with the allocation: '
  IFS= read -r node_id || return 1
  node_id="$(normalize_node_id "$node_id")"
  if ! valid_node_id "$node_id"; then
    err "Invalid Node ID format."
    return 1
  fi

  printf 'Alternate secp256k1 private key (input hidden): '
  IFS= read -rs private_key || return 1
  printf '\n'
  private_key="${private_key//[[:space:]]/}"
  private_key="${private_key#0x}"
  if [[ ! "$private_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
    err "Private key must be exactly 64 hexadecimal characters (0x is optional)."
    unset private_key
    return 1
  fi

  printf 'Destination EVM address (0x...), or empty to enter it inside the official CLI: '
  IFS= read -r evm_address || true
  evm_address="${evm_address//[[:space:]]/}"
  if [[ -n "$evm_address" && ! "$evm_address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    err "Invalid EVM address."
    unset private_key
    return 1
  fi

  # Verify the official program before writing the private key to disk.
  if ! download_official_alt_cli; then
    unset private_key
    return 1
  fi

  KEY_FILE="$WORKDIR/alternate-key.env"
  (umask 077; printf 'NODE_PRIV_KEY="%s"\n' "$private_key" > "$KEY_FILE")
  unset private_key

  printf '\n%sLaunching verified official CLI (commit %s)...%s\n' \
    "$GRN" "$OFFICIAL_COMMIT" "$R"

  local status=0
  if [[ -n "$evm_address" ]]; then
    bash "$OFFICIAL_ALT_SH" \
      --node-id "$node_id" \
      --private-key-path "$KEY_FILE" \
      --evm-address "$evm_address" || status=$?
  else
    bash "$OFFICIAL_ALT_SH" \
      --node-id "$node_id" \
      --private-key-path "$KEY_FILE" || status=$?
  fi

  rm -f -- "$KEY_FILE"
  KEY_FILE=""

  if [[ $status -ne 0 ]]; then
    err "Official CLI exited with status $status. No automatic retry was attempted."
    return "$status"
  fi

  printf '\n%sCheck the official Summary and explorer link above before closing this terminal.%s\n' "$YEL" "$R"
}

show_menu() {
  printf '\n%s%s' "$MAG" "$B"
  printf '  ╔════════════════════════════════════════╗\n'
  printf '  ║      NESA ALLOCATION & CLAIM TOOL      ║\n'
  printf '  ╚════════════════════════════════════════╝%s\n' "$R"
  printf '  %s1%s) %sCheck allocation%s   %s- Node ID only, read-only%s\n' "$B" "$R" "$CYN" "$R" "$DIM" "$R"
  printf '  %s2%s) %sClaim allocation%s   %s- fixed alternate-key method%s\n' "$B" "$R" "$GRN" "$R" "$DIM" "$R"
  printf '  %sq%s) %sQuit%s\n' "$B" "$R" "$DIM" "$R"
}

main() {
  local choice
  while true; do
    show_menu
    printf '\n%sChoose an option:%s ' "$B" "$R"
    IFS= read -r choice || break
    case "$choice" in
      1) check_allocations || true ;;
      2) claim_alternate || true ;;
      q|Q|quit|exit) break ;;
      *) err "Invalid choice: $choice" ;;
    esac

    printf '\n%sPress Enter to return to the menu...%s' "$DIM" "$R"
    IFS= read -r _ || break
  done

  printf '\n%sDone. Temporary files removed.%s\n' "$GRN" "$R"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
