# Nesa Allocation Checker

Tools to check your **Nesa miner rewards allocation** using your saved node private key — or, if you lost the key, recover it from your wallet seed phrase. **Read-only — nothing here ever submits a claim.**

Both scripts reuse the official [`nesaorg/miner-rewards-cli`](https://github.com/nesaorg/miner-rewards-cli) crypto/identity logic, so derived identities match exactly.

## Requirements
- `python3` and `curl` (scripts auto-install their Python deps in an isolated venv)

## Clone
```bash
git clone https://github.com/reza7277/nesa-allocation-checker.git
cd nesa-allocation-checker
```

---

## 1. Check allocation (you have your private key)
```bash
bash check-nesa-allocation.sh
```
Paste your node private key (64-char hex, no `0x`). It derives your Cosmos address + Node ID, prints your allocation (aNES + NES), and stops. No claim.

---

## 2. Recover key from seed (you lost the private key)
If you lost `NODE_PRIV_KEY` but still have your **wallet seed phrase** and know your **Node ID**:
```bash
bash recover-nesa-key-from-seed.sh
```
It asks for your Node ID and seed phrase (hidden input), derives candidate keys across common BIP44 paths / coin types, and finds the one whose derived Node ID matches yours. On a match it prints the recovered private key and checks your allocation.

Widen the search with extra coin types if needed:
```bash
NESA_EXTRA_COINS='234 564 818' bash recover-nesa-key-from-seed.sh
```

**Caveat:** this only works if your node key was derived from this wallet. If the node generated its own random key, no derivation path will match.

---

## Security
- Your private key / seed are used **locally only** and stored in a temp file that is auto-deleted on exit.
- Only a **read-only** allocation query is sent to `rewards-proxy.nesa.ai`.
- A **seed phrase is even more sensitive than a private key** — it controls your whole wallet. **Never share it with anyone.** Run these scripts only on a machine you fully trust.

## Want to actually claim?
Use the official CLI with your key:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/main/claim-rewards.sh)
```

---
*Not affiliated with Nesa. Use at your own risk.*
