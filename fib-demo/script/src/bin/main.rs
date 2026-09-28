//! Host script for the fib demo proof:
//!   --execute : run the guest without proving; prints the cycle count
//!   --prove   : prove (core|groth16), verify locally, write artifacts
//!
//! The groth16 proof's calldata is what the on-chain SP1 verifier consumes —
//! its gas cost is the zk-leg number for the direct-vs-zk table.
use clap::Parser;
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, HashableKey, ProvingKey, SP1Stdin,
};

const FIB_ELF: Elf = include_elf!("fib-program");

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(long)]
    execute: bool,

    #[arg(long)]
    prove: bool,

    #[arg(long, default_value = "artifacts")]
    dir: String,

    /// Proof kind: "core" (light) or "groth16" (the on-chain wrap)
    #[arg(long, default_value = "groth16")]
    mode: String,

    /// Fibonacci iterations (the cycle knob)
    #[arg(long, default_value = "1000")]
    n: u64,
}

fn main() {
    sp1_sdk::utils::setup_logger();
    let args = Args::parse();

    if args.execute == args.prove {
        eprintln!("Error: specify either --execute or --prove");
        std::process::exit(1);
    }

    let client = ProverClient::from_env();
    let mut stdin = SP1Stdin::new();
    stdin.write(&args.n);

    if args.execute {
        let (output, report) = client.execute(FIB_ELF, stdin).run().expect("execute failed");
        println!("committed: 0x{}", hex::encode(output.as_slice()));
        println!("cycles: {}", report.total_instruction_count());
    } else {
        let t0 = std::time::Instant::now();
        let pkey = client.setup(FIB_ELF).expect("setup failed");
        let setup_time = t0.elapsed();

        let proof = match args.mode.as_str() {
            "core" => client.prove(&pkey, stdin).core().run().expect("proving failed"),
            _ => client.prove(&pkey, stdin).groth16().run().expect("proving failed"),
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
