#!/usr/bin/env bash
# One-command proof runner for the pq-zk Codespace.
# Fixes missing host deps, proves the ML-DSA guest as groth16 (the on-chain
# verifiable form) with compressed/core fallbacks, then pushes the artifacts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "==> machine: $(nproc) cores, $(free -g | awk '/^Mem:/{print $2}') GB RAM (Succinct spec: 4 cores + 16 GB)"

GO_MAJOR=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' | cut -d. -f1 || true)
if [ -z "$GO_MAJOR" ] || [ "$GO_MAJOR" -lt 21 ]; then
  echo "==> installing Go 1.23.4 (SP1's gnark-ffi needs Go >= 1.21; apt's bookworm Go is 1.19)"
  curl -fsSL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz | sudo tar -C /usr/local -xz
  sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
  sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi

if ! command -v protoc >/dev/null 2>&1 || ! ldconfig -p 2>/dev/null | grep -q libclang.so; then
  echo "==> installing protobuf-compiler + libclang"
  sudo apt-get update -qq && sudo apt-get install -y -qq protobuf-compiler libclang-dev
fi

if ! rustup toolchain list 2>/dev/null | grep -q succinct; then
  echo "==> installing the SP1 toolchain"
  curl -L https://sp1.succinct.xyz | bash
  "${HOME}/.sp1/bin/sp1up"
fi

if [ -f "$ROOT/artifacts/proof_calldata.hex" ]; then
  echo "==> artifacts/proof_calldata.hex already exists — nothing to do"
  exit 0
fi

# Memory levers (SP1 6.8.1 defaults assume a bigger box: SHARD_SIZE 2^24,
# MEMORY_LIMIT 24 GiB). Smaller shards + fewer parallel core workers keep the
# peak RAM inside a 16 GB machine, at some proving-time cost.
export SHARD_SIZE=1048576
export MEMORY_LIMIT=1073741824
export SP1_WORKER_NUM_CORE_WORKERS=2

echo "==> proving (groth16; falls back to compressed, then core)"
cd "$ROOT/script" || exit 1
if ! cargo run --release -- --prove --mode groth16 --dir ../artifacts; then
  echo "==> groth16 failed — retrying as compressed"
  if ! cargo run --release -- --prove --mode compressed --dir ../artifacts; then
    echo "==> compressed failed — retrying as core"
    cargo run --release -- --prove --mode core --dir ../artifacts
  fi
fi

if [ ! -f "$ROOT/artifacts/proof_calldata.hex" ]; then
  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!! PROVING FAILED — no proof_calldata.hex was produced.   !!"
  echo "!! Paste the FULL output above back into the chat.        !!"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi

cd "$ROOT" || exit 1
git add artifacts/
git commit -m "proof artifacts from codespace" || echo "==> nothing new to commit"
git push || echo "==> push failed — run 'git push' again later"
echo "==> done — proof artifacts are in artifacts/ and pushed to the repo"
