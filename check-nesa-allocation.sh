#!/usr/bin/env bash
#
# check-nesa-allocation.sh  --  Nesa Rewards Checker & Claimer (interactive TUI)
# -----------------------------------------------------------------------------
# A single all-in-one tool with a terminal menu. Choose:
#
#   1) Node ID checker           - check allocation by Node ID (no key needed)
#   2) Private key checker        - check allocation from one private key
#   3) Batch private key checker  - paste many private keys, check them all
#   4) Match keys to node IDs     - find which key unlocks each eligible node ID
#   5) Recover key from seed      - search a BIP39 seed for the node's private key
#   6) Claim rewards              - submit a real claim via the official Nesa CLI
#
# Options 1-4 are READ-ONLY: they NEVER submit a claim. Option 5 hands off to
# the official nesaorg/miner-rewards-cli so derived identities & signing match
# exactly, and only ever runs it INTERACTIVELY (it asks you to confirm Terms).
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
  "bip-utils==2.9.3"
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
import requests, coincurve, bech32, base58, bip_utils
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

def looks_like_hex_key(s):
    """True if the string looks like a 64-char hex private key (with/without 0x)."""
    t = s[2:] if s.lower().startswith("0x") else s
    return len(t) == 64 and all(ch in "0123456789abcdefABCDEF" for ch in t)

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

def read_items(path):
    return [ln.strip() for ln in open(path, encoding="utf-8") if ln.strip()]

