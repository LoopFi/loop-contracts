// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

enum ApprovalType {
    STANDARD,
    PERMIT,
    PERMIT2
}

struct PermitParams {
    ApprovalType approvalType;
    uint256 approvalAmount;
    uint256 nonce;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

abstract contract TransferAction {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Permit;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Permit2
    address public constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TransferAction__transferFrom_notEnoughAllowance();

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Perform a permit2, a ERC20 permit transferFrom, or a standard transferFrom
    function _transferFrom(
        address token,
        address from,
        address to,
        uint256 amount,
        PermitParams memory params
    ) internal {
        if (params.approvalType == ApprovalType.PERMIT2) {
            // Consume a permit2 message and transfer tokens.
            ISignatureTransfer(permit2).permitTransferFrom(
                ISignatureTransfer.PermitTransferFrom({
                    permitted: ISignatureTransfer.TokenPermissions({token: token, amount: params.approvalAmount}),
                    nonce: params.nonce,
                    deadline: params.deadline
                }),
                ISignatureTransfer.SignatureTransferDetails({to: to, requestedAmount: amount}),
                from,
                bytes.concat(params.r, params.s, bytes1(params.v)) // Construct signature
            );
        } else if (params.approvalType == ApprovalType.PERMIT) {
            // Consume a standard ERC20 permit message
            uint256 nonceBefore = IERC20Permit(token).nonces(from);
            try IERC20Permit(token).permit(
                from,
                to,
                params.approvalAmount,
                params.deadline,
                params.v,
                params.r,
                params.s
            ){
                uint256 nonceAfter = IERC20Permit(token).nonces(from);
                // if the nonce is not incremented by 1, then the permit is invalid
                // we can check the allowance to make sure the transfer will work
                if (nonceAfter != nonceBefore + 1) {
                    if(IERC20(token).allowance(from, to) < params.approvalAmount) 
                        revert TransferAction__transferFrom_notEnoughAllowance();
                }
            }
            catch{
                // if the permit reverts, we can check the allowance to make sure the transfer will work
                if(IERC20(token).allowance(from, to) < params.approvalAmount) 
                    revert TransferAction__transferFrom_notEnoughAllowance();
            }
            IERC20(token).safeTransferFrom(from, to, amount);
        } else {
            // No signature provided, just transfer tokens.
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }
}
