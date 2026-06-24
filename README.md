# Nesa Allocation Checker

A single interactive terminal tool to check your **Nesa miner rewards allocation**. **Read-only — it never submits a claim.**

Reuses the official [`nesaorg/miner-rewards-cli`](https://github.com/nesaorg/miner-rewards-cli) logic, so derived identities and results match exactly.

## Requirements
- `python3` and `curl` (deps auto-install in an isolated venv on first run)

## Clone & run
```bash
git clone https://github.com/reza7277/nesa-allocation-checker.git
cd nesa-allocation-checker
bash check-nesa-allocation.sh
```

You'll get a terminal menu:

```
  ╔══════════════════════════════╗
  ║      NESA REWARDS CHECKER     ║
  ╚══════════════════════════════╝
  1) Node ID checker          - by Node ID, no key needed
  2) Private key checker      - one private key
  3) Batch private key checker- many keys at once
  q) Quit
```

### 1) Node ID checker
Enter one or more Node IDs (one per line). Checks allocation without any private key.

### 2) Private key checker
Paste a single node private key (64-char hex, no `0x`, hidden input). Derives your Cosmos address + Node ID locally, then shows your allocation.

### 3) Batch private key checker
Paste many private keys, one per line (hidden). The tool checks them all and prints a per-key result plus a **summary** with total and still-claimable NES.

All modes are read-only and retry automatically on transient server errors.

## Security
- Private keys are used **locally only**, kept in a temp file that is wiped after each run and deleted on exit.
- Only **read-only** allocation queries are sent to `rewards-proxy.nesa.ai`.
- **Never share your private keys or seed phrase with anyone.** Run this only on a machine you trust.

## Want to actually claim?
Use the official CLI:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/main/claim-rewards.sh)
```

---
*Not affiliated with Nesa. Use at your own risk.*
