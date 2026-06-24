#!/usr/bin/env bash
#
# check-nesa-allocation.sh  --  Nesa Rewards Checker (interactive TUI)
# -------------------------------------------------------------------
# A single all-in-one tool with a terminal menu. Choose:
#
#   1) Node ID checker          - check allocation by Node ID (no key needed)
#   2) Private key checker       - check allocation from one private key
#   3) Batch private key checker - paste many private keys, check them all
#
# Read-only: it NEVER submits a claim. It reuses the official
# nesaorg/miner-rewards-cli logic so derived identities match exactly.
#
# Usage:  bash check-nesa-allocation.sh
#
set -euo pipefail

APP_NAME="nesa-allocation-check"
VENV_DIR="${REWARDS_CLI_VENV:-$HOME/.cache/$APP_NAME/venv}"
OFFICIAL_URL="https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/main/claim-rewards.sh"

DEPS=(
  "requests==2.32.3"
  "coincurve==20.0.0"
  "bech32==1.2.0"
  "cryptography==43.0.3"
  "base58==2.1.1"
)

# --- colors (only if stdout is a terminal) --------------------------------
if [ -t 1 ]; then
  B="\033[1m"; DIM="\033[2m"; R="\033[0m"
  RED="\033[31m"; GRN="\033[32m"; YEL="\033[33m"; CYN="\033[36m"; MAG="\033[35m"
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; CYN=""; MAG=""
fi

