#!/usr/bin/env bash
# One-command proof runner for the pq-zk Codespace / Colab / Kaggle (v5).
# - fixes host deps (Go >= 1.21, protoc, libclang, SP1 toolchain)
# - frees the IDE's RAM (rust-analyzer) and adds swap where allowed
# - v5 fix: SP1's real shard-boundary knobs. SP1CoreOpts::default() (sp1-core-executor)
#   reads ELEMENT_THRESHOLD / HEIGHT_THRESHOLD — the actual shard split points — plus
#   SHARD_SIZE (an allocation hint only) and TRACE_CHUNK_SLOTS (executor trace ring).
#   The v4 ladder only set SHARD_SIZE, so shards never actually shrank; that was the
#   cause of six identical OOM deaths on the codespace.
# - sequence: fib groth16 (tiny; probes whether the fixed-size SNARK wrap fits this
#   box AND yields an on-chain-verifiable artifact) -> ML-DSA groth16 ladder ->
#   ML-DSA compressed fallback
# - samples RAM + top processes; on failure dumps OOM evidence
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

# SP1's protos import google/protobuf/empty.proto; some distro builds (e.g.
# Colab's) ship protoc without the well-known types — fetch them directly.
if command -v protoc >/dev/null 2>&1 && [ ! -f /usr/include/google/protobuf/empty.proto ]; then
  echo "==> fetching protobuf well-known types (missing from this distro's protoc)"
  $SUDO mkdir -p /usr/include/google/protobuf
  for p in any api descriptor duration empty field_mask source_context struct timestamp type wrappers; do
    $SUDO curl -fsSL "https://raw.githubusercontent.com/protocolbuffers/protobuf/v29.3/src/google/protobuf/${p}.proto" \
      -o "/usr/include/google/protobuf/${p}.proto" || true
  done
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

export RUST_LOG=info

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

if [ "$TOTAL_MB" -ge 27000 ]; then
  echo "==> big machine — SP1 defaults (tuned for 24 GB-class)"
  unset ELEMENT_THRESHOLD HEIGHT_THRESHOLD SHARD_SIZE TRACE_CHUNK_SLOTS MEMORY_LIMIT
  export SP1_WORKER_NUM_CORE_WORKERS=4
else
  echo "==> 16 GB-class machine — real shard-boundary knobs (v5)"
  export ELEMENT_THRESHOLD=$((1 << 24))            # 16.7M trace elements/shard (SP1 default 402M)
  export HEIGHT_THRESHOLD=$((1 << 18))             # 262k rows/shard (SP1 default 4.2M)
  export SHARD_SIZE=$HEIGHT_THRESHOLD              # allocation hint, matched to the boundary
  export TRACE_CHUNK_SLOTS=2                       # executor trace ring ~0.6 GiB (default ~1.4)
  export MEMORY_LIMIT=$((6 * 1024 * 1024 * 1024))  # clean abort instead of death by SIGTERM
  export SP1_WORKER_NUM_CORE_WORKERS=1
  export SP1_WORKER_CORE_BUFFER_SIZE=1
fi

# run_one <script-dir> <mode> <artifacts-dir> <label>
run_one() {
  local sdir="$1" mode="$2" artdir="$3" label="$4"
  echo "==> [$label] proving mode=$mode (ELEMENT_THRESHOLD=${ELEMENT_THRESHOLD:-default}, HEIGHT_THRESHOLD=${HEIGHT_THRESHOLD:-default}, workers=${SP1_WORKER_NUM_CORE_WORKERS:-default})..."
  rm -f /tmp/mem.log
  ( while true; do
      echo "$(date +%T) $(free -m | awk '/^Mem:/{printf "used=%dM avail=%dM", $3, $7}') | top: $(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -3 | awk '{printf "%s=%.0fMB ", $2, $1/1024}')" >> /tmp/mem.log
      sleep 3
    done ) &
  local sampler=$!
  ( cd "$ROOT/$sdir" && cargo run --release -- --prove --mode "$mode" --dir "$artdir" )
  local rc=$?
  kill "$sampler" 2>/dev/null
  echo "==> [$label] exit code: $rc | peak RAM used (MB): $(sed 's/.*used=//;s/M .*//' /tmp/mem.log 2>/dev/null | sort -rn | head -1)"
  return $rc
}

