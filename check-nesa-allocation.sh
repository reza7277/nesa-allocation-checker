#!/usr/bin/env bash
# Nesa miner Node ID finder, allocation checker, and claim launcher.
#
# The claim path intentionally delegates signing and submission to Nesa's
# official alternate-key CLI. That method accepts the real Node ID separately
# and proves ownership with the secp256k1 key used to sign miner requests.

set -euo pipefail

readonly APP_NAME="nesa-allocation-checker"
readonly ALLOCATION_ENDPOINT="https://rewards-proxy.nesa.ai/api/allocation"

# Miner registrations have existed on more than one Nesa API environment.
# The dev registry currently contains the historical registrations needed by
# the alternate-key claim flow. The current and legacy registries are checked
# too, and results are deduplicated by Node ID.
readonly REGISTRY_DEV="https://api-dev.nesa.ai"
readonly REGISTRY_CURRENT="https://api.nesa.ai"
readonly REGISTRY_LEGACY="https://api-test.nesa.ai"
readonly REGISTRY_PAGE_LIMIT=100

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
REGISTRY_PAGE_FILE="$WORKDIR/registry-page.json"
KEY_FILE=""

cleanup() {
  if [[ -n "$KEY_FILE" ]]; then
    rm -f -- "$KEY_FILE"
  fi
  rm -f -- "$OFFICIAL_ALT_SH" "$REGISTRY_PAGE_FILE"
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
  value="${value#0X}"
  [[ "$value" =~ ^[0-9a-fA-F]{64}$ ]]
}

normalize_private_key() {
  local value="$1"
  value="${value//[[:space:]]/}"
  value="${value#0x}"
  value="${value#0X}"
  printf '%s' "$value"
}

derive_compressed_public_key() {
  # Public-key derivation is performed locally with Python's standard library.
  # The private key is supplied over stdin, never as a process argument or URL.
  printf '%s' "$1" | python3 /dev/fd/3 3<<'PY'
import re
import sys

# secp256k1 domain parameters
FIELD = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GENERATOR = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)

value = sys.stdin.read().strip()
if value.lower().startswith("0x"):
    value = value[2:]
if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
    raise SystemExit(2)

scalar = int(value, 16)
if not 1 <= scalar < ORDER:
    raise SystemExit(2)

def point_add(left, right):
    if left is None:
        return right
    if right is None:
        return left

    x1, y1 = left
    x2, y2 = right
    if x1 == x2 and (y1 + y2) % FIELD == 0:
        return None

    if left == right:
        slope = (3 * x1 * x1) * pow(2 * y1, FIELD - 2, FIELD) % FIELD
    else:
        slope = (y2 - y1) * pow(x2 - x1, FIELD - 2, FIELD) % FIELD

    x3 = (slope * slope - x1 - x2) % FIELD
    y3 = (slope * (x1 - x3) - y1) % FIELD
    return x3, y3

def scalar_multiply(multiplier, point):
    result = None
    while multiplier:
        if multiplier & 1:
            result = point_add(result, point)
        point = point_add(point, point)
        multiplier >>= 1
    return result

x, y = scalar_multiply(scalar, GENERATOR)
prefix = "02" if y % 2 == 0 else "03"
print(prefix + f"{x:064x}")
PY
}

DISCOVERED_NODE_IDS=()
DISCOVERED_MONIKERS=()
DISCOVERED_SOURCES=()
REGISTRY_SUCCESS_COUNT=0

