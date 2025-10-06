# Variables
DEFAULT_DATABASE_URL := "postgres://postgres:password@localhost:5433/postgres"
DATABASE_URL := env_var_or_default("DATABASE_URL", DEFAULT_DATABASE_URL)

LOGS_DIR := "logs"
PID_FILE := LOGS_DIR + "/localnet.pid"

# Show available commands
default:
    @just --list

# Check that required dependencies are installed
check-deps:
    #!/usr/bin/env bash
    for cmd in forge cargo anvil jq; do
        command -v $cmd >/dev/null 2>&1 || { echo "Error: $cmd is not installed."; exit 1; }
    done

# Run all CI checks
ci: check test

# Run all tests
test: test-foundry test-cargo

# Run Foundry tests
test-foundry:
    forge test -vvv --isolate

# Run all Cargo tests
test-cargo: test-cargo-root test-cargo-example test-cargo-db

# Run Cargo tests for root workspace
test-cargo-root:
    RISC0_DEV_MODE=1 cargo test --workspace --exclude order-stream --exclude boundless-cli --exclude indexer-api --exclude boundless-indexer -- --include-ignored

# Run Cargo tests for counter example
test-cargo-example:
    cd examples/counter && \
    forge build && \
    RISC0_DEV_MODE=1 cargo test

# Run database tests
test-cargo-db:
    just test-db setup
    DATABASE_URL={{DATABASE_URL}} RISC0_DEV_MODE=1 cargo test -p order-stream -- --include-ignored
    DATABASE_URL={{DATABASE_URL}} RISC0_DEV_MODE=1 cargo test -p boundless-cli -- --include-ignored
    just test-db clean

# Run indexer integration tests (requires ETH_MAINNET_RPC_URL)
test-indexer:
    #!/usr/bin/env bash
    set -e
    if [ -z "$ETH_MAINNET_RPC_URL" ]; then
        echo "Error: ETH_MAINNET_RPC_URL environment variable must be set to a mainnet archive node that supports event querying"
        exit 1
    fi
    RISC0_DEV_MODE=1 cargo test -p boundless-indexer --all-targets -- --ignored --nocapture
    RISC0_DEV_MODE=1 cargo test -p indexer-api --all-targets -- --ignored --nocapture

# Manage test postgres instance (setup or clean, defaults to setup)
test-db action="setup":
    #!/usr/bin/env bash
    if [ "{{action}}" = "setup" ]; then
        docker inspect postgres-test > /dev/null 2>&1 || \
        docker run -d \
            --name postgres-test \
            -e POSTGRES_PASSWORD=password \
            -p 5433:5432 \
            postgres:latest
        # Wait for PostgreSQL to be ready
        sleep 3
        docker exec -u postgres postgres-test psql -U postgres -c "CREATE DATABASE test_db;"
    elif [ "{{action}}" = "clean" ]; then
        docker stop postgres-test
        docker rm postgres-test
    else
        echo "Unknown action: {{action}}"
        echo "Available actions: setup, clean"
        exit 1
    fi

# Run all formatting and linting checks
check: check-links check-license check-format check-clippy check-docs check-deployments

# Check links in markdown files
check-links:
    @echo "Checking links in markdown files..."
    git ls-files '*.md' ':!:documentation/*' | xargs lychee --base . --cache --

# Check licenses
check-license:
    @python license-check.py

# Check deployments addresses
check-deployments:
    @echo "Checking deployment addresses..."
    @python deployments-check.py

# Check code formatting
check-format:
    cargo sort --workspace --check
    cargo fmt --all --check
    cd examples/counter && cargo sort --workspace --check
    cd examples/counter && cargo fmt --all --check
    cd examples/smart-contract-requestor && cargo sort --workspace --check
    cd examples/smart-contract-requestor && cargo fmt --all --check
    cd examples/composition && cargo sort --workspace --check
    cd examples/composition && cargo fmt --all --check
    cd examples/counter-with-callback && cargo sort --workspace --check
    cd examples/counter-with-callback && cargo fmt --all --check
    cd crates/guest/assessor && cargo sort --workspace --check
    cd crates/guest/assessor && cargo fmt --all --check
    cd crates/guest/util && cargo sort --workspace --check
    cd crates/guest/util && cargo fmt --all --check
    cd documentation && bun run check
    dprint check
    forge fmt --check