def main():
    mode = sys.argv[1]
    results = []

    if mode == "nodeid":
        banner("Node ID checker")
        for nid in read_items(sys.argv[2]):
            # Guard: catch the common mistake of pasting a private key here.
            if looks_like_hex_key(nid):
                print(f"  {RED}\u2717{R} {nid}")
                print(f"     {YEL}This looks like a PRIVATE KEY, not a Node ID.{R}")
                print(f"     {DIM}Use option 2 (Private key) or 3 (Batch) for keys instead.{R}")
                results.append({"ok": False, "node_id": nid, "error": "looks like a private key", "claimed": None, "nes": None})
                continue
            res = query(nid, PLACEHOLDER_ADDR)
            print_result(res, label=nid)
            results.append(res)

    elif mode in ("key", "batch"):
        banner("Private key checker" if mode == "key" else "Batch private key checker")
        for idx, hexkey in enumerate(read_items(sys.argv[2]), 1):
            try:
                node_id, cosmos = from_key(hexkey)
            except ValueError as e:
                print(f"  {RED}\u2717{R} key #{idx}  {DIM}{e}{R}")
                results.append({"ok": False, "node_id": f"key#{idx}", "error": str(e), "claimed": None, "nes": None})
                continue
            res = query(node_id, cosmos)
            if mode == "key":
                print(f"  {DIM}Cosmos:{R} {cosmos}")
                print(f"  {DIM}Node ID:{R} {node_id}")
            # FIX: always show the FULL derived node_id (no truncation) so it can
            # be compared against your eligible list.
            print_result(res, label=node_id)
            results.append(res)

    elif mode == "match":
        banner("Match keys to eligible node IDs")
        eligible, keys = [], []
        for ln in open(sys.argv[2], encoding="utf-8"):
            ln = ln.rstrip("\n")
            if not ln.strip():
                continue
            tag, _, val = ln.partition(" ")
            val = val.strip()
            if tag == "N":
                eligible.append(val)
            elif tag == "K":
                keys.append(val)
        eligible_set = set(eligible)
        matched_ids = set()
        for idx, hexkey in enumerate(keys, 1):
            try:
                node_id, cosmos = from_key(hexkey)
            except ValueError as e:
                print(f"  {RED}\u2717{R} key #{idx}  {DIM}{e}{R}")
                continue
            if node_id in eligible_set:
                matched_ids.add(node_id)
                res = query(node_id, cosmos)
                print(f"  {GRN}\u2713 MATCH{R}  key #{idx}  ->  {B}{node_id}{R}")
                print_result(res, label=node_id)
            else:
                print(f"  {DIM}\u2014 no match  key #{idx}  ->  {node_id}{R}")
        banner("Match summary")
        print(f"  Eligible node IDs: {len(eligible_set)}")
        print(f"  Matched with a key: {len(matched_ids)}")
        unmatched = [n for n in eligible if n not in matched_ids]
        if unmatched:
            print(f"  {YEL}Still missing the key for:{R}")
            for nid in unmatched:
                print(f"    - {nid}")
        else:
            print(f"  {GRN}All eligible node IDs were matched to a key!{R}")
        return

    elif mode == "seed":
        from bip_utils import (Bip39SeedGenerator, Bip39MnemonicValidator,
                               Bip32Slip10Secp256k1)
        banner("Recover node key from seed")
        targets, mnemonic = [], None
        for ln in open(sys.argv[2], encoding="utf-8"):
            ln = ln.rstrip("\n")
            if not ln.strip():
                continue
            tag, _, val = ln.partition(" ")
            val = val.strip()
            if tag == "T":
                targets.append(val)
            elif tag == "S":
                mnemonic = val
        targets = list(dict.fromkeys(targets))  # de-dupe, keep order
        if not mnemonic or not targets:
            print(f"{RED}Need a seed phrase and at least one node ID.{R}"); return
        if not Bip39MnemonicValidator().IsValid(mnemonic):
            print(f"{RED}That seed phrase is not a valid BIP39 mnemonic.{R}")
            print(f"{DIM}Check the words/spelling/order (12 or 24 words).{R}"); return

        passphrase = os.environ.get("NESA_BIP39_PASSPHRASE", "")
        seed_bytes = Bip39SeedGenerator(mnemonic).Generate(passphrase)

        base_coins = [118, 60, 0, 529, 330, 459, 494]
        extra = [int(x) for x in os.environ.get("NESA_EXTRA_COINS", "").split() if x.isdigit()]
        coins = base_coins + [c for c in extra if c not in base_coins]
        n_acct = int(os.environ.get("NESA_ACCOUNTS", "8"))
        n_idx  = int(os.environ.get("NESA_INDEXES", "30"))

        print(f"  {DIM}Targets: {len(targets)} | coin types: {coins}{R}")
        print(f"  {DIM}Scanning accounts 0-{n_acct-1}, change 0/1, index 0-{n_idx-1}...{R}")

        remaining = set(targets)
        found = {}
        tried = 0
        for coin in coins:
            if not remaining:
                break
            for a in range(n_acct):
                if not remaining:
                    break
                for ch in (0, 1):
                    if not remaining:
                        break
                    for i in range(n_idx):
                        path = f"m/44'/{coin}'/{a}'/{ch}/{i}"
                        k = Bip32Slip10Secp256k1.FromSeedAndPath(seed_bytes, path).PrivateKey().Raw().ToBytes().hex()
                        tried += 1
                        nid = m.derive_node_identity_from_private_key_hex(k)["node_id"]
                        if nid in remaining:
                            found[nid] = (path, k)
                            remaining.discard(nid)
                            if not remaining:
                                break
        print(f"  {DIM}Derivations tried: {tried}{R}\n")

        for nid in targets:
            if nid in found:
                path, k = found[nid]
                cosmos = m.cosmos_address_from_private_key(m.PrivateKey(bytes.fromhex(k)), m.DEFAULT_BECH32_PREFIX)
                res = query(nid, cosmos)
                print(f"  {GRN}\u2713 FOUND{R}  {B}{nid}{R}")
                print(f"     {DIM}path:{R}   {path}")
                print(f"     {DIM}cosmos:{R} {cosmos}")
                print(f"     {RED}{B}PRIVATE KEY:{R} {k}")
                print_result(res, label=nid)
            else:
                print(f"  {RED}\u2717 not found{R}  {nid}  {DIM}(no derivation path from this seed){R}")

        if found:
            print(f"\n{YEL}{B}Keep that PRIVATE KEY secret.{R} {DIM}Use it with option 6 (Claim) to withdraw.{R}")
        if remaining:
            print(f"\n{DIM}Couldn't match {len(remaining)} ID(s). Widen the search and retry, e.g.:{R}")
            print(f"{DIM}  NESA_ACCOUNTS=16 NESA_INDEXES=60 NESA_EXTRA_COINS='234 564 818' bash check-nesa-allocation.sh{R}")
        return
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
        print(f"\n{DIM}This tool only CHECKS allocations. To claim, pick option 5 in the menu{R}")
        print(f"{DIM}(or run the official CLI directly).{R}")

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

collect_match() {
  : > "$INPUT_FILE"
  echo
  printf "${B}Match mode:${R} discover which private key unlocks each eligible node ID.\n"
  printf "${B}Step 1${R} - paste your ${B}eligible Node IDs${R} (one per line). Empty line to finish:\n"
  local line n=0
  while true; do
    printf "  Node ID #%d: " "$((n+1))"
    read -r line || break
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && break
    printf 'N %s\n' "$line" >> "$INPUT_FILE"
    n=$((n+1))
  done
  [ "$n" -eq 0 ] && { err "No node IDs entered."; return 1; }
  echo
  printf "${B}Step 2${R} - paste your ${B}private keys${R} (64-hex, hidden, one per line). Empty line to finish:\n"
  local k mm=0
  while true; do
    printf "  Key #%d: " "$((mm+1))"
    read -rs k; echo
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    [ -z "$k" ] && break
    printf 'K %s\n' "$k" >> "$INPUT_FILE"
    mm=$((mm+1))
  done
  unset k
  [ "$mm" -eq 0 ] && { err "No keys entered."; return 1; }
  printf "${DIM}Collected %d node ID(s) and %d key(s).${R}\n" "$n" "$mm"
  return 0
}