add_discovered_node() {
  local node_id="$1" moniker="$2" source="$3" index
  for ((index = 0; index < ${#DISCOVERED_NODE_IDS[@]}; index++)); do
    if [[ "${DISCOVERED_NODE_IDS[$index]}" == "$node_id" ]]; then
      case ",${DISCOVERED_SOURCES[$index]}," in
        *",$source,"*) ;;
        *) DISCOVERED_SOURCES[$index]="${DISCOVERED_SOURCES[$index]},$source" ;;
      esac
      if [[ "${DISCOVERED_MONIKERS[$index]}" == "-" && "$moniker" != "-" ]]; then
        DISCOVERED_MONIKERS[$index]="$moniker"
      fi
      return 0
    fi
  done

  DISCOVERED_NODE_IDS+=("$node_id")
  DISCOVERED_MONIKERS+=("$moniker")
  DISCOVERED_SOURCES+=("$source")
}

query_node_registry() {
  local registry_name="$1" base_url="$2" public_key="$3" max_time="$4"
  local skip=0 page_file="$REGISTRY_PAGE_FILE"
  local parsed record_type first second item_count total_count

  while true; do
    if ! curl --proto '=https' --tlsv1.2 -fsS \
      --connect-timeout 5 --max-time "$max_time" \
      --get --data-urlencode "limit=$REGISTRY_PAGE_LIMIT" \
      --data-urlencode "skip=$skip" \
      "$base_url/nodes/$public_key/list" -o "$page_file" 2>/dev/null; then
      printf '%sWarning:%s registry %s was unavailable; continuing.\n' \
        "$YEL" "$R" "$registry_name" >&2
      return 1
    fi

    if ! parsed="$(python3 - "$public_key" "$page_file" <<'PY'
import json
import re
import sys

expected_key = sys.argv[1].lower()
try:
    with open(sys.argv[2], "r", encoding="utf-8") as handle:
        response = json.load(handle)
except (OSError, json.JSONDecodeError, TypeError) as exc:
    print(f"invalid registry response: {exc}", file=sys.stderr)
    raise SystemExit(2)

items = response.get("list")
if not isinstance(items, list):
    print("registry response does not contain a list", file=sys.stderr)
    raise SystemExit(2)

total = response.get("total_count", len(items))
try:
    total = max(0, int(total))
except (TypeError, ValueError):
    total = len(items)

print(f"META\t{len(items)}\t{total}")
for item in items:
    if not isinstance(item, dict):
        continue
    returned_key = str(item.get("public_key", "")).lower()
    if returned_key.startswith("0x"):
        returned_key = returned_key[2:]
    if returned_key != expected_key:
        continue

    node_id = str(item.get("node_id", "")).strip()
    if not re.fullmatch(r"[1-9A-HJ-NP-Za-km-z]{32,64}", node_id):
        continue

    moniker = str(item.get("moniker") or "-")
    moniker = "".join(
        character if ord(character) >= 32 and ord(character) != 127 else " "
        for character in moniker
    ).strip() or "-"
    print(f"NODE\t{node_id}\t{moniker}")
PY
)"; then
      printf '%sWarning:%s registry %s returned invalid data; continuing.\n' \
        "$YEL" "$R" "$registry_name" >&2
      return 1
    fi

    if [[ "$skip" -eq 0 ]]; then
      REGISTRY_SUCCESS_COUNT=$((REGISTRY_SUCCESS_COUNT + 1))
    fi

    item_count=0
    total_count=0
    while IFS=$'\t' read -r record_type first second; do
      case "$record_type" in
        META)
          item_count="$first"
          total_count="$second"
          ;;
        NODE)
          add_discovered_node "$first" "$second" "$registry_name"
          ;;
      esac
    done <<< "$parsed"

    if [[ "$item_count" -lt "$REGISTRY_PAGE_LIMIT" ]]; then
      break
    fi
    skip=$((skip + item_count))
    if [[ "$skip" -ge "$total_count" ]]; then
      break
    fi
  done
}

