#!/usr/bin/env python3

import json
import os
import subprocess
import argparse
import time
from pathlib import Path

# Default settings
DEFAULT_SETTINGS = {
    "solc_version": "0.8.19",
    "optimizer_runs": 100,
    "evm_version": "cancun"
}

# Contract constructor signatures
CONTRACT_CONSTRUCTORS = {
    "ACL": "",
    "AddressProviderV3": "address",
    "ContractsRegister": "address",
    "LinearInterestRateModelV3": "uint256,uint256,uint256,uint256,uint256,uint256,bool",
    "PoolQuotaKeeperV3": "address",
    "LoopVoter": "address,uint256",
    "GaugeV3": "address,address",
    "StakingLPEth": "address,string,string,uint256",
    "Locking": "address",
    "PoolV3": "address,address,address,address,uint256,string,string"
}

# Contract path mappings - add your custom paths here
CONTRACT_PATHS = {
    # Format: "ContractName": "path/to/Contract.sol:ContractName"
    
    # Core contracts
    "LinearInterestRateModelV3": "lib/core-v3/contracts/pool/LinearInterestRateModelV3.sol:LinearInterestRateModelV3",
    "ACL": "lib/core-v2/contracts/core/ACL.sol:ACL",
    "AddressProviderV3": "lib/core-v3/contracts/core/AddressProviderV3.sol:AddressProviderV3",
    "ContractsRegister": "lib/core-v3/contracts/core/ContractsRegister.sol:ContractsRegister",
    "PoolQuotaKeeperV3": "lib/core-v3/contracts/pool/PoolQuotaKeeperV3.sol:PoolQuotaKeeperV3",
    
    # Reward managers
    "RewardManager": "src/pendle-rewards/RewardManager.sol:RewardManager",
    "RewardManagerSpectra": "src/spectra-rewards/RewardManagerSpectra.sol:RewardManagerSpectra",
    
    # Spectra contracts
    "CDPVaultSpectra": "src/CDPVaultSpectra.sol:CDPVaultSpectra",
    "CDPVault_Vaults_deUSD": "src/CDPVaultSpectra.sol:CDPVaultSpectra",
    "SpectraYnETHOracle": "src/oracle/SpectraYnETHOracle.sol:SpectraYnETHOracle",
    
    # Core system contracts
    "PoolV3": "src/PoolV3.sol:PoolV3",
    "VaultRegistry": "src/VaultRegistry.sol:VaultRegistry",
    "CDPVault": "src/CDPVault.sol:CDPVault",
    "Treasury": "src/Treasury.sol:Treasury",
    
    # Proxy/Action contracts
    "BaseAction": "src/proxy/BaseAction.sol:BaseAction",
    "ERC165Plugin": "src/proxy/ERC165Plugin.sol:ERC165Plugin",
    "PoolAction": "src/proxy/PoolAction.sol:PoolAction",
    "PositionAction": "src/proxy/PositionAction.sol:PositionAction",
    "PositionAction20": "src/proxy/PositionAction20.sol:PositionAction20",
    "PositionAction4626": "src/proxy/PositionAction4626.sol:PositionAction4626",
    "PositionActionPendle": "src/proxy/PositionActionPendle.sol:PositionActionPendle",
    "PositionActionPenpie": "src/proxy/PositionActionPenpie.sol:PositionActionPenpie",
    "PositionActionTranchess": "src/proxy/PositionActionTranchess.sol:PositionActionTranchess",
    "SwapAction": "src/proxy/SwapAction.sol:SwapAction",
    "TransferAction": "src/proxy/TransferAction.sol:TransferAction",
    
    # Flashlender
    "Flashlender": "src/Flashlender.sol:Flashlender",
    
    # PRBProxy
    "PRBProxyRegistry": "src/proxy/PRBProxyRegistry.sol:PRBProxyRegistry",
    
    # Staking and Locking
    "StakingLPEth": "src/staking/StakingLPEth.sol:StakingLPEth",
    "Locking": "src/staking/Locking.sol:Locking",
    
    # Voter and Gauge
    "LoopVoter": "src/quotas/LoopVoter.sol:LoopVoter",
    "GaugeV3": "src/quotas/GaugeV3.sol:GaugeV3",
    
    # Oracles
    "PendleLPOracleRate": "src/oracle/PendleLPOracleRate.sol:PendleLPOracleRate",
    "MockOracle": "src/oracle/MockOracle.sol:MockOracle",
    "ChainlinkCurveOracle": "src/oracle/ChainlinkCurveOracle.sol:ChainlinkCurveOracle",
    "Combined4626AggregatorV3Oracle": "src/oracle/Combined4626AggregatorV3Oracle.sol:Combined4626AggregatorV3Oracle",
    "CombinedAggregatorV3Oracle": "src/oracle/CombinedAggregatorV3Oracle.sol:CombinedAggregatorV3Oracle",
}

def load_deployment_file(filepath):
    """Load the deployment file JSON."""
    with open(filepath, 'r') as f:
        return json.load(f)

