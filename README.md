# Nesa Allocation Checker

An interactive terminal tool to check a Nesa miner allocation and submit it through Nesa's **official alternate-key claim method**.

This repository was updated for Nesa's July 2026 fix for miners whose allocated Node ID differs from the Node ID that the original claim CLI derives from `NODE_PRIV_KEY`.

## Why the old method failed

Some Nesa installations generated and stored a Node ID independently from the secp256k1 private key in `orchestrator.env`. Reinstalling could also leave miners with an allocated Node ID and a different signing identity. The original CLI derived a new Node ID from the private key, queried that different ID, and incorrectly appeared to show no allocation.

Nesa's alternate method fixes this by treating the two proofs separately:

1. You provide the **actual Miner ID / Node ID** that has the allocation.
2. You provide the **secp256k1 private key** that signed the node's latest miner requests/heartbeats.
3. Nesa verifies the derived compressed public key against its registered key for that Node ID.

The private key does not need to reproduce the Node ID.

Official sources:

- [Nesa alternate-key CLI branch](https://github.com/nesaorg/miner-rewards-cli/tree/alternate-key-cli#alternate-claim)
- [Official alternate claim script](https://github.com/nesaorg/miner-rewards-cli/blob/alternate-key-cli/claim-rewards-alt.sh)
- [Original identity mismatch report and confirmed resolution](https://github.com/nesaorg/miner-rewards-cli/issues/1)

## Requirements

- Linux or another Bash-compatible environment
- `bash`, `curl`, and `python3`
- Internet access to GitHub and `rewards-proxy.nesa.ai`

The official Nesa claim CLI creates its own Python virtual environment and installs its pinned Python dependencies on first use.

## Install and run

```bash
git clone https://github.com/reza7277/nesa-allocation-checker.git
cd nesa-allocation-checker
bash check-nesa-allocation.sh
```

Menu:

```text
  1) Check allocation   - Node ID only, read-only
  2) Claim allocation   - fixed alternate-key method
  q) Quit
```

## Check an allocation

Choose option 1 and enter one or more Node IDs. This is read-only and does not ask for a private key. Only the Node IDs are sent to Nesa's official allocation endpoint.

## Claim an allocation

Choose option 2 and enter:

1. The exact Node ID that shows an allocation.
2. The alternate `NODE_PRIV_KEY` used to sign that node's requests (input is hidden).
3. A destination EVM address, or leave it empty and enter it in the official CLI.

The wrapper then launches Nesa's official alternate-key CLI interactively. It never passes `-y`, so you must verify the displayed Node ID/public key, accept the Terms, and confirm the final claim yourself.

## Security design

- Claim logic is not reimplemented here; the signed payload is built and submitted by Nesa's official `claim-rewards-alt.sh`.
- The official file is pinned to commit `b204312dd53104df9680f08438c15e25177c0dc8` and must match SHA-256 `9e040755e5633957aa47807adbebb5c8ad9b4fcd86c5fc8228197942d46ce41d` before the tool writes a private key to disk or executes it.
- The pinned official CLI has a display-only formatting bug that renders integer amounts ending in zero incorrectly (`30` as `3`, for example). The wrapper applies one exact replacement after the official hash passes, then requires patched SHA-256 `29bc7697950c014fdd590723fe18893ae2efa75a59fbe04385d173340eb01708`. This patch does not touch claim payloads, signatures, endpoints, or raw allocation values.
- Private-key input is hidden and stored only in a mode-`600` temporary file inside a mode-`700` temporary directory.
- The temporary key file is deleted immediately after the official CLI exits and again by the exit trap as a fallback.
- No Seed Phrase is needed. Never paste a Seed Phrase into this tool, a website, Telegram, Discord, or support chat.
- Claim transactions are irreversible. Verify the destination EVM address and the explorer result carefully.

> Deleting a temporary file is best-effort cleanup; no software can honestly guarantee physical erasure from SSDs, snapshots, swap, or terminal/session recording. Run the tool only on a trusted machine.

## Why the old key/seed modes were removed

The previous Private-key checker, key-to-Node-ID matcher, and Seed recovery modes assumed the private key must deterministically reproduce the allocated Node ID. That assumption is precisely what Nesa's alternate claim method was created to bypass. Keeping those modes would produce misleading “no allocation” or “no match” results for affected miners.

## Common official errors

- **Public key does not match the registered key:** the private key is not the latest alternate signing key registered for that Node ID.
- **Node ID is not registered:** that Node ID is not in Nesa's alternate-key claims datastore; contact official Nesa support.
- **No available allocation:** the allocation is zero or has already been claimed.
- **Signature verification failed:** recheck the Node ID and private key; do not keep retrying blindly.
- **Transient `clique_api` error:** first check the explorer and the CLI summary. If no claim was submitted, retry the same Node ID later; the official issue reporter confirmed that a later retry succeeded.

The tool deliberately does not auto-retry claim submissions.

## Direct official command

Nesa's corrected official command includes `bash` before process substitution:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nesaorg/miner-rewards-cli/alternate-key-cli/claim-rewards-alt.sh) \
  --node-id "YOUR_NODE_ID_HERE"
```

The wrapper in this repository is safer for public sharing because it verifies a pinned copy of that official script before handling a private key.

---

Not affiliated with Nesa. Use at your own risk and follow Nesa's Terms of Use.
