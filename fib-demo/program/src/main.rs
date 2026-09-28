//! Tiny SP1 guest: iterative Fibonacci over u64 — a fixed, minimal computation
//! used to measure the on-chain cost of verifying an SP1 proof. The verifier's
//! gas is program-independent: whatever this proves, the on-chain check costs
//! the same as verifying the full ML-DSA guest's proof.
#![no_main]
sp1_zkvm::entrypoint!(main);

pub fn main() {
    let n = sp1_zkvm::io::read::<u64>();
    let mut a: u64 = 0;
    let mut b: u64 = 1;
    for _ in 0..n {
        let t = a.wrapping_add(b);
        a = b;
        b = t;
    }
    sp1_zkvm::io::commit_slice(&a.to_le_bytes());
}