def format_constructor_args(args, contract_name=None):
    """Format constructor arguments for forge verify-contract command."""
    if not args:
        return None

    # Get constructor signature from contract name
    constructor_sig = CONTRACT_CONSTRUCTORS.get(contract_name, "")
    if not constructor_sig:
        print(f"Warning: No constructor signature found for {contract_name}, using raw arguments")
        return " ".join(str(arg) for arg in args)
                
    # Use cast abi-encode to format the arguments
    try:
        command = ["cast", "abi-encode", f"constructor({constructor_sig})"] + [str(arg) for arg in args]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            print(f"Warning: Failed to encode constructor arguments: {result.stderr}")
            return " ".join(str(arg) for arg in args)
    except Exception as e:
        print(f"Warning: Error encoding constructor arguments: {str(e)}")
        return " ".join(str(arg) for arg in args)

def get_contract_path(contract_name, artifact_name):
    """Get the path to the contract source."""
    # Check if we have a custom path for this contract
    if contract_name in CONTRACT_PATHS:
        return CONTRACT_PATHS[contract_name]
    
    # Check if artifact_name contains path info
    if ":" in artifact_name:
        return artifact_name
    
    # Default path based on artifact name
    # This assumes your contracts are in src/ directory with same name as artifact
    return f"src/{artifact_name}.sol:{artifact_name}"

def verify_contract(address, artifact_name, constructor_args, chain_id, etherscan_key, settings):
    """Verify a single contract."""
    try:
        print(f"\nVerifying {artifact_name} at {address}...")
        
        # Get contract path
        print(f"Looking up contract path for {artifact_name}...")
        contract_path = get_contract_path(artifact_name, artifact_name)
        if not contract_path:
            print(f"❌ Contract path not found for {artifact_name}")
            return False, f"Contract path not found for {artifact_name}"
        print(f"Found contract path: {contract_path}")

        # Format constructor arguments
        print("Formatting constructor arguments...")
        formatted_args = format_constructor_args(constructor_args, artifact_name)
        if formatted_args:
            print(f"Formatted constructor args: {formatted_args}")
        
        # Build command
        command = [
        "forge", "verify-contract",
            address,
            contract_path,
        "--chain-id", str(chain_id),
            "--num-of-optimizations", str(settings['optimizer_runs']),
        "--watch"
    ]
    
        if formatted_args:
            command.extend(["--constructor-args", formatted_args])

        # Use etherscan verifier for all chains (including XDC)
        command.extend([
            "--verifier", "etherscan",
            "--etherscan-api-key", etherscan_key,
        ])
        
        command.extend([
            "--compiler-version", f"v{settings['solc_version']}"
        ])

        print(f"Executing command: {' '.join(command)}")
        
        # Set environment variable for forge verify-contract
        env = os.environ.copy()
        env["ETHERSCAN_API_KEY"] = etherscan_key
        
        # Debug: Print environment variables
        print("\nEnvironment variables:")
        print(f"ETHERSCAN_API_KEY in env: {env.get('ETHERSCAN_API_KEY')}")
        print(f"ETHERSCAN_API_KEY in os.environ: {os.environ.get('ETHERSCAN_API_KEY')}")
        
        # Run verification with both environment variable and command line argument
        print("Running forge verify-contract...")
        result = subprocess.run(command, capture_output=True, text=True, env=env)
        
        if result.returncode == 0:
            print(f"✅ Successfully verified {artifact_name}")
            return True, result.stdout
        else:
            print(f"❌ Error verifying {artifact_name}:")
            print(f"Error output: {result.stderr}")
            return False, result.stderr

    except Exception as e:
        print(f"❌ Exception during verification of {artifact_name}: {str(e)}")
        return False, str(e)

