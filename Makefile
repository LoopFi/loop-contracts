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
anvil-bnc        :; anvil --fork-url $(BNB_RPC_URL) --auto-impersonate
deploy-anvil     :; rm -rf scripts/*-local.json && npx hardhat run scripts/Deploy.js --network local --show-stack-traces
deploy-tenderly  :; npx hardhat run scripts/Deploy.js --network tenderly
deploy-arbitrum   :; npx hardhat run scripts/Deploy.js --network arbitrum
deploy-mainnet   :; npx hardhat run scripts/Deploy.js --network mainnet
deploy-scroll    :; npx hardhat run scripts/Deploy.js --network scroll
deploy-bnc       :; npx hardhat run scripts/Deploy.js --network bnc