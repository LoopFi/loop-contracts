#!/usr/bin/env python3

import json
import os
import subprocess
import argparse
import time
from pathlib import Path

# Default compiler settings
DEFAULT_SETTINGS = {
    "optimizer": True,
    "optimizer_runs": 100,
    "solc_version": "0.8.19",
    "evm_version": "cancun"
}

# Contract path mappings - add your custom paths here
CONTRACT_PATHS = {
    # Format: "ContractName": "path/to/Contract.sol:ContractName"
    
    # Core contracts
    "LinearInterestRateModelV3": "lib/core-v3/contracts/pool/LinearInterestRateModelV3.sol:LinearInterestRateModelV3",
    "ACL": "lib/core-v2/contracts/core/ACL.sol:ACL",
    
    # Reward managers
    "RewardManager": "src/pendle-rewards/RewardManager.sol:RewardManager",
    "RewardManagerSpectra": "src/spectra-rewards/RewardManagerSpectra.sol:RewardManagerSpectra",
    
    # Spectra contracts
    "CDPVaultSpectra": "src/CDPVaultSpectra.sol:CDPVaultSpectra",
    "CDPVault_Vaults_deUSD": "src/CDPVaultSpectra.sol:CDPVaultSpectra",
    "SpectraYnETHOracle": "src/oracle/SpectraYnETHOracle.sol:SpectraYnETHOracle",
    
    # Core system contracts
    "AddressProviderV3": "src/AddressProviderV3.sol:AddressProviderV3",
    "ContractsRegister": "src/ContractsRegister.sol:ContractsRegister",
    "PoolV3": "src/PoolV3.sol:PoolV3",
    "VaultRegistry": "src/VaultRegistry.sol:VaultRegistry",
    "CDPVault": "src/vaults/CDPVault.sol:CDPVault",
    "Treasury": "src/Treasury.sol:Treasury",
    "PoolQuotaKeeperV3": "src/quotas/PoolQuotaKeeperV3.sol:PoolQuotaKeeperV3",
    
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
    "StakingLPEth": "src/StakingLPEth.sol:StakingLPEth",
    "Locking": "src/Locking.sol:Locking",
    
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
    """Format constructor arguments for the verify command."""
    if not args:
        return ""
    
    # Special case for known contracts with complex constructor arguments
    if contract_name == "CDPVaultSpectra" or contract_name.startswith("CDPVault_"):
        # We know this contract takes two structs as arguments
        if len(args) == 2 and isinstance(args[0], list) and isinstance(args[1], list):
            try:
                # Format the structs properly with parentheses
                struct1 = ",".join([str(x) for x in args[0]])
                struct2 = ",".join([str(x) for x in args[1]])
                
                # Run the cast command with properly formatted structs
                cmd = [
                    "cast", "abi-encode",
                    "constructor((address,address,address,uint256),(uint128,uint64,uint64,uint64,address,address,address))",
                    f"({struct1})", f"({struct2})"
                ]
                
                print(f"Running encode command: {' '.join(cmd)}")
                encoded_args = subprocess.check_output(cmd, text=True).strip()
                
                return f"--constructor-args {encoded_args}"
            except subprocess.CalledProcessError as e:
                print(f"Error encoding complex arguments for CDPVault: {e}")
                print(f"Args: {args}")
                print(f"Error output: {e.stderr if hasattr(e, 'stderr') else e.output}")
                
                # Try a fallback approach with explicit constructor-args-data
                try:
                    print("Attempting fallback encoding approach...")
                    # This is a manual approach to create the ABI-encoded constructor arguments
                    # Format: address fields are padded to 32 bytes, numeric values are right-aligned in 32 bytes
                    
                    # Extract constructor parameters
                    pool, oracle, token, tokenScale = args[0]
                    debtFloor, liquidationRatio, liquidationPenalty, liquidationDiscount, roleAdmin, vaultAdmin, pauseAdmin = args[1]
                    
                    # Remove '0x' prefix for encoding
                    pool = pool[2:].lower()
                    oracle = oracle[2:].lower()
                    token = token[2:].lower()
                    roleAdmin = roleAdmin[2:].lower()
                    vaultAdmin = vaultAdmin[2:].lower()
                    pauseAdmin = pauseAdmin[2:].lower()
                    
                    # Create a manual encoding for these arguments
                    manual_encoding = f"0x" + \
                        "0"*24 + pool + \
                        "0"*24 + oracle + \
                        "0"*24 + token + \
                        tokenScale.zfill(64) + \
                        debtFloor.zfill(64) + \
                        liquidationRatio.zfill(64) + \
                        liquidationPenalty.zfill(64) + \
                        liquidationDiscount.zfill(64) + \
                        "0"*24 + roleAdmin + \
                        "0"*24 + vaultAdmin + \
                        "0"*24 + pauseAdmin
                    
                    return f"--constructor-args-data {manual_encoding}"
                except Exception as manual_error:
                    print(f"Fallback encoding also failed: {manual_error}")
                    return ""
    
    # For regular arguments, use auto-detection of types
    args_str = []
    arg_types = []
    
    for arg in args:
        if isinstance(arg, bool) or arg == "true" or arg == "false" or arg == "True" or arg == "False":
            # Handle boolean values
            arg_types.append("bool")
            # Convert to lowercase "true" or "false" for cast
            if isinstance(arg, str):
                args_str.append(arg.lower())
            else:
                args_str.append("true" if arg else "false")
        elif isinstance(arg, str) and arg.startswith("0x"):
            # Handle address or bytes
            if len(arg) == 42:  # Standard Ethereum address length
                arg_types.append("address")
            else:
                arg_types.append("bytes")
            args_str.append(arg)
        elif isinstance(arg, (int, str)) and str(arg).isdigit():
            # Handle integers
            arg_types.append("uint256")
            args_str.append(str(arg))
        else:
            # Default to string for other types
            arg_types.append("string")
            # Escape quotes in string values
            arg_value = str(arg).replace('"', '\\"')
            args_str.append(f'"{arg_value}"')
    
    try:
        # For complex arguments, construct the proper types signature
        encoded_args = subprocess.check_output(
            ["cast", "abi-encode", f"constructor({','.join(arg_types)})", *args_str],
            text=True
        ).strip()
        
        return f"--constructor-args {encoded_args}"
    except subprocess.CalledProcessError as e:
        print(f"Error: Could not ABI encode the function and arguments. Details: {e}")
        print(f"Command: cast abi-encode constructor({','.join(arg_types)}) {' '.join(args_str)}")
        print(f"Args: {args}")
        print(f"Error output: {e.stderr if e.stderr else e.output}")
        return ""

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
    """Run forge verify-contract for a single contract."""
    contract_name = artifact_name.split(":")[-1] if ":" in artifact_name else artifact_name
    contract_path = get_contract_path(contract_name, artifact_name)
    
    # Prepare the basic command
    cmd = [
        "forge", "verify-contract",
        "--chain-id", str(chain_id),
        "--compiler-version", f"v{settings['solc_version']}",
        "--num-of-optimizations", str(settings["optimizer_runs"]),
        "--evm-version", settings["evm_version"],
        "--watch"
    ]
    
    # Add constructor args if present
    if constructor_args:
        if isinstance(constructor_args, list):
            args_str = format_constructor_args(constructor_args, contract_name)
            if args_str:
                cmd.extend(args_str.split())
        else:
            # If constructor_args is a pre-formatted string
            cmd.extend(["--constructor-args", constructor_args])
    
    # Add the etherscan key
    cmd.extend(["--etherscan-api-key", etherscan_key])
    
    # Add the contract address and path
    cmd.extend([address, contract_path])
    
    print(f"Verifying {contract_name} at {address}...")
    print(f"Command: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(cmd, check=True, text=True, capture_output=True)
        print(result.stdout)
        if "Successfully verified" in result.stdout:
            return True, result.stdout
        return False, result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error verifying {contract_name}: {e}")
        print(e.stderr if e.stderr else "")
        return False, e.stderr if e.stderr else ""

def verify_all_contracts(deployment_file, chain_id, etherscan_key, settings, delay=5, specific_address=None):
    """Verify all contracts in the deployment file or a specific contract."""
    data = load_deployment_file(deployment_file)
    verified = {}
    failed = {}
    
    # If specific address is provided, only verify that contract
    if specific_address:
        specific_address = specific_address.lower()
        found = False
        
        # Check in core contracts
        if "core" in data:
            for name, contract in data["core"].items():
                if contract.get("address", "").lower() == specific_address:
                    found = True
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
            for name, contract in data["vaults"].items():
                if contract.get("address", "").lower() == specific_address:
                    found = True
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
            for address, contract in data["rewardManagers"].items():
                if contract.get("address", "").lower() == specific_address:
                    found = True
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
            print(f"Error: Contract with address {specific_address} not found in deployment file.")
            return {}, {}
    
    # Otherwise verify all contracts (existing code)
    else:
        # Process core contracts
        if "core" in data:
            for name, contract in data["core"].items():
                if not contract.get("address"):
                    continue
                    
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
                
                # Delay between verifications to avoid rate limiting
                time.sleep(delay)
        
        # Process vaults
        if "vaults" in data:
            for name, contract in data["vaults"].items():
                if not contract.get("address"):
                    continue
                    
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
                
                time.sleep(delay)
        
        # Process reward managers
        if "rewardManagers" in data:
            for address, contract in data["rewardManagers"].items():
                if not contract.get("address"):
                    continue
                    
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
                
                time.sleep(delay)
        
        # Process any other contract categories
        # Add them here as needed...
    
    # Print summary
    print("\n--- VERIFICATION SUMMARY ---")
    print(f"Verified: {len(verified)} contracts")
    for name, address in verified.items():
        print(f"✅ {name}: {address}")
    
    print(f"\nFailed: {len(failed)} contracts")
    for name, data in failed.items():
        print(f"❌ {name}: {data['address']}")
    
    return verified, failed

def main():
    parser = argparse.ArgumentParser(description="Verify smart contracts on Etherscan using Forge")
    parser.add_argument("deployment_file", help="Path to deployment JSON file")
    parser.add_argument("--chain-id", type=int, default=1, help="Chain ID (default: 1 for Ethereum mainnet)")
    parser.add_argument("--etherscan-key", help="Etherscan API key (or set ETHERSCAN_API_KEY env variable)")
    parser.add_argument("--optimizer", type=bool, default=DEFAULT_SETTINGS["optimizer"], help="Enable optimizer")
    parser.add_argument("--optimizer-runs", type=int, default=DEFAULT_SETTINGS["optimizer_runs"], help="Optimizer runs")
    parser.add_argument("--solc-version", default=DEFAULT_SETTINGS["solc_version"], help="Solidity compiler version")
    parser.add_argument("--evm-version", default=DEFAULT_SETTINGS["evm_version"], help="EVM version")
    parser.add_argument("--delay", type=int, default=5, help="Delay between verifications in seconds")
    parser.add_argument("--address", help="Verify only the contract at this address")
    
    args = parser.parse_args()
    
    # Use environment variable if API key not provided
    etherscan_key = args.etherscan_key or os.environ.get("ETHERSCAN_API_KEY")
    if not etherscan_key:
        print("Error: Etherscan API key required. Provide with --etherscan-key or set ETHERSCAN_API_KEY env variable.")
        return 1
    
    settings = {
        "optimizer": args.optimizer,
        "optimizer_runs": args.optimizer_runs,
        "solc_version": args.solc_version,
        "evm_version": args.evm_version
    }
    
    verify_all_contracts(args.deployment_file, args.chain_id, etherscan_key, settings, args.delay, args.address)
    
    return 0

if __name__ == "__main__":
    exit(main())
