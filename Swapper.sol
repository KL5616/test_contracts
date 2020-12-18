
// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/math/SafeMath.sol";
import "https://github.com/KL5616/FRACTALS2/blob/main/FRACTAL.sol";

contract Swapper {
    using SafeMath for uint256;
    IUniswapV2Router02 public immutable _uniswapV2Router;
    FRACTAL private _tokenContract;

    constructor(FRACTAL tokenContract, IUniswapV2Router02 uniswapV2Router) public {
        _tokenContract = tokenContract;
        _uniswapV2Router = uniswapV2Router;
    }

    function swapTokens(address pairTokenAddress, uint256 tokenAmount) external {
        uint256 initialPairTokenBalance = IERC20(pairTokenAddress).balanceOf(address(this));
        swapTokensForTokens(pairTokenAddress, tokenAmount);
        uint256 newPairTokenBalance = IERC20(pairTokenAddress).balanceOf(address(this)).sub(initialPairTokenBalance);
        IERC20(pairTokenAddress).transfer(address(_tokenContract), newPairTokenBalance);
    }

    function swapTokensForTokens(address pairTokenAddress, uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(_tokenContract);
        path[1] = pairTokenAddress;

        _tokenContract.approve(address(_uniswapV2Router), tokenAmount);

        // make the swap
        _uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of pair token
            path,
            address(this),
            block.timestamp
        );
    }
}