# --- Step 1: fib groth16 — the wrap-feasibility probe -------------------------
# The groth16 wrap circuit is fixed-size regardless of the guest program, so a
# tiny fib proof answers "does the SNARK wrap fit this box?" in minutes. It
# also produces an on-chain-verifiable artifact (proof_calldata.hex) that the
# gas-measurement leg can use directly.
FIB_OK=0
if [ -f "$ROOT/fib-demo/artifacts/proof_calldata.hex" ]; then
  FIB_OK=1
  echo "==> fib artifact already present — skipping wrap probe"
elif run_one fib-demo/script groth16 ../artifacts "fib wrap-probe"; then
  FIB_OK=1
  echo "==> WRAP FEASIBLE: the SNARK wrap fits this box"
else
  echo "==> fib groth16 failed — the SNARK wrap itself does not fit; skipping ML-DSA groth16 attempts"
fi

# --- Step 2: ML-DSA groth16 ladder (only if the wrap is feasible) -------------
MLDSA_OK=0
[ -f "$ROOT/artifacts/proof_calldata.hex" ] && MLDSA_OK=1
if [ "$MLDSA_OK" -eq 0 ] && [ "$FIB_OK" -eq 1 ]; then
  for knobs in "16777216 262144" "4194304 131072"; do
    eth="${knobs%% *}"; h="${knobs##* }"
    export ELEMENT_THRESHOLD="$eth" HEIGHT_THRESHOLD="$h" SHARD_SIZE="$h"
    if run_one script groth16 ../artifacts "mldsa groth16 ETH=$eth/H=$h"; then
      MLDSA_OK=1
      break
    fi
    echo "==> attempt failed: mldsa groth16 ETH=$eth/H=$h"
  done
fi

# --- Step 3: ML-DSA compressed fallback (feasibility artifact; not on-chain) --
if [ "$MLDSA_OK" -eq 0 ] && [ ! -f "$ROOT/artifacts/proof_calldata.hex" ]; then
  export ELEMENT_THRESHOLD=$((1 << 24)) HEIGHT_THRESHOLD=$((1 << 18)) SHARD_SIZE=$((1 << 18))
  run_one script compressed ../artifacts "mldsa compressed (fallback)" \
    || echo "==> compressed fallback failed too"
fi

# --- Report + push ------------------------------------------------------------
if [ ! -f "$ROOT/artifacts/proof_calldata.hex" ] && [ "$FIB_OK" -ne 1 ]; then
  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!! PROVING FAILED — no artifacts were produced.           !!"
  echo "!! Paste ALL of the output above back into the chat.      !!"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "==> cgroup peak usage: $(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo '?') bytes"
  echo "==> cgroup oom events: $(cat /sys/fs/cgroup/memory.events 2>/dev/null | tr '\n' ' ')"
  echo "==> last memory samples (with the top memory owners):"
  tail -10 /tmp/mem.log 2>/dev/null
  exit 1
fi

cd "$ROOT" || exit 1
git add artifacts/ fib-demo/artifacts/ 2>/dev/null
git commit -m "proof artifacts" || echo "==> nothing new to commit"
git push 2>/dev/null || echo "==> no git credentials here — download the artifacts manually (see COLAB.md)"
echo "==> done"
[ "$FIB_OK" -eq 1 ] && echo "==> fib (on-chain gas fixture): fib-demo/artifacts/"
[ -f "$ROOT/artifacts/proof_calldata.hex" ] && echo "==> ML-DSA proof: artifacts/" || echo "==> ML-DSA proof: NOT produced yet (see messages above)"
