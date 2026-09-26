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
   The devcontainer auto-installs Rust, the SP1 toolchain, protoc, libclang and Go.

2. Run the one-command proof runner:

   ```bash
   git pull && bash run-prove.sh
   ```

   It fixes any missing host deps (including Go ≥ 1.21, which apt's bookworm
   Go is not), proves the guest as **groth16** — the on-chain verifiable form —
   with a compressed fallback, then commits and pushes the artifacts.
   Takes ~10–40 min of full CPU (normal for proving). On success it prints
   proving time, proof size, the verification key, and `LOCAL VERIFICATION: OK`,
   and writes `artifacts/proof_calldata.hex`, `artifacts/public_values.hex`,
   `artifacts/vkey.txt`.

## Manual commands (if you'd rather run each step)

```bash
cd /workspaces/pq-zk/script
cargo run --release -- --execute --dir ../artifacts   # sanity: cycles ≈ 2.7M
cargo run --release -- --prove --mode groth16 --dir ../artifacts
# fallback if groth16 fails: --mode compressed
git add artifacts/ && git commit -m "proof artifacts" && git push
```

Then on the laptop: `HybridAccountZK` verifies the proof on-chain and the
direct-vs-zk gas table gets its second measured number.