def verify_all_contracts(deployment_file, chain_id, etherscan_key, settings, delay=5, specific_address=None):
    """Verify all contracts in the deployment file."""
    print(f"\nLoading deployment file: {deployment_file}")
    data = load_deployment_file(deployment_file)
    if not data:
        return {}, {}

    verified = {}
    failed = {}

    print("\nStarting contract verification process...")
    
    # If specific address is provided, only verify that contract
    if specific_address:
        print(f"\nVerifying specific contract at address: {specific_address}")
        found = False
        
        # Check in core contracts
        if "core" in data:
            print("\nChecking core contracts...")
            for name, contract in data["core"].items():
                if contract.get("address", "").lower() == specific_address.lower():
                    found = True
                    print(f"\nFound matching contract in core: {name}")
                    success, output = verify_contract(
                        contract["address"],
                        contract.get("artifactName", name),
                        contract.get("constructorArguments", contract.get("constructorArgs", [])),
                        chain_id,
                        etherscan_key,
                        settings
                    )
                    if success:
                        verified[name] = contract["address"]
                    else:
                        failed[name] = {"address": contract["address"], "error": output}
                    break
        
        # Check in vaults
        if not found and "vaults" in data:
            print("\nChecking vault contracts...")
            for name, contract in data["vaults"].items():
                if contract.get("address", "").lower() == specific_address.lower():
                    found = True
                    print(f"\nFound matching contract in vaults: {name}")
                    success, output = verify_contract(
                        contract["address"],
                        contract.get("artifactName", name),
                        contract.get("constructorArguments", contract.get("constructorArgs", [])),
                        chain_id,
                        etherscan_key,
                        settings
                    )
                    if success:
                        verified[name] = contract["address"]
                    else:
                        failed[name] = {"address": contract["address"], "error": output}
                    break
        
        # Check in reward managers
        if not found and "rewardManagers" in data:
            print("\nChecking reward manager contracts...")
            for address, contract in data["rewardManagers"].items():
                if contract.get("address", "").lower() == specific_address.lower():
                    found = True
                    print(f"\nFound matching contract in reward managers: {contract.get('vaultName', 'RewardManager')}")
                    success, output = verify_contract(
                        contract["address"],
                        contract.get("artifactName", "RewardManager"),
                        contract.get("constructorArguments", contract.get("constructorArgs", [])),
                        chain_id,
                        etherscan_key,
                        settings
                    )
                    if success:
                        verified[contract.get("vaultName", "RewardManager")] = contract["address"]
                    else:
                        failed[contract.get("vaultName", "RewardManager")] = {"address": contract["address"], "error": output}
                    break
        
        if not found:
            print(f"❌ Error: Contract with address {specific_address} not found in deployment file.")
            return {}, {}
    
    # Otherwise verify all contracts
    else:
        print("\nVerifying all contracts...")
        
        # Process core contracts
        if "core" in data:
            print("\nProcessing core contracts...")
            for name, contract in data["core"].items():
                if not contract.get("address"):
                    print(f"Skipping {name} - no address found")
                    continue
                print(f"\nVerifying core contract: {name}")
                success, output = verify_contract(
                    contract["address"],
                    contract.get("artifactName", name),
                    contract.get("constructorArguments", contract.get("constructorArgs", [])),
                    chain_id,
                    etherscan_key,
                    settings
                )
                if success:
                    verified[name] = contract["address"]
                else:
                    failed[name] = {"address": contract["address"], "error": output}
                
                print(f"Waiting {delay} seconds before next verification...")
                time.sleep(delay)
        
        # Process vaults
        if "vaults" in data:
            print("\nProcessing vault contracts...")
            for name, contract in data["vaults"].items():
                if not contract.get("address"):
                    print(f"Skipping {name} - no address found")
                    continue
                print(f"\nVerifying vault contract: {name}")
                success, output = verify_contract(
                    contract["address"],
                    contract.get("artifactName", name),
                    contract.get("constructorArguments", contract.get("constructorArgs", [])),
                    chain_id,
                    etherscan_key,
                    settings
                )
                if success:
                    verified[name] = contract["address"]
                else:
                    failed[name] = {"address": contract["address"], "error": output}
                
                print(f"Waiting {delay} seconds before next verification...")
                time.sleep(delay)
        
        # Process reward managers
        if "rewardManagers" in data:
            print("\nProcessing reward manager contracts...")
            for address, contract in data["rewardManagers"].items():
                if not contract.get("address"):
                    print(f"Skipping reward manager - no address found")
                    continue
                print(f"\nVerifying reward manager for vault: {contract.get('vaultName', 'Unknown')}")
                success, output = verify_contract(
                    contract["address"],
                    contract.get("artifactName", "RewardManager"),
                    contract.get("constructorArguments", contract.get("constructorArgs", [])),
                    chain_id,
                    etherscan_key,
                    settings
                )
                if success:
                    verified[contract.get("vaultName", "RewardManager")] = contract["address"]
                else:
                    failed[contract.get("vaultName", "RewardManager")] = {"address": contract["address"], "error": output}
                
                print(f"Waiting {delay} seconds before next verification...")
                time.sleep(delay)
        
    print("\nVerification Summary:")
    print(f"Successfully verified: {len(verified)} contracts")
    print(f"Failed to verify: {len(failed)} contracts")
    
    if failed:
        print("\nFailed verifications:")
        for name, info in failed.items():
            print(f"- {name} ({info['address']}): {info['error']}")
    
    return verified, failed

def main():
    parser = argparse.ArgumentParser(description='Verify deployed contracts on Etherscan')
    parser.add_argument('deployment_file', help='Path to the deployment JSON file')
    parser.add_argument('--chain-id', type=int, required=True, help='Chain ID for verification')
    parser.add_argument('--etherscan-key', required=True, help='Etherscan API key')
    parser.add_argument('--delay', type=int, default=5, help='Delay between verifications in seconds')
    parser.add_argument('--address', help='Specific contract address to verify')
    args = parser.parse_args()
    
    # Use default settings
    settings = DEFAULT_SETTINGS
    
    verify_all_contracts(args.deployment_file, args.chain_id, args.etherscan_key, settings, args.delay, args.address)
    
    return 0

if __name__ == "__main__":
    exit(main())
