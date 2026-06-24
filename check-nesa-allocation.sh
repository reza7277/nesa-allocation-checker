#!/usr/bin/env bash
#
# check-nesa-allocation.sh
# ------------------------
# Prompts for your previous Nesa node private key, then checks ONLY your
# rewards allocation from the official nesaorg/miner-rewards-cli.
#
# It does NOT submit a claim. It reuses the official script's crypto/identity
# logic (so derivation matches exactly), but stops right after showing the
# allocation. Nothing is ever sent except the read-only allocation query.
#
# Usage:
#   bash check-nesa-allocation.sh
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

err()      { echo "Error: $*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- prerequisites --------------------------------------------------------
if ! have_cmd python3; then err "python3 is required but was not found."; exit 1; fi
if ! have_cmd curl;    then err "curl is required but was not found.";    exit 1; fi

# --- temp workspace (auto-cleaned) ---------------------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
chmod 700 "$WORKDIR"

OFFICIAL_SH="$WORKDIR/claim-rewards.sh"
MODULE_PY="$WORKDIR/nesa_cli.py"
ENV_FILE="$WORKDIR/orchestrator.env"

# --- python venv + deps (mirrors the official bootstrap) ------------------
if [ ! -d "$VENV_DIR" ]; then
  echo "Setting up environment at $VENV_DIR ..."
  python3 -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

if ! "$PYTHON" - <<'PY_CHECK' >/dev/null 2>&1
import requests, coincurve, bech32, base58
from cryptography.hazmat.primitives.asymmetric import ed25519
PY_CHECK
then
  echo "Installing dependencies ..."
  "$PIP" install --quiet --upgrade pip
  "$PIP" install --quiet "${DEPS[@]}"
fi

# --- download official script and extract its Python payload --------------
echo "Downloading official Nesa CLI ..."
curl -fsSL "$OFFICIAL_URL" -o "$OFFICIAL_SH"

# Extract everything inside the  <<'PY_APP' ... PY_APP  heredoc, but stop
# before the `if __name__ == "__main__":` guard so importing it does NOT run
# the interactive claim flow. We only want its functions.
awk '
  /<<'\''PY_APP'\''/ { capture=1; next }
  capture && /^if __name__ == "__main__":/ { exit }
  capture { print }
' "$OFFICIAL_SH" > "$MODULE_PY"

if [ ! -s "$MODULE_PY" ]; then
  err "Could not extract the Python logic from the official script (format may have changed)."
  exit 1
fi

# --- prompt for the private key (hidden input) ----------------------------
echo
echo "Paste your previous node private key (64-char hex, no 0x prefix)."
echo "Input is hidden and stored only in a temp file that is deleted on exit."
printf "NODE_PRIV_KEY: "
read -rs NODE_PRIV_KEY
echo

# strip optional 0x and surrounding whitespace/quotes
NODE_PRIV_KEY="$(printf '%s' "$NODE_PRIV_KEY" | tr -d '[:space:]"'"'"'' )"
NODE_PRIV_KEY="${NODE_PRIV_KEY#0x}"

if ! printf '%s' "$NODE_PRIV_KEY" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  err "That does not look like a 64-character hex private key. Aborting."
  exit 1
fi

umask 077
printf 'NODE_PRIV_KEY="%s"\n' "$NODE_PRIV_KEY" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
unset NODE_PRIV_KEY

# --- run the check-only driver -------------------------------------------
ENV_FILE="$ENV_FILE" MODULE_PY="$MODULE_PY" "$PYTHON" - <<'PY_DRIVER'
import importlib.util, json, os, sys
from decimal import Decimal

module_path = os.environ["MODULE_PY"]
env_path    = os.environ["ENV_FILE"]

spec = importlib.util.spec_from_file_location("nesa_cli", module_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)  # defines functions only; no claim flow runs

def banner(t):
    line = "=" * max(8, len(t) + 4)
    print(f"\n{line}\n  {t}\n{line}")

try:
    private_key, private_key_hex = m.load_private_key(env_path)
    cosmos = m.cosmos_address_from_private_key(private_key, m.DEFAULT_BECH32_PREFIX)
    node_identity = m.derive_node_identity_from_private_key_hex(private_key_hex)
    node_id = node_identity["node_id"]

    banner("Miner identity detected")
    print(f"Cosmos address:  {cosmos}")
    print(f"Node / miner ID: {node_id}")

    banner("Checking allocation")
    resp = m.get_json(
        m.DEFAULT_ALLOCATION_ENDPOINT,
        params={"cosmos_address": cosmos, "node_id": node_id},
    )

    try:
        amount = m.extract_allocation_amount(resp)
    except Exception:
        amount = Decimal("0")

    print(m.allocation_display_line(resp))

    if m.allocation_claimed(resp):
        prev = None
        try:
            prev = m.extract_previous_claim(resp)
        except Exception:
            pass
        banner("Result")
        print("This allocation has ALREADY been claimed.")
        if prev:
            print(json.dumps(prev, indent=2))
    elif amount <= Decimal("0"):
        banner("Result")
        print("No claimable allocation found for this miner identity.")
    else:
        banner("Result")
        print(f"You have a claimable allocation: {m.allocation_display_line(resp)}")
        print("\nThis script only CHECKS the allocation and does not claim it.")
        print("To actually claim, run the official script:")
        print("  bash <(curl -fsSL "
              "https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/main/claim-rewards.sh)")

except m.CliError as exc:
    body = getattr(exc, "body", None)
    print(f"\nError: {exc}", file=sys.stderr)
    if isinstance(body, dict):
        print(json.dumps(body, indent=2), file=sys.stderr)
    sys.exit(1)
PY_DRIVER

echo
echo "Done. Temp key file will be securely removed now."
