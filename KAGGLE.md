# Plan B: proving on Kaggle (4 cores / 30 GB RAM, free)

The Codespace caps at ~15 GB usable RAM and the SP1 prover bursts past it.
Kaggle's free CPU notebooks give **4 cores / 30 GB RAM** for 12-hour sessions —
above Succinct's documented requirement — and run the same `run-prove.sh`
unchanged.

## One-time setup

1. Create a free account at <https://www.kaggle.com> (phone verification is
   required to enable internet access).
2. **Create** → **New Notebook**.
3. Right sidebar → **Session options** → **Internet: ON**, Accelerator: None.

## Run

Paste into a notebook cell and run it (Shift+Enter):

```
!git clone https://github.com/muhammadsohaimmuqtada/pq-zk
!cd pq-zk && bash run-prove.sh
```

The script installs everything itself (Rust, SP1 toolchain, Go, protoc,
libclang — the machine runs as root, no passwords needed). Expect ~10 min of
compiling, then ~20–60 min of proving. The cell blocks while it runs; you can
close the browser tab and come back later — the session keeps running.

On success the last line prints `done — proof artifacts are in artifacts/`.

## Get the artifacts back

Kaggle has no GitHub login, so the push step there is skipped by design:

1. Open the **file browser** (folder icon, right sidebar of the notebook).
2. Go to `kaggle/working/pq-zk/artifacts/` — three NEW files:
   `proof_calldata.hex`, `public_values.hex`, `vkey.txt`.
3. Download all three to the laptop, put them into the local
   `pq-zk/artifacts/` folder, and tell the chat — the on-chain leg continues
   from there.

(Alternative: upload the three files to the GitHub repo via github.com's
web UI — add file → upload — and the chat pulls them like normal.)

## Notes

- Don't leave the session idle for hours, Kaggle reaps inactive notebooks.
- If a cell errors early, just run it again — the script skips finished steps.
- The whole flow is also documented in `CODESPACE.md` for the Codespace path.