# Run Cargo clippy
check-clippy:
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNELS=1 \
    cargo clippy --workspace --all-targets

    cd examples/counter && forge build && \
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNELS=1 \
    cargo clippy --workspace --all-targets

    cd examples/composition && forge build && \
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNELS=1 \
    cargo clippy --workspace --all-targets

    cd examples/counter-with-callback && \
    forge build && \
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNELS=1 \
    cargo clippy --workspace --all-targets

    cd examples/smart-contract-requestor && \
    forge build && \
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNELS=1 \
    cargo clippy --workspace --all-targets

check-docs:
    cd documentation && bun install
    # Matches the docs-rs job in CI 
    RUSTDOCFLAGS="--cfg docsrs -D warnings" RISC0_SKIP_BUILD=1 cargo +nightly-2025-05-09 doc -p boundless-market --all-features --no-deps

# Format all code
format:
    cargo sort --workspace
    cargo fmt --all
    cd examples/counter && cargo sort --workspace
    cd examples/counter && cargo fmt --all
    cd examples/smart-contract-requestor && cargo sort --workspace
    cd examples/smart-contract-requestor && cargo fmt --all
    cd examples/composition && cargo sort --workspace
    cd examples/composition && cargo fmt --all
    cd examples/counter-with-callback && cargo sort --workspace
    cd examples/counter-with-callback && cargo fmt --all
    cd crates/guest/assessor && cargo sort --workspace
    cd crates/guest/assessor && cargo fmt --all
    cd crates/guest/util && cargo sort --workspace
    cd crates/guest/util && cargo fmt --all
    cd documentation && bun install && bun run format-markdown
    dprint fmt
    forge fmt

# Clean up all build artifacts
clean: 
    @just localnet down
    @echo "Cleaning up..."
    @rm -rf {{LOGS_DIR}} ./broadcast
    cargo clean
    forge clean
    @echo "Cleanup complete."

