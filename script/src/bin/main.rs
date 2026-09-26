//! Host script for the PQ zk proof:
//!   --execute : run the guest without proving; prints the cycle count
//!   --prove   : prove, verify locally, print/measure (time, proof size, vkey)
//!
//! Artifacts come from the ESP32 device: pk.bin, sig.bin, msg.bin (default dir: ./artifacts).
use alloy_sol_types::SolType;
use clap::Parser;
use pq_zk_lib::PublicValuesStruct;
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, HashableKey, ProvingKey, SP1Stdin,
};

const PQ_ZK_ELF: Elf = include_elf!("pq-zk-program");

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(long)]
    execute: bool,

    #[arg(long)]
    prove: bool,

    #[arg(long, default_value = "artifacts")]
    dir: String,

    /// Proof kind: "core" (light, local verify) or "compressed" (for on-chain wrap)
    #[arg(long, default_value = "core")]
    mode: String,
}

fn main() {
    sp1_sdk::utils::setup_logger();
    dotenv::dotenv().ok();
    let args = Args::parse();

    if args.execute == args.prove {
        eprintln!("Error: specify either --execute or --prove");
        std::process::exit(1);
    }

    let pk_bytes = std::fs::read(format!("{}/pk.bin", args.dir)).expect("pk.bin");
    let sig_bytes = std::fs::read(format!("{}/sig.bin", args.dir)).expect("sig.bin");
    let msg = std::fs::read(format!("{}/msg.bin", args.dir)).expect("msg.bin");
    println!(
        "inputs: pk={} B, sig={} B, msg={} B",
        pk_bytes.len(),
        sig_bytes.len(),
        msg.len()
    );

    let client = ProverClient::from_env();
    let mut stdin = SP1Stdin::new();
    stdin.write(&pk_bytes);
    stdin.write(&sig_bytes);
    stdin.write(&msg);

    if args.execute {
        let (output, report) = client.execute(PQ_ZK_ELF, stdin).run().expect("execute failed");
        let values = PublicValuesStruct::abi_decode(output.as_slice()).unwrap();
        println!(
            "executed: ok={} user_op_hash={:?} pk_bytes={}",
            values.ok,
            values.user_op_hash,
            values.pk.len()
        );
        println!("cycles: {}", report.total_instruction_count());
    } else {
        let t0 = std::time::Instant::now();
        let pkey = client.setup(PQ_ZK_ELF).expect("setup failed");
        let setup_time = t0.elapsed();

        let proof = match args.mode.as_str() {
            "core" => client.prove(&pkey, stdin).core().run().expect("proving failed"),
            _ => client.prove(&pkey, stdin).run().expect("proving failed"),
        };
        let prove_time = t0.elapsed() - setup_time;

        println!("mode: {}", args.mode);
        println!("setup: {:?}", setup_time);
        println!("prove: {:?}", prove_time);
        println!("vkey: {}", pkey.verifying_key().bytes32());
        println!("proof size: {} bytes", proof.bytes().len());
        println!("public values: 0x{}", hex::encode(proof.public_values.as_slice()));

        client
            .verify(&proof, pkey.verifying_key(), None)
            .expect("local verification failed");
        println!("LOCAL VERIFICATION: OK");

        std::fs::write(
            format!("{}/vkey.txt", args.dir),
            pkey.verifying_key().bytes32().to_string(),
        )
        .expect("write vkey");
        std::fs::write(
            format!("{}/public_values.hex", args.dir),
            hex::encode(proof.public_values.as_slice()),
        )
        .expect("write public values");
        std::fs::write(
            format!("{}/proof_calldata.hex", args.dir),
            hex::encode(proof.bytes()),
        )
        .expect("write proof");
        println!("artifacts written to {}/", args.dir);
    }
}
