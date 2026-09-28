# Plan C: prove on Google Colab (free, no ID checks)

Use this if the Codespace's 15 GB still can't fit the proof. Colab free tier gives
~12.7 GB RAM **and allows a swapfile** — the swap absorbs the prover's spikes, at
the cost of speed (expect 1–3 hours instead of ~30 minutes).

## Steps

1. Open <https://colab.research.google.com> with your Google account → **New notebook**.

2. **Cell 1** — create 20 GB swap, then run it (Shift+Enter):
   ```
   !fallocate -l 20G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && free -h
   ```
   `Swap:` should now show ~20G.

3. **Cell 2** — clone and prove:
   ```
   !git clone https://github.com/muhammadsohaimmuqtada/pq-zk && cd pq-zk && bash run-prove.sh
   ```
   The script installs Rust, the SP1 toolchain, Go and all deps itself (Colab runs
   as root), then proves: fib groth16 wrap-probe → ML-DSA groth16 ladder →
   ML-DSA compressed fallback. `bash -n` clean; every step logs its phase and RAM.

4. **Keep the tab open** while it runs (free Colab reclaims runtimes; closing the
   tab for long risks losing the session). Check in every so often.

5. When it prints `done`, download the artifacts from the file panel (folder icon,
   left sidebar):
   - `pq-zk/artifacts/` — ML-DSA proof: `proof_calldata.hex`, `public_values.hex`, `vkey.txt`
   - `pq-zk/fib-demo/artifacts/` — fib fixture (same three files)

   `git push` from Colab has no credentials, so the script prints a manual-download
   notice instead — that's expected.

6. Drop the files into the same folders in your local `pq-zk` clone and tell the
   chat — the on-chain leg (real-proof verification, HybridAccountZK deploy, gas
   table) proceeds from there.
