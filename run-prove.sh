#!/usr/bin/env bash
# One-command proof runner for the pq-zk Codespace / Kaggle (v4).
# - fixes host deps (Go >= 1.21, protoc, libclang, SP1 toolchain)
# - tries a swapfile when allowed
# - big machine (>=27 GB): one groth16 run with SP1 defaults
# - small machine (16 GB class): a shard-size ladder + single worker to fit
# - samples RAM + top processes during proving; on failure dumps OOM evidence
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "==> machine: $(nproc) cores, ${TOTAL_MB} MB RAM"
echo "==> cgroup memory.max: $(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo '?') | memory.swap.max: $(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null || echo '?')"

# Free RAM: the IDE's rust-analyzer sits on ~2.5 GB and the prover needs it.
# (Reversible: reinstall it from the Extensions panel when you want IntelliSense.)
if command -v code >/dev/null 2>&1 && code --list-extensions 2>/dev/null | grep -q rust-lang.rust-analyzer; then
  echo "==> disabling rust-analyzer to free ~2.5 GB RAM"
  code --uninstall-extension rust-lang.rust-analyzer >/dev/null 2>&1 || true
  pkill -f rust-analyzer 2>/dev/null || true
fi

GO_MAJOR=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' | cut -d. -f1 || true)
if [ -z "$GO_MAJOR" ] || [ "$GO_MAJOR" -lt 21 ]; then
  echo "==> installing Go 1.23.4 (SP1's gnark-ffi needs Go >= 1.21)"
  curl -fsSL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz | $SUDO tar -C /usr/local -xz
  $SUDO ln -sf /usr/local/go/bin/go /usr/local/bin/go
  $SUDO ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi

if ! command -v protoc >/dev/null 2>&1 || ! ldconfig -p 2>/dev/null | grep -q libclang.so; then
  echo "==> installing protobuf-compiler + libclang"
  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq protobuf-compiler libclang-dev
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "==> installing Rust (rustup)"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  export PATH="$HOME/.cargo/bin:$PATH"
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

# Swap: absorbs the prover's memory spike where the environment allows it.
if [ "$(swapon --show 2>/dev/null | wc -l)" -eq 0 ]; then
  echo "==> trying to add a swapfile (12G, then 8G, then 4G)..."
  for sz in 12 8 4; do
    if $SUDO fallocate -l ${sz}G /swapfile 2>/dev/null && $SUDO chmod 600 /swapfile \
       && $SUDO mkswap -q /swapfile 2>/dev/null && $SUDO swapon /swapfile 2>/dev/null; then
      echo "==> swap ON: ${sz}G"
      break
    fi
    $SUDO rm -f /swapfile 2>/dev/null
  done
fi
swapon --show || echo "==> no swap available"

export RUST_LOG=info

run_prove() {
  local mode="$1"
  echo "==> [$mode] proving (SHARD_SIZE=${SHARD_SIZE:-default}, workers=${SP1_WORKER_NUM_CORE_WORKERS:-default})..."
  rm -f /tmp/mem.log
  ( while true; do
      echo "$(date +%T) $(free -m | awk '/^Mem:/{printf "used=%dM avail=%dM", $3, $7}') | top: $(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -3 | awk '{printf "%s=%.0fMB ", $2, $1/1024}')" >> /tmp/mem.log
      sleep 3
    done ) &
  local sampler=$!
  cargo run --release -- --prove --mode "$mode" --dir ../artifacts
  local rc=$?
  kill "$sampler" 2>/dev/null
  echo "==> [$mode] exit code: $rc | peak RAM used (MB): $(sed 's/.*used=//;s/M .*//' /tmp/mem.log 2>/dev/null | sort -rn | head -1)"
  return $rc
}

cd "$ROOT/script" || exit 1

if [ "$TOTAL_MB" -ge 27000 ]; then
  echo "==> big machine — SP1 defaults, single groth16 run"
  unset SHARD_SIZE MEMORY_LIMIT
  export SP1_WORKER_NUM_CORE_WORKERS=4
  run_prove groth16 || true
else
  echo "==> 16 GB-class machine — memory ladder (smallest shards, one worker)"
  export MEMORY_LIMIT=1073741824
  export SP1_WORKER_NUM_CORE_WORKERS=1
  export SP1_WORKER_CORE_BUFFER_SIZE=1
  # descending shard sizes shrink the per-shard trace; modes from lightest
  # artifact to the on-chain verifiable one
  for step in compressed:262144 compressed:65536 core:262144 groth16:262144; do
    mode="${step%%:*}"; export SHARD_SIZE="${step##*:}"
    if run_prove "$mode"; then echo "==> SUCCESS: mode=$mode SHARD_SIZE=$SHARD_SIZE"; break; fi
    echo "==> attempt failed: mode=$mode SHARD_SIZE=$SHARD_SIZE"
  done
fi

if [ ! -f "$ROOT/artifacts/proof_calldata.hex" ]; then
  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!! PROVING FAILED — no proof_calldata.hex was produced.   !!"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "==> cgroup peak usage: $(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo '?') bytes"
  echo "==> cgroup oom events: $(cat /sys/fs/cgroup/memory.events 2>/dev/null | tr '\n' ' ')"
  echo "==> last memory samples (with the top memory owners):"
  tail -10 /tmp/mem.log 2>/dev/null
  echo "!! Paste ALL of the output above back into the chat."
  exit 1
fi

cd "$ROOT" || exit 1
git add artifacts/
git commit -m "proof artifacts" || echo "==> nothing new to commit"
git push 2>/dev/null || echo "==> no git credentials here — download artifacts/{proof_calldata.hex,public_values.hex,vkey.txt} manually (see KAGGLE.md)"
echo "==> done — proof artifacts are in artifacts/"
