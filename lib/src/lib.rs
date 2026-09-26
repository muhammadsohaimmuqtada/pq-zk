//! Public values committed by the PQ verification guest program.
//!
//! The on-chain verifier parses these to check that a proof actually covers
//! THE userOpHash and THE registered ML-DSA public key (not just "some key
//! verified some message").
use alloy_sol_types::sol;

sol! {
    struct PublicValuesStruct {
        bool ok;
        bytes32 user_op_hash;
        bytes pk;
    }
}
