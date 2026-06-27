# Nesa Allocation Checker

A single interactive terminal tool to check your **Nesa miner rewards allocation** — and now to **claim** them too. Checking is read-only; claiming hands off to the official CLI and always asks you to confirm.

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
  4) Match keys to node IDs   - which key unlocks which node
  5) Recover key from seed    - find the node key from your seed phrase
  6) Claim rewards            - submit a real claim (official CLI)
  q) Quit
```

### 1) Node ID checker
Enter one or more Node IDs (one per line). Checks allocation without any private key. If you accidentally paste a 64-char hex **private key** here, the tool detects it and tells you to use option 2/3 instead.

### 2) Private key checker
Paste a single node private key (64-char hex, no `0x`, hidden input). Derives your Cosmos address + Node ID locally, then shows your allocation.

### 3) Batch private key checker
Paste many private keys, one per line (hidden). The tool checks them all and prints a per-key result (with the **full** derived Node ID so you can compare it against your eligible list) plus a **summary** with total and still-claimable NES.

### 4) Match keys to node IDs
Don't know which key belongs to which eligible node? Paste your **eligible Node IDs** first, then your **private keys** (hidden). The tool derives each key's Node ID and tells you exactly which key unlocks which eligible node — and which eligible nodes you're still missing a key for.

### 5) Recover key from seed
Lost the node's private key but still have your **seed phrase**? Paste your eligible Node ID(s), then your seed phrase (12/24 words, hidden). The tool scans standard BIP39/BIP32 derivation paths (coin types 118/60/0/529/330/459/494, accounts and indexes) and, for any path whose derived key reproduces an eligible Node ID, prints the **exact private key**, derivation path, Cosmos address and allocation. Everything runs locally.

Widen the search if needed:
```bash
NESA_ACCOUNTS=16 NESA_INDEXES=60 NESA_EXTRA_COINS='234 564 818' bash check-nesa-allocation.sh
```
Optional BIP39 passphrase (25th word): `NESA_BIP39_PASSPHRASE='...'`.

### 6) Claim rewards
Submits a **real on-chain claim** by handing off to the official Nesa CLI. You paste the node's private key (hidden) and the EVM address to receive the reward. It runs the official CLI **interactively** (never with `-y`), so you still confirm the Terms and the claim yourself before anything is submitted.

Options 1–4 are read-only and retry automatically on transient server errors.

## Security
- Private keys are used **locally only**, kept in a temp file (`umask 077`) that is wiped after each run and deleted on exit.
- Read-only modes only send allocation queries to `rewards-proxy.nesa.ai`.
- Claiming uses the official `nesaorg/miner-rewards-cli` and signs locally; your key is never uploaded.
- **Never share your private keys or seed phrase with anyone.** Run this only on a machine you trust.

---
*Not affiliated with Nesa. Use at your own risk.*
