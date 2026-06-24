#!/usr/bin/env bash
#
# recover-nesa-key-from-seed.sh
# -----------------------------
# You lost your Nesa node private key but still have your wallet seed phrase
# (BIP39 mnemonic) and you know your Node ID.
#
# This script derives candidate secp256k1 private keys from your seed across
# common derivation paths, computes the Nesa Node ID for each (using the EXACT
# official nesaorg/miner-rewards-cli logic), and finds the one that matches
# your Node ID. If found, it shows the recovered private key and checks your
# rewards allocation. It NEVER submits a claim.
#
# IMPORTANT: this only works if your node key was derived from this wallet.
# If the node generated its own random key, no derivation path will match.
#
# Usage:
#   bash recover-nesa-key-from-seed.sh
#
set -euo pipefail

APP_NAME="nesa-key-recovery"
VENV_DIR="${REWARDS_CLI_VENV:-$HOME/.cache/$APP_NAME/venv}"
OFFICIAL_URL="https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/main/claim-rewards.sh"

DEPS=(
  "requests==2.32.3"
  "coincurve==20.0.0"
  "bech32==1.2.0"
  "cryptography==43.0.3"
  "base58==2.1.1"
  "bip_utils>=2.9.0"
)

err()      { echo "Error: $*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! have_cmd python3; then err "python3 is required but was not found."; exit 1; fi
if ! have_cmd curl;    then err "curl is required but was not found.";    exit 1; fi

WORKDIR="$(mktemp -d)"; chmod 700 "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

OFFICIAL_SH="$WORKDIR/claim-rewards.sh"
MODULE_PY="$WORKDIR/nesa_cli.py"

# --- venv + deps ----------------------------------------------------------
if [ ! -d "$VENV_DIR" ]; then
  echo "Setting up environment at $VENV_DIR ..."
  python3 -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

if ! "$PYTHON" - <<'PY_CHECK' >/dev/null 2>&1
import requests, coincurve, bech32, base58, bip_utils
from cryptography.hazmat.primitives.asymmetric import ed25519
PY_CHECK
then
  echo "Installing dependencies ..."
  "$PIP" install --quiet --upgrade pip
  "$PIP" install --quiet "${DEPS[@]}"
fi

# --- download official script and extract its functions -------------------
echo "Downloading official Nesa CLI (for exact identity logic) ..."
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

# --- collect inputs -------------------------------------------------------
echo
printf "Enter your Node ID (e.g. 8UTbwzv...): "
read -r TARGET_NODE_ID
TARGET_NODE_ID="$(printf '%s' "$TARGET_NODE_ID" | tr -d '[:space:]')"
if [ -z "$TARGET_NODE_ID" ]; then err "Node ID is required."; exit 1; fi

echo
echo "Paste your wallet seed phrase (12/24 words). Input is HIDDEN."
echo "It is used locally only and never leaves this machine."
printf "Seed phrase: "
read -rs MNEMONIC
echo

# --- run recovery ---------------------------------------------------------
TARGET_NODE_ID="$TARGET_NODE_ID" MNEMONIC="$MNEMONIC" MODULE_PY="$MODULE_PY" "$PYTHON" - <<'PY_DRIVER'
import importlib.util, json, os, sys
from decimal import Decimal

module_path = os.environ["MODULE_PY"]
target = os.environ["TARGET_NODE_ID"].strip()
mnemonic = " ".join(os.environ["MNEMONIC"].split())

spec = importlib.util.spec_from_file_location("nesa_cli", module_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

from bip_utils import Bip39SeedGenerator, Bip39MnemonicValidator, Bip32Slip10Secp256k1

def banner(t):
    line = "=" * max(8, len(t) + 4)
    print(f"\n{line}\n  {t}\n{line}")

# validate mnemonic
try:
    Bip39MnemonicValidator().Validate(mnemonic)
except Exception:
    print("\nError: that seed phrase failed BIP39 checksum validation.", file=sys.stderr)
    print("Double-check the words, their order, and spelling.", file=sys.stderr)
    sys.exit(1)

seed_bytes = Bip39SeedGenerator(mnemonic).Generate()
bip32 = Bip32Slip10Secp256k1.FromSeed(seed_bytes)

# coin types to try: cosmos(118), eth(60), btc(0), secret(529), terra(330),
# kava(459), band(494), osmosis uses 118. Extend via env NESA_EXTRA_COINS.
coins = [118, 60, 0, 529, 330, 459, 494]
extra = os.environ.get("NESA_EXTRA_COINS", "").replace(",", " ").split()
for c in extra:
    try: coins.append(int(c))
    except ValueError: pass

banner("Searching derivation paths")
print(f"Target Node ID: {target}")
print("Trying common BIP44 paths across multiple coin types...")

checked = 0
found = None
for coin in coins:
    for acc in range(5):       # account 0..4
        for change in (0, 1):  # external / internal
            for idx in range(10):  # address index 0..9
                path = f"m/44'/{coin}'/{acc}'/{change}/{idx}"
                try:
                    node = bip32.DerivePath(path)
                    ph = node.PrivateKey().Raw().ToHex()
                except Exception:
                    continue
                checked += 1
                nid = m.derive_node_identity_from_private_key_hex(ph)["node_id"]
                if nid == target:
                    found = (path, ph)
                    break
            if found: break
        if found: break
    if found: break

print(f"Checked {checked} candidate keys.")

if not found:
    banner("No match")
    print("None of the tried derivation paths produced your Node ID.")
    print("Most likely your node generated its own random key (not derived")
    print("from this wallet), OR a different/longer derivation path was used.")
    print("\nYou can widen the search with extra coin types, e.g.:")
    print("  NESA_EXTRA_COINS='234 564 818' bash recover-nesa-key-from-seed.sh")
    sys.exit(2)

path, priv_hex = found
pk = m.PrivateKey(bytes.fromhex(priv_hex))
cosmos = m.cosmos_address_from_private_key(pk, m.DEFAULT_BECH32_PREFIX)

banner("MATCH FOUND")
print(f"Derivation path:   {path}")
print(f"Cosmos address:    {cosmos}")
print(f"Node / miner ID:   {target}")
print(f"\nRecovered NODE_PRIV_KEY (keep this SECRET):\n{priv_hex}")
print("\nSave it for the official CLI like this:")
print('  mkdir -p ~/.nesa/env')
print(f'  echo \'NODE_PRIV_KEY="{priv_hex}"\' > ~/.nesa/env/orchestrator.env')

# --- read-only allocation check ------------------------------------------
banner("Checking allocation")
try:
    resp = m.get_json(
        m.DEFAULT_ALLOCATION_ENDPOINT,
        params={"cosmos_address": cosmos, "node_id": target},
    )
    try:
        amount = m.extract_allocation_amount(resp)
    except Exception:
        amount = Decimal("0")
    print(m.allocation_display_line(resp))
    if m.allocation_claimed(resp):
        print("This allocation has ALREADY been claimed.")
    elif amount <= Decimal("0"):
        print("No claimable allocation found for this identity.")
    else:
        print(f"\nClaimable allocation: {m.allocation_display_line(resp)}")
        print("This script does NOT claim. To claim, run the official CLI with the key above:")
        print("  bash <(curl -fsSL https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/main/claim-rewards.sh)")
except m.CliError as exc:
    print(f"Allocation check error: {exc}", file=sys.stderr)
PY_DRIVER

echo
echo "Done. (Seed and recovered key were only used locally.)"