collect_seed() {
  : > "$INPUT_FILE"
  echo
  printf "${B}Seed recovery:${R} find the private key (from your seed phrase) that built\n"
  printf "an eligible node ID. ${B}Everything stays local.${R}\n"
  printf "${B}Step 1${R} - paste the ${B}eligible Node ID(s)${R} you want the key for (one per line).\n"
  printf "Press ${B}Enter on an empty line${R} to finish:\n"
  local line n=0
  while true; do
    printf "  Node ID #%d: " "$((n+1))"
    read -r line || break
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && break
    printf 'T %s\n' "$line" >> "$INPUT_FILE"
    n=$((n+1))
  done
  [ "$n" -eq 0 ] && { err "No node IDs entered."; return 1; }
  echo
  printf "${B}Step 2${R} - paste your ${B}seed phrase${R} (12/24 words, space-separated). Input is ${B}hidden${R}:\n"
  printf "  SEED: "
  local s; read -rs s; echo
  # collapse extra whitespace, trim ends
  s="$(printf '%s' "$s" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')"
  [ -z "$s" ] && { err "No seed entered."; return 1; }
  printf 'S %s\n' "$s" >> "$INPUT_FILE"
  unset s
  printf "${DIM}Collected %d node ID(s) + seed. Searching may take a few seconds...${R}\n" "$n"
  return 0
}

# ==========================================================================
# Claim (hands off to the official Nesa CLI, interactive & confirmed)
# ==========================================================================
do_claim() {
  echo
  printf "${YEL}${B}  CLAIM MODE  ${R}\n"
  printf "${YEL}This SUBMITS a real on-chain claim. Your reward is sent to an EVM address you pick.${R}\n"
  printf "${DIM}It runs the official Nesa CLI interactively - you still confirm the Terms there.${R}\n\n"

  printf "Paste the ${B}private key${R} of the node to claim (64-hex, no 0x). Input is ${B}hidden${R}:\n"
  printf "  NODE_PRIV_KEY: "
  local k; read -rs k; echo
  k="$(printf '%s' "$k" | tr -d '[:space:]')"
  k="${k#0x}"
  [ -z "$k" ] && { err "No key entered."; return 1; }
  if ! printf '%s' "$k" | grep -qiE '^[0-9a-f]{64}$'; then
    err "Not a valid 64-char hex private key."; unset k; return 1
  fi

  local keyenv="$WORKDIR/claim.env"
  ( umask 077; printf 'NODE_PRIV_KEY="%s"\n' "$k" > "$keyenv" )
  unset k

  printf "\nEnter the ${B}EVM address${R} to receive the reward (0x...),\n"
  printf "or leave ${B}empty${R} to let the official CLI ask you:\n"
  printf "  EVM address: "
  local evm; read -r evm || true
  evm="$(printf '%s' "$evm" | tr -d '[:space:]')"

  echo
  printf "${YEL}Launching official Nesa claim CLI (interactive)...${R}\n"
  # NOTE: we never pass -y, so the official CLI always prompts for confirmation.
  if [ -n "$evm" ]; then
    bash "$OFFICIAL_SH" --private-key-path "$keyenv" --evm-address "$evm" || true
  else
    bash "$OFFICIAL_SH" --private-key-path "$keyenv" || true
  fi

  rm -f "$keyenv"
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
  printf "  ${B}4${R}) ${CYN}Match keys to node IDs${R}   ${DIM}- which key unlocks which node${R}\n"
  printf "  ${B}5${R}) ${CYN}Recover key from seed${R}    ${DIM}- find the node key from your seed phrase${R}\n"
  printf "  ${B}6${R}) ${GRN}Claim rewards${R}            ${DIM}- submit a real claim (official CLI)${R}\n"
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
    4) if collect_match;      then "$PYTHON" "$RUNNER_PY" match  "$INPUT_FILE"; fi ;;
    5) if collect_seed;       then "$PYTHON" "$RUNNER_PY" seed   "$INPUT_FILE"; fi ;;
    6) do_claim || true ;;
    q|Q|quit|exit) break ;;
    *) err "Invalid choice: $choice" ;;
  esac
  : > "$INPUT_FILE"  # wipe sensitive input after each run
  echo
  printf "${DIM}Press Enter to return to the menu...${R}"; read -r _ || break
done

echo
printf "${GRN}Done. Temporary files securely removed.${R}\n"