err()      { printf "${RED}Error:${R} %s\n" "$*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! have_cmd python3; then err "python3 is required but was not found."; exit 1; fi
if ! have_cmd curl;    then err "curl is required but was not found.";    exit 1; fi

# --- temp workspace (auto-cleaned) ---------------------------------------
WORKDIR="$(mktemp -d)"; chmod 700 "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

OFFICIAL_SH="$WORKDIR/claim-rewards.sh"
MODULE_PY="$WORKDIR/nesa_cli.py"; export MODULE_PY
RUNNER_PY="$WORKDIR/runner.py"
INPUT_FILE="$WORKDIR/input.txt"

# ==========================================================================
# One-time setup: venv, deps, official module, python runner
# ==========================================================================
setup() {
  if [ ! -d "$VENV_DIR" ]; then
    printf "${DIM}Setting up environment at %s ...${R}\n" "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
  PYTHON="$VENV_DIR/bin/python"
  PIP="$VENV_DIR/bin/pip"

  if ! "$PYTHON" - <<'PY_CHECK' >/dev/null 2>&1
import requests, coincurve, bech32, base58
from cryptography.hazmat.primitives.asymmetric import ed25519
PY_CHECK
  then
    printf "${DIM}Installing dependencies ...${R}\n"
    "$PIP" install --quiet --upgrade pip
    "$PIP" install --quiet "${DEPS[@]}"
  fi

  printf "${DIM}Downloading official Nesa CLI logic ...${R}\n"
  curl -fsSL "$OFFICIAL_URL" -o "$OFFICIAL_SH"
  awk '
    /<<'\''PY_APP'\''/ { capture=1; next }
    capture && /^if __name__ == "__main__":/ { exit }
    capture { print }
  ' "$OFFICIAL_SH" > "$MODULE_PY"
  if [ ! -s "$MODULE_PY" ]; then
    err "Could not extract logic from the official script (format may have changed)."
    exit 1
  fi

  write_runner
}

write_runner() {
  cat > "$RUNNER_PY" <<'PY_RUNNER'
import importlib.util, json, os, sys, time
from decimal import Decimal

module_path = os.environ["MODULE_PY"]
spec = importlib.util.spec_from_file_location("nesa_cli", module_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Terminal colors
TTY = sys.stdout.isatty()
def c(code): return code if TTY else ""
B, DIM, R = c("\033[1m"), c("\033[2m"), c("\033[0m")
RED, GRN, YEL, CYN, MAG = c("\033[31m"), c("\033[32m"), c("\033[33m"), c("\033[36m"), c("\033[35m")

ONE = Decimal(10) ** 18
# Server keys allocation off node_id; cosmos_address only needs to be present.
PLACEHOLDER_ADDR = "nesa1w508d6qejxtdg4y5r3zarvary0c5xw7kcc5gqf"

def banner(t):
    line = "=" * (len(t) + 4)
    print(f"\n{CYN}{line}\n  {B}{t}{R}{CYN}\n{line}{R}")

def get_json_retry(params, attempts=5, delay=10):
    last = None
    for i in range(attempts):
        try:
            return m.get_json(m.DEFAULT_ALLOCATION_ENDPOINT, params=params)
        except m.CliError as exc:
            sc = getattr(exc, "status_code", None)
            last = exc
            if (sc in (500, 502, 503, 504) or sc is None) and i < attempts - 1:
                print(f"  {YEL}Transient server error (HTTP {sc}); retry in {delay}s ({i+1}/{attempts}){R}")
                time.sleep(delay)
                continue
            raise
    raise last

def query(node_id, cosmos_address):
    """Return dict: ok, node_id, address, nes, claimed, error."""
    out = {"node_id": node_id, "address": cosmos_address, "nes": None,
           "claimed": None, "ok": False, "error": None}
    try:
        resp = get_json_retry({"cosmos_address": cosmos_address, "node_id": node_id})
        try:
            amount = m.extract_allocation_amount(resp)
        except Exception:
            amount = Decimal("0")
        out["nes"] = amount / ONE
        out["claimed"] = bool(m.allocation_claimed(resp))
        out["ok"] = True
    except m.CliError as exc:
        out["error"] = str(exc).splitlines()[0]
    return out

def from_key(hexkey):
    """Validate + derive identity from a 64-hex private key. Returns (node_id, cosmos) or raises."""
    hexkey = hexkey.strip().lower()
    if hexkey.startswith("0x"):
        hexkey = hexkey[2:]
    if len(hexkey) != 64 or any(ch not in "0123456789abcdef" for ch in hexkey):
        raise ValueError("not a 64-char hex private key")
    pk = m.PrivateKey(bytes.fromhex(hexkey))
    cosmos = m.cosmos_address_from_private_key(pk, m.DEFAULT_BECH32_PREFIX)
    node_id = m.derive_node_identity_from_private_key_hex(hexkey)["node_id"]
    return node_id, cosmos

def print_result(res, label=None):
    head = label or res["node_id"]
    if not res["ok"]:
        print(f"  {RED}\u2717{R} {head}  {DIM}{res['error']}{R}")
        return
    nes = res["nes"]
    if res["claimed"]:
        tag = f"{YEL}already claimed{R}"
    elif nes > 0:
        tag = f"{GRN}claimable{R}"
    else:
        tag = f"{DIM}no allocation{R}"
    print(f"  {GRN}\u2713{R} {head}  ->  {B}{nes:.6f} NES{R}  [{tag}]")

def shorten(s, n=14):
    return s if len(s) <= n else s[:n-3] + "..."

def main():
    mode = sys.argv[1]
    items = [ln.strip() for ln in open(sys.argv[2], encoding="utf-8") if ln.strip()]

    results = []

    if mode == "nodeid":
        banner("Node ID checker")
        for nid in items:
            res = query(nid, PLACEHOLDER_ADDR)
            print_result(res, label=nid)
            results.append(res)

    elif mode in ("key", "batch"):
        banner("Private key checker" if mode == "key" else "Batch private key checker")
        for idx, hexkey in enumerate(items, 1):
            try:
                node_id, cosmos = from_key(hexkey)
            except ValueError as e:
                print(f"  {RED}\u2717{R} key #{idx}  {DIM}{e}{R}")
                results.append({"ok": False, "node_id": f"key#{idx}", "error": str(e)})
                continue
            res = query(node_id, cosmos)
            label = f"{node_id}"
            if mode == "key":
                print(f"  {DIM}Cosmos:{R} {cosmos}")
                print(f"  {DIM}Node ID:{R} {node_id}")
            print_result(res, label=shorten(label, 20) if mode == "batch" else label)
            results.append(res)
    else:
        print(f"{RED}Unknown mode: {mode}{R}"); sys.exit(1)

    ok = [r for r in results if r.get("ok")]
    if len(results) > 1:
        total = sum((r["nes"] for r in ok), Decimal(0))
        claimable = sum((r["nes"] for r in ok if not r["claimed"]), Decimal(0))
        banner("Summary")
        print(f"  Checked:        {len(results)}")
        print(f"  Succeeded:      {len(ok)}")
        print(f"  Total alloc:    {B}{total:.6f} NES{R}")
        print(f"  Still claimable:{B} {claimable:.6f} NES{R}")

    if any(r.get("ok") and not r["claimed"] and r["nes"] > 0 for r in results):
        print(f"\n{DIM}This tool only CHECKS allocations. To claim, use the official CLI:{R}")
        print(f"{DIM}  bash <(curl -fsSL https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/main/claim-rewards.sh){R}")

if __name__ == "__main__":
    main()
PY_RUNNER
}

# ==========================================================================
# Input collectors
# ==========================================================================
collect_node_ids() {
  : > "$INPUT_FILE"
  echo
  printf "${B}Enter Node ID(s)${R} - one per line. Press ${B}Enter on an empty line${R} to finish:\n"
  local line n=0
  while true; do
    printf "  Node ID #%d: " "$((n+1))"
    read -r line || break
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && break
    printf '%s\n' "$line" >> "$INPUT_FILE"
    n=$((n+1))
  done
  [ "$n" -eq 0 ] && { err "No Node IDs entered."; return 1; }
  return 0
}

collect_one_key() {
  : > "$INPUT_FILE"
  echo
  printf "Paste your ${B}private key${R} (64-char hex, no 0x). Input is ${B}hidden${R}:\n"
  printf "  NODE_PRIV_KEY: "
  local k; read -rs k; echo
  k="$(printf '%s' "$k" | tr -d '[:space:]')"
  [ -z "$k" ] && { err "No key entered."; return 1; }
  printf '%s\n' "$k" >> "$INPUT_FILE"
  unset k
  return 0
}

collect_batch_keys() {
  : > "$INPUT_FILE"
  echo
  printf "${B}Batch mode:${R} paste your private keys ${B}one per line${R} (hidden).\n"
  printf "Press ${B}Enter on an empty line${R} to finish.\n"
  local k n=0
  while true; do
    printf "  Key #%d: " "$((n+1))"
    read -rs k; echo
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    [ -z "$k" ] && break
    printf '%s\n' "$k" >> "$INPUT_FILE"
    n=$((n+1))
  done
  unset k
  [ "$n" -eq 0 ] && { err "No keys entered."; return 1; }
  printf "${DIM}Collected %d key(s).${R}\n" "$n"
  return 0
}

# ==========================================================================
# Menu
# ==========================================================================
show_menu() {
  printf "\n${MAG}${B}"
  printf "  ╔══════════════════════════════╗\n"
  printf "  ║      NESA REWARDS CHECKER     ║\n"
  printf "  ╚══════════════════════════════╝${R}\n"
  printf "  ${B}1${R}) ${CYN}Node ID checker${R}          ${DIM}- by Node ID, no key needed${R}\n"
  printf "  ${B}2${R}) ${CYN}Private key checker${R}      ${DIM}- one private key${R}\n"
  printf "  ${B}3${R}) ${CYN}Batch private key checker${R}${DIM}- many keys at once${R}\n"
  printf "  ${B}q${R}) ${DIM}Quit${R}\n"
}

echo
printf "${DIM}Preparing... (first run installs dependencies)${R}\n"
setup

while true; do
  show_menu
  printf "\n${B}Choose an option:${R} "
  read -r choice || break
  case "$choice" in
    1) if collect_node_ids;   then "$PYTHON" "$RUNNER_PY" nodeid "$INPUT_FILE"; fi ;;
    2) if collect_one_key;    then "$PYTHON" "$RUNNER_PY" key    "$INPUT_FILE"; fi ;;
    3) if collect_batch_keys; then "$PYTHON" "$RUNNER_PY" batch  "$INPUT_FILE"; fi ;;
    q|Q|quit|exit) break ;;
    *) err "Invalid choice: $choice" ;;
  esac
  : > "$INPUT_FILE"  # wipe sensitive input after each run
  echo
  printf "${DIM}Press Enter to return to the menu...${R}"; read -r _ || break
done

echo
printf "${GRN}Done. Temporary files securely removed.${R}\n"
