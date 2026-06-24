# Nesa Allocation Checker

Check your **Nesa miner rewards allocation** using only your previously saved node private key.
No server/node needed. **Read-only — it never submits a claim.**

It reuses the official [`nesaorg/miner-rewards-cli`](https://github.com/nesaorg/miner-rewards-cli) crypto/identity logic, so the derived identity matches exactly, but stops right after showing your allocation.

## Requirements
- `python3` and `curl` (the script auto-installs its Python deps in an isolated venv)

## Clone
```bash
git clone https://github.com/reza7277/nesa-allocation-checker.git
cd nesa-allocation-checker
```

## Run
```bash
bash check-nesa-allocation.sh
```
When prompted, paste your node private key (64-char hex, no `0x` prefix). Input is hidden.

The script will:
1. Derive your Cosmos address + Node/miner ID from the key (locally).
2. Query the official Nesa rewards endpoint and print your allocation (aNES + NES).
3. Stop — **nothing is claimed.**

## Security
- Your private key is used **locally only** and stored in a temp file that is auto-deleted on exit.
- Only a **read-only** allocation query is sent to `rewards-proxy.nesa.ai`.
- **Never share your private key or mnemonic with anyone.** Run this only on a machine you trust.

## Want to actually claim?
Use the official CLI:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/main/claim-rewards.sh)
```

---
*Not affiliated with Nesa. Use at your own risk.*