discover_node_ids() {
  local public_key="$1"
  DISCOVERED_NODE_IDS=()
  DISCOVERED_MONIKERS=()
  DISCOVERED_SOURCES=()
  REGISTRY_SUCCESS_COUNT=0

  # Query the known historical registry first. A failure on one mirror is not
  # interpreted as "no nodes"; the remaining mirrors are still checked.
  query_node_registry "api-dev" "$REGISTRY_DEV" "$public_key" 20 || true
  query_node_registry "api" "$REGISTRY_CURRENT" "$public_key" 20 || true
  query_node_registry "api-test" "$REGISTRY_LEGACY" "$public_key" 6 || true
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

read_and_validate_private_key() {
  ENTERED_PRIVATE_KEY=""
  DERIVED_PUBLIC_KEY=""
  printf 'Alternate secp256k1 private key (input hidden): '
  IFS= read -rs ENTERED_PRIVATE_KEY || return 1
  printf '\n'
  ENTERED_PRIVATE_KEY="$(normalize_private_key "$ENTERED_PRIVATE_KEY")"
  if [[ ! "$ENTERED_PRIVATE_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
    err "Private key must be exactly 64 hexadecimal characters (0x is optional)."
    ENTERED_PRIVATE_KEY=""
    return 1
  fi

  if ! DERIVED_PUBLIC_KEY="$(derive_compressed_public_key "$ENTERED_PRIVATE_KEY")" ||
    [[ ! "$DERIVED_PUBLIC_KEY" =~ ^0[23][0-9a-f]{64}$ ]]; then
    err "Private key is outside the valid secp256k1 range."
    ENTERED_PRIVATE_KEY=""
    DERIVED_PUBLIC_KEY=""
    return 1
  fi
}

prompt_evm_address() {
  ENTERED_EVM_ADDRESS=""
  printf 'Destination EVM address (0x...), or empty to enter it inside the official CLI: '
  IFS= read -r ENTERED_EVM_ADDRESS || true
  ENTERED_EVM_ADDRESS="${ENTERED_EVM_ADDRESS//[[:space:]]/}"
  if [[ -n "$ENTERED_EVM_ADDRESS" && ! "$ENTERED_EVM_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    err "Invalid EVM address."
    ENTERED_EVM_ADDRESS=""
    return 1
  fi
}

launch_official_claim() {
  local node_id="$1" private_key="$2" evm_address="$3"

  # Verify the official program before writing the private key to disk.
  if ! download_official_alt_cli; then
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

claim_alternate() {
  printf '\n%s%sMANUAL ALTERNATE CLAIM%s\n' "$YEL" "$B" "$R"
  printf '%sThis submits a real claim through Nesa\047s official alternate-key CLI.%s\n' "$YEL" "$R"
  printf 'You will confirm the Node ID, Terms, destination address, and final submission.\n\n'

  local node_id status=0
  printf 'Node ID with the allocation: '
  IFS= read -r node_id || return 1
  node_id="$(normalize_node_id "$node_id")"
  if ! valid_node_id "$node_id"; then
    err "Invalid Node ID format."
    return 1
  fi

  if ! read_and_validate_private_key; then
    return 1
  fi
  if ! prompt_evm_address; then
    ENTERED_PRIVATE_KEY=""
    DERIVED_PUBLIC_KEY=""
    return 1
  fi

  launch_official_claim \
    "$node_id" "$ENTERED_PRIVATE_KEY" "$ENTERED_EVM_ADDRESS" || status=$?
  ENTERED_PRIVATE_KEY=""
  DERIVED_PUBLIC_KEY=""
  ENTERED_EVM_ADDRESS=""
  return "$status"
}

discover_and_claim() {
  printf '\n%s%sDISCOVER NODE IDs & CLAIM%s\n' "$CYN" "$B" "$R"
  printf 'The private key stays local. Only its compressed public key is sent to Nesa registries.\n'
  printf 'No claim is submitted until you choose a Node ID and confirm inside the official CLI.\n\n'

  if ! read_and_validate_private_key; then
    return 1
  fi

  printf 'Derived compressed public key: %s\n' "$DERIVED_PUBLIC_KEY"
  printf '%sSearching Nesa node registries...%s\n' "$DIM" "$R"
  discover_node_ids "$DERIVED_PUBLIC_KEY"

  if [[ ${#DISCOVERED_NODE_IDS[@]} -eq 0 ]]; then
    if [[ "$REGISTRY_SUCCESS_COUNT" -eq 0 ]]; then
      err "No registry could be queried successfully. Retry later; this is not proof that no Node ID exists."
    else
      err "No Node ID with an exact matching public key was found in the reachable registries."
    fi
    ENTERED_PRIVATE_KEY=""
    DERIVED_PUBLIC_KEY=""
    return 1
  fi

  printf '\n%sFound %d Node ID(s):%s\n' "$GRN" "${#DISCOVERED_NODE_IDS[@]}" "$R"
  local index node_id selection selected_index status=0
  for ((index = 0; index < ${#DISCOVERED_NODE_IDS[@]}; index++)); do
    printf '  %d) %s  moniker=%s  source=%s\n' \
      "$((index + 1))" \
      "${DISCOVERED_NODE_IDS[$index]}" \
      "${DISCOVERED_MONIKERS[$index]}" \
      "${DISCOVERED_SOURCES[$index]}"
  done

  printf '\n%sAllocation results%s\n' "$CYN" "$R"
  for node_id in "${DISCOVERED_NODE_IDS[@]}"; do
    check_one_node "$node_id" || true
  done

  printf '\nChoose the Node ID to claim (1-%d), or 0 to cancel: ' \
    "${#DISCOVERED_NODE_IDS[@]}"
  IFS= read -r selection || selection=0
  if [[ ! "$selection" =~ ^[0-9]{1,6}$ ]]; then
    err "Invalid selection."
    ENTERED_PRIVATE_KEY=""
    DERIVED_PUBLIC_KEY=""
    return 1
  fi
  selection=$((10#$selection))
  if [[ "$selection" -eq 0 ]]; then
    printf '%sCancelled; no claim was submitted.%s\n' "$YEL" "$R"
    ENTERED_PRIVATE_KEY=""
    DERIVED_PUBLIC_KEY=""
    return 0
  fi
  if [[ "$selection" -gt ${#DISCOVERED_NODE_IDS[@]} ]]; then
    err "Selection is outside the displayed range."
    ENTERED_PRIVATE_KEY=""
    DERIVED_PUBLIC_KEY=""
    return 1
  fi
  selected_index=$((selection - 1))
  node_id="${DISCOVERED_NODE_IDS[$selected_index]}"

  if ! prompt_evm_address; then
    ENTERED_PRIVATE_KEY=""
    DERIVED_PUBLIC_KEY=""
    return 1
  fi

  launch_official_claim \
    "$node_id" "$ENTERED_PRIVATE_KEY" "$ENTERED_EVM_ADDRESS" || status=$?
  ENTERED_PRIVATE_KEY=""
  DERIVED_PUBLIC_KEY=""
  ENTERED_EVM_ADDRESS=""
  return "$status"
}

show_menu() {
  printf '\n%s%s' "$MAG" "$B"
  printf '  ╔════════════════════════════════════════╗\n'
  printf '  ║      NESA ALLOCATION & CLAIM TOOL      ║\n'
  printf '  ╚════════════════════════════════════════╝%s\n' "$R"
  printf '  %s1%s) %sCheck allocation%s        %s- Node ID only, read-only%s\n' "$B" "$R" "$CYN" "$R" "$DIM" "$R"
  printf '  %s2%s) %sDiscover IDs & claim%s     %s- private key only%s\n' "$B" "$R" "$GRN" "$R" "$DIM" "$R"
  printf '  %s3%s) %sManual alternate claim%s   %s- Node ID + private key%s\n' "$B" "$R" "$YEL" "$R" "$DIM" "$R"
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
      2) discover_and_claim || true ;;
      3) claim_alternate || true ;;
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