# Manage the development network (up or down, defaults to up)
localnet action="up": check-deps
    #!/usr/bin/env bash
    # Localnet-specific variables
    ANVIL_BLOCK_TIME="2"
    RISC0_DEV_MODE="${RISC0_DEV_MODE:-1}"
    CHAIN_KEY="anvil"
    RUST_LOG="info,broker=debug,boundless_market=debug,order_stream=debug"
    # This key is a prefunded address for the anvil test configuration (index 0)
    DEPLOYER_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    ADMIN_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    DEPOSIT_AMOUNT="100000000000000000000"
    CI=${CI:-0}
    
    if [ "{{action}}" = "up" ]; then
        # Find an unused port
        get_free_port() {
        for port in $(seq 8500 8600); do
            if ! lsof -i:$port > /dev/null; then
            echo "$port"
            return
            fi
        done
        echo "No free port found" >&2
        exit 1
        }

        PORT=$(get_free_port)
        echo "Starting anvil on port $PORT"
        ANVIL_PORT=$PORT
        mkdir -p {{LOGS_DIR}}
        
        # Create .env.localnet from template if it doesn't exist
        if [ ! -f .env.localnet ]; then
            echo "Creating .env.localnet from template..."
            cp .env.localnet-template .env.localnet || { echo "Error: .env.localnet-template not found"; exit 1; }
        fi
        
        echo "Building contracts..."
        forge build || { echo "Failed to build contracts"; just localnet down; exit 1; }
        echo "Building Rust project..."
        if [ $CI -eq 1 ]; then
            echo "Running in CI mode, skipping Rust build."
            # In CI, we assume the Rust project is already built
            # and the binaries are available in the target directory.
        else
            cargo build --locked --bin order_stream || { echo "Failed to build order-stream binary"; just localnet down; exit 1; }
            cargo build --locked --bin boundless || { echo "Failed to build boundless CLI binary"; just localnet down; exit 1; }
        fi
        # Check if Anvil is already running
        if nc -z localhost $ANVIL_PORT; then
            echo "Anvil is already running on port $ANVIL_PORT. Reusing existing instance."
        else
            echo "Starting Anvil..."
            anvil -p $ANVIL_PORT -b $ANVIL_BLOCK_TIME > {{LOGS_DIR}}/anvil.txt 2>&1 & echo $! >> {{PID_FILE}}
            sleep 5
        fi
        echo "Deploying contracts..."
        DEPLOYER_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY CHAIN_KEY=$CHAIN_KEY RISC0_DEV_MODE=$RISC0_DEV_MODE BOUNDLESS_MARKET_OWNER=$ADMIN_ADDRESS forge script contracts/scripts/Deploy.s.sol --rpc-url http://localhost:$ANVIL_PORT --broadcast -vv || { echo "Failed to deploy contracts"; just localnet down; exit 1; }
        echo "Fetching contract addresses..."
        VERIFIER_ADDRESS=$(jq -re '.transactions[] | select(.contractName == "RiscZeroVerifierRouter") | .contractAddress' ./broadcast/Deploy.s.sol/31337/run-latest.json | head -n 1)
        SET_VERIFIER_ADDRESS=$(jq -re '.transactions[] | select(.contractName == "RiscZeroSetVerifier") | .contractAddress' ./broadcast/Deploy.s.sol/31337/run-latest.json | head -n 1)
        BOUNDLESS_MARKET_ADDRESS=$(jq -re '.transactions[] | select(.contractName == "ERC1967Proxy") | .contractAddress' ./broadcast/Deploy.s.sol/31337/run-latest.json | head -n 1)
        HIT_POINTS_ADDRESS=$(jq -re '.transactions[] | select(.contractName == "HitPoints") | .contractAddress' ./broadcast/Deploy.s.sol/31337/run-latest.json | head -n 1)
        echo "Contract deployed at addresses:"
        echo "VERIFIER_ADDRESS=$VERIFIER_ADDRESS"
        echo "SET_VERIFIER_ADDRESS=$SET_VERIFIER_ADDRESS"
        echo "BOUNDLESS_MARKET_ADDRESS=$BOUNDLESS_MARKET_ADDRESS"
        echo "HIT_POINTS_ADDRESS=$HIT_POINTS_ADDRESS"
        echo "Updating .env.localnet file..."
        # Update the environment variables in .env.localnet
        sed -i.bak "s/^export VERIFIER_ADDRESS=.*/export VERIFIER_ADDRESS=$VERIFIER_ADDRESS/" .env.localnet
        sed -i.bak "s/^export SET_VERIFIER_ADDRESS=.*/export SET_VERIFIER_ADDRESS=$SET_VERIFIER_ADDRESS/" .env.localnet
        sed -i.bak "s/^export BOUNDLESS_MARKET_ADDRESS=.*/export BOUNDLESS_MARKET_ADDRESS=$BOUNDLESS_MARKET_ADDRESS/" .env.localnet
        sed -i.bak "s/^export HIT_POINTS_ADDRESS=.*/export HIT_POINTS_ADDRESS=$HIT_POINTS_ADDRESS/" .env.localnet
        sed -i.bak "s/^export RPC_URL=.*/export RPC_URL=\"http:\/\/localhost:$ANVIL_PORT\"/" .env.localnet
        rm .env.localnet.bak
        echo ".env.localnet file updated successfully."
        
        # Mint stake to the address in the localnet template wallet
        DEFAULT_PRIVATE_KEY="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
        DEFAULT_ADDRESS="0x90F79bf6EB2c4f870365E785982E1f101E93b906"
        
        echo "Minting HP for prover address."
        cast send --private-key $DEPLOYER_PRIVATE_KEY \
            --rpc-url http://localhost:$ANVIL_PORT \
            $HIT_POINTS_ADDRESS "mint(address, uint256)" $DEFAULT_ADDRESS $DEPOSIT_AMOUNT

        if [ $CI -eq 1 ]; then
            REPO_ROOT_DIR=${REPO_ROOT:-$(git rev-parse --show-toplevel)}
            DEPLOYMENT_SECRETS_PATH="${REPO_ROOT_DIR}/contracts/deployment_secrets.toml"
            echo "Creating ${DEPLOYMENT_SECRETS_PATH}..."
            echo "[chains.anvil]" > $DEPLOYMENT_SECRETS_PATH
            echo "rpc-url = \"http://localhost:${ANVIL_PORT}\"" >> $DEPLOYMENT_SECRETS_PATH
            echo "etherscan-api-key = \"none\"" >> $DEPLOYMENT_SECRETS_PATH
            ls -al $DEPLOYMENT_SECRETS_PATH
            cat $DEPLOYMENT_SECRETS_PATH
            ASSESSOR_ID=$(r0vm --id --elf target/riscv-guest/guest-assessor/assessor-guest/riscv32im-risc0-zkvm-elf/release/assessor-guest.bin)
            ASSESSOR_ID="0x$ASSESSOR_ID"
            ASSESSOR_GUEST_BIN_PATH=$(realpath target/riscv-guest/guest-assessor/assessor-guest/riscv32im-risc0-zkvm-elf/release/assessor-guest.bin)
            ASSESSOR_GUEST_URL="file://$ASSESSOR_GUEST_BIN_PATH"
            echo "Running in CI mode, skipping prover setup."
            python3 contracts/update_deployment_toml.py \
                --verifier "$VERIFIER_ADDRESS" \
                --set-verifier "$SET_VERIFIER_ADDRESS" \
                --boundless-market "$BOUNDLESS_MARKET_ADDRESS" \
                --collateral-token "$HIT_POINTS_ADDRESS" \
                --assessor-image-id "$ASSESSOR_ID" \
                --assessor-guest-url "$ASSESSOR_GUEST_URL"
        else
            # Start order stream server
            just test-db setup
            echo "Starting order stream server..."
            DATABASE_URL={{DATABASE_URL}} RUST_LOG=$RUST_LOG ./target/debug/order_stream \
                --rpc-url http://localhost:$ANVIL_PORT \
                --min-balance-raw 0 \
                --bypass-addrs="0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f" \
                --boundless-market-address $BOUNDLESS_MARKET_ADDRESS > {{LOGS_DIR}}/order_stream.txt 2>&1 & echo $! >> {{PID_FILE}}
            
            echo "Depositing stake using boundless CLI..."
            RPC_URL=http://localhost:$ANVIL_PORT \
            PRIVATE_KEY=$DEFAULT_PRIVATE_KEY \
            BOUNDLESS_MARKET_ADDRESS=$BOUNDLESS_MARKET_ADDRESS \
            SET_VERIFIER_ADDRESS=$SET_VERIFIER_ADDRESS \
            VERIFIER_ADDRESS=$VERIFIER_ADDRESS \
            ./target/debug/boundless account deposit 100 || echo "Note: Stake deposit failed, but this is non-critical for localnet setup"
            
            echo "Localnet is running with RISC0_DEV_MODE=$RISC0_DEV_MODE"
            if [ ! -f broker.toml ]; then
                echo "Creating broker.toml from template..."
                cp broker-template.toml broker.toml || { echo "Error: broker-template.toml not found"; exit 1; }
                echo "broker.toml created successfully."
            fi
            echo "Make sure to run 'source .env.localnet' to load the environment variables before interacting with the network."
            echo "To start the broker manually, run:"
            echo "source .env.localnet && cargo run --bin broker"
        fi
        
    elif [ "{{action}}" = "down" ]; then
        if [ -f {{PID_FILE}} ]; then
            while read pid; do
                kill $pid 2>/dev/null || true
            done < {{PID_FILE}}
            rm {{PID_FILE}}
        fi
        if [ $CI -eq 1 ]; then
            echo "Running in CI mode, skipping test-db cleanup."
        else
            just test-db clean
        fi
    elif [ "{{action}}" = "logs" ]; then
        if [ ! -f {{PID_FILE}} ]; then
            echo "localnet is not running" >/dev/stderr; exit 1
        fi
        tail -F {{LOGS_DIR}}/*
    else
        echo "Unknown action: {{action}}"
        echo "Available actions: up, down"
        exit 1
    fi

# Update cargo dependencies
cargo-update:
    cargo update
    cd examples/counter && cargo update

# Start the bento service
bento action="up" env_file="" compose_flags="" detached="true":
    #!/usr/bin/env bash
    if [ -n "{{env_file}}" ]; then
        ENV_FILE_ARG="--env-file {{env_file}}"
    else
        ENV_FILE_ARG=""
    fi

    if ! command -v docker &> /dev/null; then
        echo "Error: Docker command is not available. Please make sure you have docker in your PATH."
        exit 1
    fi

    if ! docker compose version &> /dev/null; then
        echo "Error: Docker compose command is not available. Please make sure you have docker in your PATH."
        exit 1
    fi

    if [ "{{action}}" = "up" ]; then
        if [ -n "{{env_file}}" ] && [ ! -f "{{env_file}}" ]; then
            echo "Error: Environment file {{env_file}} does not exist."
            exit 1
        fi

        echo "Starting Docker Compose services"
        if [ -n "{{env_file}}" ]; then
            echo "Using environment file: {{env_file}}"
        else
            echo "Using default values from compose.yml"
        fi
        
        if [ "{{detached}}" = "true" ]; then
            DETACHED_FLAG="-d"
        else
            DETACHED_FLAG=""
        fi
        
        docker compose {{compose_flags}} $ENV_FILE_ARG up --build $DETACHED_FLAG
        if [ "{{detached}}" != "true" ]; then
            echo "Docker Compose services have been started."
        fi
    elif [ "{{action}}" = "down" ]; then
        echo "Stopping Docker Compose services"
        if docker compose {{compose_flags}} --profile miner $ENV_FILE_ARG down; then
            echo "Docker Compose services have been stopped and removed."
        else
            echo "Error: Failed to stop Docker Compose services."
            exit 1
        fi
    elif [ "{{action}}" = "clean" ]; then
        echo "Stopping and cleaning Docker Compose services"
        if docker compose {{compose_flags}} --profile miner $ENV_FILE_ARG down -v; then
            echo "Docker Compose services have been stopped and volumes have been removed."
        else
            echo "Error: Failed to clean Docker Compose services."
            exit 1
        fi
    elif [ "{{action}}" = "logs" ]; then
        echo "Docker logs"
        docker compose {{compose_flags}} $ENV_FILE_ARG logs -f
    else
        echo "Unknown action: {{action}}"
        echo "Available actions: up, down, clean, logs"
        exit 1
    fi

# Run the broker service with a bento cluster for proving.
broker action="up" env_file="" detached="true":
    #!/usr/bin/env bash
    # Check if broker.toml exists, if not create it from template
    if [ ! -f broker.toml ]; then
        echo "Creating broker.toml from template..."
        cp broker-template.toml broker.toml || { echo "Error: broker-template.toml not found"; exit 1; }
        echo "broker.toml created successfully."
    fi

    just bento "{{action}}" "{{env_file}}" "--profile broker" "{{detached}}"

# Run the mining service with a bento cluster
mine action="up":
    #!/usr/bin/env bash
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker command is not available. Please make sure you have docker in your PATH."
        exit 1
    fi

    if ! docker compose version &> /dev/null; then
        echo "Error: Docker compose command is not available. Please make sure you have docker in your PATH."
        exit 1
    fi

    if [ "{{action}}" = "up" ]; then
        echo "Starting mining service"
        docker compose --profile miner up -d --build miner
        echo "Mining service has been started."
    elif [ "{{action}}" = "down" ]; then
        echo "Stopping mining service"
        if docker compose --profile miner stop miner; then
            echo "Mining service has been stopped."
        else
            echo "Error: Failed to stop mining service."
            exit 1
        fi
    else
        echo "Unknown action: {{action}}"
        echo "Available actions: up, down"
        exit 1
    fi

# Run the setup script
bento-setup:
    #!/usr/bin/env bash
    ./scripts/setup.sh

# Check job status in Postgres
job-status job_id:
    #!/usr/bin/env bash
    ./scripts/job_status.sh {{job_id}}
