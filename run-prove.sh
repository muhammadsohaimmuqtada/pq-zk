#!/usr/bin/env bash
# One-command proof runner for the pq-zk Codespace (v3: evidence edition).
# Fixes missing host deps, tries a swapfile, proves the ML-DSA guest as
# groth16 with compressed/core fallbacks, and on failure prints kernel OOM
# evidence + peak memory so the next fix is a certainty, not a guess.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "==> machine: $(nproc) cores"
free -h
echo "==> cgroup memory.max: $(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo '?') | memory.swap.max: $(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null || echo '?')"

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

# Swap: the prover's peak can exceed the cgroup limit; a swapfile absorbs the
# spike (slow but survives) if the cgroup allows swapping.
if [ "$(swapon --show 2>/dev/null | wc -l)" -eq 0 ]; then
  echo "==> trying to add a swapfile (12G, then 8G, then 4G)..."
  for sz in 12 8 4; do
    if sudo fallocate -l ${sz}G /swapfile 2>/dev/null && sudo chmod 600 /swapfile \
       && sudo mkswap -q /swapfile 2>/dev/null && sudo swapon /swapfile 2>/dev/null; then
      echo "==> swap ON: ${sz}G"
      break
    fi
    sudo rm -f /swapfile 2>/dev/null
  done
fi
swapon --show || echo "==> no swap available (cgroup may forbid it)"

# Memory levers (SP1 6.8.1 defaults assume a bigger box: SHARD_SIZE 2^24,
# MEMORY_LIMIT 24 GiB). Smaller shards + fewer parallel workers cut peak RAM.
export SHARD_SIZE=1048576
export MEMORY_LIMIT=1073741824
export SP1_WORKER_NUM_CORE_WORKERS=2
# Phase-level logs so we can see WHERE the run dies.
export RUST_LOG=info

run_prove() {
  local mode="$1"
  echo "==> [$mode] proving..."
  rm -f /tmp/mem.log
  ( while true; do
      echo "$(date +%T) $(free -m | awk '/^Mem:/{print "used=" $3 "M avail=" $7 "M"}')" >> /tmp/mem.log
      sleep 3
    done ) &
  local sampler=$!
  cargo run --release -- --prove --mode "$mode" --dir ../artifacts
  local rc=$?
  kill "$sampler" 2>/dev/null
  echo "==> [$mode] exit code: $rc | peak RAM used (MB): $(sed 's/.*used=//;s/M .*//' /tmp/mem.log 2>/dev/null | sort -rn | head -1)"
  return $rc
}

echo "==> proving (groth16 -> compressed -> core)"
cd "$ROOT/script" || exit 1
if ! run_prove groth16; then
  echo "==> groth16 failed — retrying as compressed"
  if ! run_prove compressed; then
    echo "==> compressed failed — retrying as core"
    run_prove core
  fi
fi

if [ ! -f "$ROOT/artifacts/proof_calldata.hex" ]; then
  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!! PROVING FAILED — no proof_calldata.hex was produced.   !!"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "==> cgroup peak usage: $(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo '?') bytes"
  echo "==> cgroup oom events: $(cat /sys/fs/cgroup/memory.events 2>/dev/null | tr '\n' ' ')"
  echo "==> kernel OOM records:"
  sudo dmesg 2>/dev/null | grep -iE "oom|killed process" | tail -6 || echo "(dmesg unavailable)"
  echo "==> last memory samples:"
  tail -8 /tmp/mem.log 2>/dev/null
  echo "!! Paste ALL of the output above back into the chat."
  exit 1
fi

cd "$ROOT" || exit 1
git add artifacts/
git commit -m "proof artifacts from codespace" || echo "==> nothing new to commit"
git push || echo "==> push failed — run 'git push' again later"
echo "==> done — proof artifacts are in artifacts/ and pushed to the repo"
