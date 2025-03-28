// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "src/pendle-rewards/RewardManagerAbstract.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPRBProxy, IPRBProxyRegistry} from "../prb-proxy/interfaces/IPRBProxyRegistry.sol";

interface ILiquidityGaugeV3 {
    function swapBonus() external view returns (address);

    function claimRewards(address account) external;
}

interface ISwapBonus {
    function bonusToken() external view returns (address);
}

contract RewardManagerTranchess is RewardManagerAbstract {
    using PMath for uint256;
    using ArrayLib for uint256[];

    error OnlyVault();

    uint256 public lastRewardBlock;

    mapping(address => RewardState) public rewardState;

    ILiquidityGaugeV3 public immutable market;
    address public immutable vault;
    IPRBProxyRegistry public immutable proxyRegistry;
    address public immutable swapBonusToken;
    address public immutable chess;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address _vault, address _market, address _proxyRegistry, address _chess) {
        market = ILiquidityGaugeV3(_market);
        vault = _vault;
        proxyRegistry = IPRBProxyRegistry(_proxyRegistry);
        chess = _chess;
        swapBonusToken = ISwapBonus(market.swapBonus()).bonusToken();
    }

    function _updateRewardIndex()
        internal
        virtual
        override
        returns (address[] memory tokens, uint256[] memory indexes)
    {
        if (swapBonusToken == chess) {
            indexes = new uint256[](1);
            tokens = new address[](1);
            tokens[0] = chess;
        } else {
            indexes = new uint256[](2);
            tokens = new address[](2);
            tokens[0] = chess;
            tokens[1] = swapBonusToken;
        }

        if (lastRewardBlock != block.number) {
            // if we have not yet update the index for this block
            lastRewardBlock = block.number;

            uint256 totalShares = _rewardSharesTotal();
            // Claim external rewards on Market
            market.claimRewards(address(vault));

            for (uint256 i = 0; i < tokens.length; ++i) {
                address token = tokens[i];

                if (token == address(market)) continue;
                // the entire token balance of the contract must be the rewards of the contract

                RewardState memory _state = rewardState[token];
                (uint256 lastBalance, uint256 index) = (_state.lastBalance, _state.index);

                uint256 accrued = IERC20(tokens[i]).balanceOf(vault) - lastBalance;
                uint256 deltaIndex;
                uint256 advanceBalance;
                if (totalShares != 0) {
                    deltaIndex = accrued.divDown(totalShares);
                    advanceBalance = deltaIndex.mulDown(totalShares);
                }
                if (index == 0) index = INITIAL_REWARD_INDEX;
                if (totalShares != 0) index += deltaIndex;

                rewardState[token] = RewardState({
                    index: index.Uint128(),
                    lastBalance: (lastBalance + advanceBalance).Uint128()
                });

                indexes[i] = index;
            }
        } else {
            for (uint256 i = 0; i < tokens.length; i++) {
                indexes[i] = rewardState[tokens[i]].index;
            }
        }
    }

    /// @dev this function doesn't need redeemExternal since redeemExternal is bundled in updateRewardIndex
    /// @dev this function also has to update rewardState.lastBalance
    function _doTransferOutRewards(
        address user
    ) internal virtual override returns (address[] memory tokens, uint256[] memory rewardAmounts, address to) {
        if (swapBonusToken == chess) {
            tokens = new address[](1);
            tokens[0] = chess;
        } else {
            tokens = new address[](2);
            tokens[0] = chess;
            tokens[1] = swapBonusToken;
        }
        rewardAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            rewardAmounts[i] = userReward[tokens[i]][user].accrued;
            if (rewardAmounts[i] != 0) {
                userReward[tokens[i]][user].accrued = 0;
                rewardState[tokens[i]].lastBalance -= rewardAmounts[i].Uint128();
                //_transferOut(tokens[i], receiver, rewardAmounts[i]);
            }
        }

        if (proxyRegistry.isProxy(user)) {
            to = IPRBProxy(user).owner();
        } else {
            to = user;
        }
        return (tokens, rewardAmounts, to);
    }

    function _rewardSharesTotal() internal view virtual returns (uint256) {
        return _totalShares;
    }

    function handleRewardsOnDeposit(
        address user,
        uint collateralAmountBefore,
        int256 deltaCollateral
    ) external virtual onlyVault {
        _updateAndDistributeRewards(user, collateralAmountBefore, deltaCollateral);
    }

    function handleRewardsOnWithdraw(
        address user,
        uint collateralAmountBefore,
        int256 deltaCollateral
    ) external virtual onlyVault returns (address[] memory tokens, uint256[] memory amounts, address to) {
        _updateAndDistributeRewards(user, collateralAmountBefore, deltaCollateral);
        return _doTransferOutRewards(user);
    }
}
