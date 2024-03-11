/**
 *Submitted for verification at basescan.org on 2024-01-13
*/

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interface/IERC20.sol";
import "./interface/ISwapRouter.sol";
import "./interface/IStargateRouter.sol";

contract ChainPing is IStargateRouter {
    uint256 public blockTimeStamp;
    address public owner;
    address public stargateRouter;
    ISwapRouter public swapRouter;

    event Swap(address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event ReceivedOnDestination(address token, uint256 amountLD, bool success);

    modifier onlyOwner {
        require(owner == msg.sender, "Invalid Owner");
        _;
    }

    constructor(address _stargateRouter, ISwapRouter _swapRouter) {
        owner = msg.sender;
        stargateRouter = _stargateRouter;
        swapRouter = _swapRouter;
        blockTimeStamp = 3600;
    }

    receive() external payable {}

    function balanceOf(address token) public view returns(uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function setBlockTimeStamp(uint256 _blockTimeStamp) external onlyOwner {
        blockTimeStamp = _blockTimeStamp;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
    }

    function setRouter(address _stargateRouter) external onlyOwner {
        stargateRouter = _stargateRouter;
    }

    function setSwapRouter(ISwapRouter _swapRouter) public onlyOwner{
        swapRouter = _swapRouter;
    }

    function rescueFunds(address token) public onlyOwner {
        if (token == address(0)) {
            payable(msg.sender).transfer(address(this).balance);
        } else {
            IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
        }
    }

    function approve(address token, uint256 amount) public onlyOwner {
        IERC20(token).approve(msg.sender, 0);
        IERC20(token).approve(msg.sender, amount);
    }

    /// @param _chainId The remote chainId sending the tokens
    /// @param _srcAddress The remote Bridge address
    /// @param _nonce The message ordering nonce
    /// @param _token The token contract on the local chain
    /// @param amountLD The qty of local _token contract tokens
    /// @param _payload The bytes containing the toAddress
    function sgReceive(
        uint16 _chainId,
        bytes memory _srcAddress,
        uint _nonce,
        address _token,
        uint amountLD,
        bytes memory _payload
    ) override external {
        require(
            msg.sender == address(stargateRouter) || msg.sender == owner,
            "only stargate router and owner can call sgReceive!"
        );
        (bool isSwap) = abi.decode(_payload, (bool));
        if (isSwap) {
            withSwap(_token, amountLD, _payload);
        } else {
            withoutSwap(_token, amountLD, _payload);
        }
    }

    function withoutSwap(address _token, uint amountLD, bytes memory _payload) internal {
        (
            ,,,uint256 nativeFee,
            uint256 _amount,
            address _to,
            address _user,
            address _extraOrShareToken,
            bytes memory txData
        ) = abi.decode(_payload, (
            bool, address, bytes, uint256,
            uint256, address, address, address, bytes
        ));

        bool success;
        if (txData.length == 0) {
            IERC20(_token).transfer(_user, amountLD);
            success = true;
        } else {
            IERC20(_token).approve(_to, amountLD);
            uint256 beforeTokens;
            if (_extraOrShareToken != address(0)) beforeTokens = IERC20(_extraOrShareToken).balanceOf(address(this));

            if (amountLD >= _amount) {
                if (nativeFee > 0) {
                    (success, ) = _to.call{value: nativeFee}(txData);
                } else {
                    (success, ) = _to.call(txData);
                }
            }

            uint256 anyDust;
            if (!success) {
                IERC20(_token).approve(_to, 0);
                anyDust = amountLD;
            } else if (amountLD > _amount) {
                anyDust = amountLD - _amount;
            }

            if (anyDust > 0) IERC20(_token).transfer(_user, anyDust);
            if (success && _extraOrShareToken != address(0)) {
                uint256 afterTokens = IERC20(_extraOrShareToken).balanceOf(address(this));
                if (afterTokens > beforeTokens) {
                    IERC20(_extraOrShareToken).transfer(_user, afterTokens-beforeTokens);
                }
            }
        }
        emit ReceivedOnDestination(_token, amountLD, success);
    }

    function withSwap(
        address _token,
        uint amountLD,
        bytes memory _payload
    ) internal {
        (
            ,
            address _tokenOut,
            bytes memory swapTxData
            ,,,,
            address _user
            ,,
        ) = abi.decode(_payload, (
            bool, address, bytes, uint256,
            uint256, address, address, address, bytes
        ));
        uint256 amountBefore = IERC20(_tokenOut).balanceOf(address(this));
        swap(_token, _tokenOut, _user, amountLD, swapTxData);
        uint256 amountAfter = IERC20(_tokenOut).balanceOf(address(this));
        withoutSwap(_tokenOut, amountAfter - amountBefore, _payload);
    }

    function swap(
        address _tokenIn,
        address _tokenOut,
        address _user,
        // uint24 _poolFee,
        uint256 _amount,
        bytes memory txData
    ) internal returns(uint256 amountOut) {
        IERC20(_tokenIn).approve(address(swapRouter), _amount);
        (bool success, ) = address(swapRouter).call(txData);
        if (!success) IERC20(_tokenIn).transfer(_user, _amount);
        emit Swap(_tokenIn, _tokenOut, _amount, amountOut);
    }
}