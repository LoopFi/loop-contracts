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
anvil-xdc        :; anvil --fork-url $(XDC_RPC_URL) --auto-impersonate --balance 10000000
anvil-bitlayer   :; anvil --fork-url $(BITLAYER_RPC_URL) --auto-impersonate --balance 10000
deploy-clear     :; rm -rf scripts/*-local.json
deploy-anvil     :; npx hardhat run scripts/deploy_eth.js --network local --show-stack-traces
deploy-anvil-usdc:; npx hardhat run scripts/deploy_usdc.js --network local --show-stack-traces
deploy-anvil-bsc :;	npx hardhat run scripts/deploy_bsc.js --network local --show-stack-traces
deploy-anvil-xdc :; npx hardhat run scripts/deploy_xdc.js --network local --show-stack-traces
deploy-anvil-bitlayer :; npx hardhat run scripts/deploy_bitlayer.js --network local --show-stack-traces
deploy-tenderly-eth  :; npx hardhat run scripts/deploy_eth.js --network tenderly
deploy-tenderly-usdc :; npx hardhat run scripts/deploy_usdc.js --network tenderly
deploy-xdc       :; npx hardhat run scripts/deploy_xdc.js --network xdc --show-stack-traces
deploy-xdc-testnet:; npx hardhat run scripts/deploy_xdc.js --network xdc_testnet --show-stack-traces
deploy-bitlayer  :; npx hardhat run scripts/deploy_bitlayer.js --network bitlayer --show-stack-traces
deploy-bitlayer-testnet:; npx hardhat run scripts/deploy_bitlayer.js --network bitlayer_testnet --show-stack-traces

# deploy-mainnet-usdc   	:; npx hardhat run scripts/deploy_usdc.js --network mainnet
# deploy-mainnet-eth   	:; npx hardhat run scripts/deploy_eth.js --network mainnet
deploy-bsc       		:; npx hardhat run scripts/deploy_bsc.js --network bsc --show-stack-traces

# ACL Ownership
acl-update-owner-anvil    :; npm run update-acl-owner
acl-update-owner-tenderly :; npm run update-acl-owner-tenderly

# TODO: uncomment these when ready
# deploy-arbitrum  :; npx hardhat run scripts/Deploy.js --network arbitrum

# deploy-scroll    :; npx hardhat run scripts/Deploy.js --network scroll

