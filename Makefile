# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# Update dependencies
install          :; forge install
update           :; forge update

# Build
build            :; forge build --sizes
clean            :; forge clean
lint             :; yarn install && yarn run lint
format           :; npx prettier --write "src/**/*.sol"

# Testing
test             :; forge test --match-path "src/test/**/*.t.sol"
# test             :; forge test --match-path "src/test/**/CDPVault.t.sol"
test-gas             :; forge test --match-path "src/test/**/*.t.sol" --gas-report
test-contract    :; forge test --match-contract $(contract)
test-fuzz        :; forge test --ffi --match-path "src/test/fuzz/**/*.t.sol"
test-invariant   :; forge test --ffi --match-path "src/test/invariant/**/*.t.sol"
test-integration :; forge test --ffi --match-path "src/test/integration/**/*.t.sol"
test-unit        :; forge test --ffi --match-path "src/test/unit/**/*.t.sol"

# Deployment
anvil            :; anvil --fork-url $(MAINNET_RPC_URL) --auto-impersonate
anvil-scroll     :; anvil --fork-url $(SCROLL_RPC_URL) --auto-impersonate
anvil-bsc        :; anvil --fork-url $(BNB_RPC_URL) --auto-impersonate
deploy-clear     :; rm -rf scripts/*-local.json
deploy-anvil     :; npx hardhat run scripts/deploy_eth.js --network local --show-stack-traces
deploy-anvil-usdc:; npx hardhat run scripts/deploy_usdc.js --network local --show-stack-traces
deploy-anvil-bsc :;	npx hardhat run scripts/deploy_bsc.js --network local --show-stack-traces
deploy-tenderly-eth  :; npx hardhat run scripts/deploy_eth.js --network tenderly
deploy-tenderly-usdc :; npx hardhat run scripts/deploy_usdc.js --network tenderly

deploy-mainnet-usdc   	:; npx hardhat run scripts/deploy_usdc.js --network mainnet
deploy-mainnet-eth   	:; npx hardhat run scripts/deploy_eth.js --network mainnet
deploy-bsc       		:; npx hardhat run scripts/deploy_bsc.js --network bsc --show-stack-traces

# TODO: uncomment these when ready
# deploy-arbitrum  :; npx hardhat run scripts/Deploy.js --network arbitrum

# deploy-scroll    :; npx hardhat run scripts/Deploy.js --network scroll

# Voter Management
voters-help      :; npx hardhat run scripts/vote-manager.js help

# Local Voter Management
voters-list-local :; npx hardhat run scripts/vote-manager.js --network=local list-voters
voters-add-local  :; npx hardhat run scripts/vote-manager.js --network=local add-voters
voters-status-local :; npx hardhat run scripts/vote-manager.js --network=local check-voter-status

# BSC Voter Management
voters-list-bsc  :; npx hardhat run scripts/vote-manager.js --network=bsc list-voters
voters-add-bsc   :; npx hardhat run scripts/vote-manager.js --network=bsc add-voters
voters-status-bsc :; npx hardhat run scripts/vote-manager.js --network=bsc check-voter-status

# Mainnet Voter Management
voters-list-mainnet  :; npx hardhat run scripts/vote-manager.js --network=mainnet list-voters
voters-add-mainnet   :; npx hardhat run scripts/vote-manager.js --network=mainnet add-voters
voters-status-mainnet :; npx hardhat run scripts/vote-manager.js --network=mainnet check-voter-status

# Voting (requires parameters) - Use these as templates and adjust the command line arguments
# Example: make voters-vote-local ARGS="0 0x123... 0x456... 0 1000000"
voters-vote-local    :; npx hardhat run scripts/vote-manager.js --network=local vote $(ARGS)
voters-vote-bsc      :; npx hardhat run scripts/vote-manager.js --network=bsc vote $(ARGS)
voters-vote-mainnet  :; npx hardhat run scripts/vote-manager.js --network=mainnet vote $(ARGS)

# Vote for Rate (requires parameters) - Use these as templates and adjust the command line arguments
# Example: make voters-rate-local ARGS="0 0x123... 0x456... 800 1000000"
voters-rate-local    :; npx hardhat run scripts/vote-manager.js --network=local vote-for-rate $(ARGS)
voters-rate-bsc      :; npx hardhat run scripts/vote-manager.js --network=bsc vote-for-rate $(ARGS)
voters-rate-mainnet  :; npx hardhat run scripts/vote-manager.js --network=mainnet vote-for-rate $(ARGS)

