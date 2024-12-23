// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "src/pendle-rewards/RewardManagerAbstract.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPRBProxy, IPRBProxyRegistry} from "../prb-proxy/interfaces/IPRBProxyRegistry.sol";

interface IMasterPenpie {
    struct PoolInfo {
        address stakingToken; // Address of staking token contract to be staked.
        address receiptToken; // Address of receipt token contract represent a staking position
        uint256 allocPoint; // How many allocation points assigned to this pool. Penpies to distribute per second.
        uint256 lastRewardTimestamp; // Last timestamp that Penpies distribution occurs.
        uint256 accPenpiePerShare; // Accumulated Penpies per share, times 1e12. See below.
        uint256 totalStaked;
        address rewarder;
        bool isActive; // if the pool is active
    }

    function multiclaimFor(
        address[] calldata _stakingTokens,
        address[][] memory _rewardTokens,
        address _account
    ) external;

    function tokenToPoolInfo(address _token) external view returns (PoolInfo memory);
}
interface IRewarder {
    function rewardTokenInfos() external view returns (address[] memory, string[] memory);
}

/// NOTE: RewardManager must not have duplicated rewardTokens
contract RewardManagerPenpie is RewardManagerAbstract {
    using PMath for uint256;
    using ArrayLib for uint256[];

    error OnlyVault();

    uint256 public lastRewardBlock;

    mapping(address => RewardState) public rewardState;

    IMasterPenpie public immutable masterPenpie;
    address public immutable vault;
    address public immutable stakingToken;
    IPRBProxyRegistry public immutable proxyRegistry;
    address public immutable rewarder;
    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address _vault, address _masterPenpie, address _stakingToken, address _proxyRegistry) {
        masterPenpie = IMasterPenpie(_masterPenpie);
        vault = _vault;
        stakingToken = _stakingToken;
        IMasterPenpie.PoolInfo memory poolInfo = masterPenpie.tokenToPoolInfo(stakingToken);
        rewarder = poolInfo.rewarder;
        proxyRegistry = IPRBProxyRegistry(_proxyRegistry);
    }

    function _updateRewardIndex()
        internal
        virtual
        override
        returns (address[] memory tokens, uint256[] memory indexes)
    {
        //  (, tokens, , ) = masterPenpie.allPendingTokens(stakingToken, vault);
        (tokens, ) = IRewarder(rewarder).rewardTokenInfos();
        indexes = new uint256[](tokens.length);

        if (tokens.length == 0) return (tokens, indexes);

        if (lastRewardBlock != block.number) {
            // if we have not yet update the index for this block
            lastRewardBlock = block.number;

            uint256 totalShares = _rewardSharesTotal();
            address[] memory stakingTokens = new address[](1);
            stakingTokens[0] = stakingToken;
            address[][] memory rewardTokens = new address[][](1);
            // Claim external rewards
            masterPenpie.multiclaimFor(stakingTokens, rewardTokens, vault);
            for (uint256 i = 0; i < tokens.length; ++i) {
                address token = tokens[i];

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
        (tokens, ) = IRewarder(rewarder).rewardTokenInfos();

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
