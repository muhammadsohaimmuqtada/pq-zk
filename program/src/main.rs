//! SP1 guest program: verifies an ML-DSA-44 (FIPS 204) signature over a
//! 32-byte userOpHash, entirely inside the zkVM.
//!
//! Inputs (private to the prover): pk (1312 B), sig (2420 B), msg (32 B).
//! Public values (committed): ok, user_op_hash, pk — so the on-chain
//! verifier can bind the proof to the account's registered key and the
//! exact operation being authorized.
#![no_main]
sp1_zkvm::entrypoint!(main);

use alloy_sol_types::SolType;
use ml_dsa::{EncodedSignature, EncodedVerifyingKey, MlDsa44, Signature, VerifyingKey};
use pq_zk_lib::PublicValuesStruct;

pub fn main() {
    let pk_bytes = sp1_zkvm::io::read::<Vec<u8>>();
    let sig_bytes = sp1_zkvm::io::read::<Vec<u8>>();
    let msg = sp1_zkvm::io::read::<Vec<u8>>();

    let vk_enc = <EncodedVerifyingKey<MlDsa44> as TryFrom<&[u8]>>::try_from(&pk_bytes)
        .expect("pk must be 1312 bytes");
    let vk = VerifyingKey::<MlDsa44>::decode(&vk_enc);

    let sig_enc = <EncodedSignature<MlDsa44> as TryFrom<&[u8]>>::try_from(&sig_bytes)
        .expect("sig must be 2420 bytes");
    let sig = Signature::<MlDsa44>::decode(&sig_enc).expect("sig decode failed");

    // FIPS 204 pure mode: empty context. Returns bool directly.
    let ok = vk.verify_with_context(&msg, &[], &sig);

    let values = PublicValuesStruct {
        ok,
        user_op_hash: msg.as_slice().try_into().expect("msg must be 32 bytes"),
        pk: pk_bytes.into(),
    };
    sp1_zkvm::io::commit_slice(&PublicValuesStruct::abi_encode(&values));
}
