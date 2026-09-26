# pq-zk: proving the ML-DSA verifier in SP1 (Codespace runbook)

This repo contains an SP1 guest program that verifies an ML-DSA-44 (FIPS 204)
signature — the post-quantum leg of the hybrid 2-of-2 account in `pq-account`.
The artifacts in `artifacts/` (pk.bin, sig.bin, msg.bin) were produced by the
ESP32 signer device.

Local proving of the full guest needs ~16 GB RAM (see Succinct's hardware
requirements) — use a **4-core / 16 GB** Codespace.

## Steps

1. Create the Codespace on this repo — **machine type: 4 cores, 16 GB RAM, 32 GB storage**
   (Code → Codespaces → "+" → Change options → pick 4-core/16GB).
   The devcontainer auto-installs Rust and the SP1 toolchain (`sp1up`).

2. Sanity: execute the guest without proving (fast, prints the cycle count):

   ```bash
   cd script
   cargo run --release -- --execute --dir ../artifacts
   ```

3. Prove (the real run — takes ~10–30 min on 4 cores). Run from `script/`
   (the `--dir` path is relative to where you run it):

   ```bash
   cd /workspaces/pq-zk/script
   cargo run --release -- --prove --mode compressed --dir ../artifacts
   ```

   On success it prints proving time, proof size, the verification key, and
   writes `artifacts/proof_calldata.hex`, `artifacts/public_values.hex`,
   `artifacts/vkey.txt`.

4. Bring the artifacts back to the laptop (download via the VS Code explorer,
   or commit + push them):

   ```bash
   git add artifacts/ && git commit -m "proof artifacts" && git push
   ```

Then on the laptop: `HybridAccountZK` verifies the proof on-chain and the
direct-vs-zk gas table gets its second measured number.
