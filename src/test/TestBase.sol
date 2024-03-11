// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;


import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ICDM} from "../interfaces/ICDM.sol";
import {ICDPVault, ICDPVaultBase, CDPVaultConfig, CDPVaultConstants} from "../interfaces/ICDPVault.sol";
import {IFlashlender} from "../interfaces/IFlashlender.sol";
import {CDPVault} from "../CDPVault.sol";

import {PatchedDeal} from "./utils/PatchedDeal.sol";
import {Stablecoin, MINTER_AND_BURNER_ROLE} from "../Stablecoin.sol";
import {CDM, getCredit, getDebt, getCreditLine, ACCOUNT_CONFIG_ROLE} from "../CDM.sol";
import {Minter} from "../Minter.sol";
import {Flashlender} from "../Flashlender.sol";
import {Buffer} from "../Buffer.sol";

import {MockOracle} from "./MockOracle.sol";

import {WAD, wdiv} from "../utils/Math.sol";
import {CDM} from "../CDM.sol";

contract CreditCreator {
    constructor(ICDM cdm) {
        cdm.modifyPermission(msg.sender, true);
    }
}

contract TestBase is Test {

    CDM internal cdm;
    Stablecoin internal stablecoin;
    Minter internal minter;
    Buffer internal buffer;

    ProxyAdmin internal bufferProxyAdmin;

    IFlashlender internal flashlender;

    ERC20PresetMinterPauser internal token;
    MockOracle internal oracle;

    uint256[] internal timestamps;
    uint256 public currentTimestamp;

    PatchedDeal internal dealManager;
    bool public usePatchedDeal = false;

    uint256 internal constant initialGlobalDebtCeiling = 100_000_000_000 ether;

    CreditCreator private creditCreator;

    struct CDPAccessParams {
        address roleAdmin;
        address vaultAdmin;
        address tickManager;
        address pauseAdmin;
        address vaultUnwinder;
    }

    modifier useCurrentTimestamp() virtual {
        vm.warp(currentTimestamp);
        _;
    }

    function createAccounts() internal virtual {}

    function createAssets() internal virtual {
        token = new ERC20PresetMinterPauser("TestToken", "TST");
    }

    function createOracles() internal virtual {
        oracle = new MockOracle();
        setOraclePrice(WAD);
    }

    function createCore() internal virtual {
        cdm = new CDM(address(this), address(this), address(this));
        setGlobalDebtCeiling(initialGlobalDebtCeiling);
        stablecoin = new Stablecoin();
        minter = new Minter(cdm, stablecoin, address(this), address(this));
        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, address(minter));
        flashlender = new Flashlender(minter, 0);
        cdm.setParameter(address(flashlender), "debtCeiling", uint256(type(int256).max));
        bufferProxyAdmin = new ProxyAdmin();
        buffer = Buffer(address(new TransparentUpgradeableProxy(
            address(new Buffer(cdm)),
            address(bufferProxyAdmin),
            abi.encodeWithSelector(Buffer.initialize.selector, address(this), address(this))
        )));
        cdm.setParameter(address(buffer), "debtCeiling", initialGlobalDebtCeiling);

        // create an unbound credit line to use for testing        
        creditCreator = new CreditCreator(cdm);
        cdm.setParameter(address(creditCreator), "debtCeiling", uint256(type(int256).max));
    }

    function createCDPVault(
        IERC20 token_,
        uint256 debtCeiling,
        uint128 debtFloor,
        uint64 liquidationRatio,
        uint64 liquidationPenalty,
        uint64 liquidationDiscount,
        uint256 baseRate
    ) internal returns (CDPVault) {
        return createCDPVault(
            CDPVaultConstants({
                cdm: cdm,
                oracle: oracle,
                buffer: buffer,
                token: token_,
                tokenScale: 10**IERC20Metadata(address(token_)).decimals()

            }),
            CDPVaultConfig({
                debtFloor: debtFloor,
                liquidationRatio: liquidationRatio,
                liquidationPenalty: liquidationPenalty,
                liquidationDiscount: liquidationDiscount,
                baseRate: baseRate,
                roleAdmin: address(this),
                vaultAdmin: address(this),
                pauseAdmin: address(this),
                vaultUnwinder: address(this)
            }),
            debtCeiling
        );
    }

    function createCDPVault(
        CDPVaultConstants memory constants,
        CDPVaultConfig memory configs,
        uint256 debtCeiling
    ) internal returns (CDPVault vault) {
        vault = new CDPVault(constants, configs);

        if (debtCeiling > 0) {
            constants.cdm.setParameter(address(vault), "debtCeiling", debtCeiling);
        }

        cdm.modifyPermission(address(vault), true);

        (int256 balance, uint256 debtCeiling_) = cdm.accounts(address(vault));
        assertEq(balance, 0);
        assertEq(debtCeiling_, debtCeiling);

        vm.label({account: address(vault), newLabel: "CDPVault"});
    }
    
    function labelContracts() internal virtual {
        vm.label({account: address(cdm), newLabel: "CDM"});
        vm.label({account: address(stablecoin), newLabel: "Stablecoin"});
        vm.label({account: address(minter), newLabel: "Minter"});
        vm.label({account: address(flashlender), newLabel: "Flashlender"});
        vm.label({account: address(buffer), newLabel: "Buffer"});
        vm.label({account: address(token), newLabel: "CollateralToken"});
        vm.label({account: address(oracle), newLabel: "Oracle"});
    }

    function setCurrentTimestamp(uint256 currentTimestamp_) public {
        timestamps.push(currentTimestamp_);
        currentTimestamp = currentTimestamp_;
    }

    function setGlobalDebtCeiling(uint256 _globalDebtCeiling) public {
        cdm.setParameter("globalDebtCeiling", _globalDebtCeiling);
    }

    function setOraclePrice(uint256 price) public {
        oracle.updateSpot(address(token), price);
    }

    function createCredit(address to, uint256 amount) public {
        cdm.modifyBalance(address(creditCreator), to, amount);
    }

    function credit(address account) internal view returns (uint256) {
        (int256 balance,) = cdm.accounts(account);
        return getCredit(balance);
    }

    function debt(address account) internal view returns (uint256) {
        (int256 balance,) = cdm.accounts(account);
        return getDebt(balance);
    }

    function creditLine(address account) internal view returns (uint256) {
        (int256 balance, uint256 debtCeiling) = cdm.accounts(account);
        return getCreditLine(balance, debtCeiling);
    }

    function liquidationPrice(ICDPVaultBase vault_) internal returns (uint256) {
        (, uint64 liquidationRatio_) = vault_.vaultConfig();
        return wdiv(vault_.spotPrice(), uint256(liquidationRatio_));
    }

    function _getDefaultVaultConstants() internal view returns (CDPVaultConstants memory) {
        return CDPVaultConstants({
            cdm: cdm,
            oracle: oracle,
            buffer: buffer,
            token: token,
            tokenScale: 10**IERC20Metadata(address(token)).decimals()
        });
    }

    function _getDefaultVaultConfig() internal view returns (CDPVaultConfig memory) {
        return CDPVaultConfig({
            debtFloor: 0,
            liquidationRatio: 1.25 ether,
            baseRate: WAD,
            liquidationPenalty: uint64(WAD),
            liquidationDiscount: uint64(WAD),
            roleAdmin: address(this),
            vaultAdmin: address(this),
            pauseAdmin: address(this),
            vaultUnwinder: address(this)
        });
    }

    function setUp() public virtual {
        dealManager = new PatchedDeal();
        setCurrentTimestamp(block.timestamp);

        createAccounts();
        createAssets();
        createOracles();
        createCore();
        labelContracts();
    }

    function getContracts() public view returns (address[] memory contracts) {
        contracts = new address[](7);
        contracts[0] = address(cdm);
        contracts[1] = address(stablecoin);
        contracts[2] = address(minter);
        contracts[3] = address(buffer);
        contracts[5] = address(flashlender);
        contracts[6] = address(token);
    }

    function deal(address token_, address to, uint256 amount) virtual override internal {
        if (usePatchedDeal) {
            uint256 chainId = block.chainid;
            vm.chainId(1);
            dealManager.deal2(token_, to, amount);
            vm.chainId(chainId);
        } else {
            super.deal(token_, to, amount);
        }
    }
}
