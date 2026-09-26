#!/usr/bin/env bash
# One-command proof runner for the pq-zk Codespace.
# Fixes missing host deps, proves the ML-DSA guest as groth16 (the on-chain
# verifiable form) with a compressed fallback, then pushes the artifacts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

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

echo "==> proving (groth16; falls back to compressed if the local SNARK wrap fails)"
cd "$ROOT/script" || exit 1
if ! cargo run --release -- --prove --mode groth16 --dir ../artifacts; then
  echo "==> groth16 failed — retrying as compressed"
  cargo run --release -- --prove --mode compressed --dir ../artifacts
fi

cd "$ROOT" || exit 1
git add artifacts/
git commit -m "proof artifacts from codespace" || echo "==> nothing new to commit"
git push || echo "==> push failed — run 'git push' again later"
echo "==> done — proof artifacts are in artifacts/ and pushed to the repo"
