// SPDX-License-Identifier:MIT
pragma solidity ^0.6.2;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@opengsn/gsn/contracts/forwarder/IForwarder.sol";
import "@opengsn/gsn/contracts/BasePaymaster.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/**
 * A Token-based paymaster.
 * - each request is paid for by the caller.
 * - acceptRelayedCall - verify the caller can pay for the request in tokens.
 * - preRelayedCall - pre-pay the maximum possible price for the tx
 * - postRelayedCall - refund the caller for the unused gas
 */
contract TokenPaymaster is BasePaymaster {
    using SafeMath for uint256;

    function versionPaymaster()
        external
        view
        virtual
        override
        returns (string memory)
    {
        return "2.0.0+opengsn.token.ipaymaster";
    }

    IUniswapV2Router02 public immutable uniV2Router02;

    uint256 public gasUsedByPost;

    constructor(IUniswapV2Router02 router) public {
        uniV2Router02 = router;
    }

    /**
     * set gas used by postRelayedCall, for proper gas calculation.
     * You can use TokenGasCalculator to calculate these values (they depend on actual code of postRelayedCall,
     * but also the gas usage of the token and of Uniswap)
     */
    function setPostGasUsage(uint256 _gasUsedByPost) external onlyOwner {
        gasUsedByPost = _gasUsedByPost;
    }

    // return the payer of this request.
    // for account-based target, this is the target account.
    function getPayer(GsnTypes.RelayRequest calldata relayRequest)
        public
        view
        virtual
        returns (address)
    {
        (this);
        return relayRequest.request.from;
    }

    event Received(uint256 eth);

    receive() external payable override {
        emit Received(msg.value);
    }

    function bytesToAddress(bytes memory bys)
        private
        pure
        returns (address addr)
    {
        assembly {
            addr := mload(add(bys, 20))
        }
    }

    function _getToken(bytes memory paymasterData)
        internal
        view
        returns (IERC20 token, IUniswapV2Pair pair)
    {
        require(
            paymasterData.length > 0,
            "invalid uniswap address in paymasterData"
        );
        pair = IUniswapV2Pair(bytesToAddress(paymasterData));
        if (pair.token0() != uniV2Router02.WETH()) {
            token = IERC20(pair.token0());
        } else {
            token = IERC20(pair.token1());
        }
    }

    function _calculatePreCharge(
        IERC20 token,
        IUniswapV2Pair pair,
        GsnTypes.RelayRequest calldata relayRequest,
        uint256 maxPossibleGas
    ) internal view returns (address payer, uint256 tokenPreCharge) {
        (token);
        payer = this.getPayer(relayRequest);
        uint256 ethMaxCharge =
            relayHub.calculateCharge(maxPossibleGas, relayRequest.relayData);
        ethMaxCharge += relayRequest.request.value;
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (pair.token0() == uniV2Router02.WETH()) {
            tokenPreCharge = uniV2Router02.getAmountIn(
                ethMaxCharge,
                reserve1,
                reserve0
            );
        } else {
            tokenPreCharge = uniV2Router02.getAmountIn(
                ethMaxCharge,
                reserve0,
                reserve1
            );
        }
    }

    function preRelayedCall(
        GsnTypes.RelayRequest calldata relayRequest,
        bytes calldata signature,
        bytes calldata approvalData,
        uint256 maxPossibleGas
    )
        external
        virtual
        override
        relayHubOnly
        returns (bytes memory context, bool revertOnRecipientRevert)
    {
        (relayRequest, signature, approvalData, maxPossibleGas);
        (IERC20 token, IUniswapV2Pair pair) =
            _getToken(relayRequest.relayData.paymasterData);
        (address payer, uint256 tokenPrecharge) =
            _calculatePreCharge(token, pair, relayRequest, maxPossibleGas);
        uint256 balance = token.balanceOf(payer);
        require(balance != 0, "no tokens");
        require(balance >= tokenPrecharge, "balance not sufficient");
        token.transferFrom(payer, address(this), tokenPrecharge);
        return (abi.encode(payer, tokenPrecharge, token, pair), false);
    }

    function postRelayedCall(
        bytes calldata context,
        bool,
        uint256 gasUseWithoutPost,
        GsnTypes.RelayData calldata relayData
    ) external virtual override relayHubOnly {
        (
            address payer,
            uint256 tokenPrecharge,
            IERC20 token,
            IUniswapV2Pair pair
        ) = abi.decode(context, (address, uint256, IERC20, IUniswapV2Pair));
        _postRelayedCallInternal(
            payer,
            tokenPrecharge,
            0,
            gasUseWithoutPost,
            relayData,
            token,
            pair
        );
    }

    function _postRelayedCallInternal(
        address payer,
        uint256 tokenPrecharge,
        uint256 valueRequested,
        uint256 gasUseWithoutPost,
        GsnTypes.RelayData calldata relayData,
        IERC20 token,
        IUniswapV2Pair pair
    ) internal {
        uint256 ethActualCharge =
            relayHub.calculateCharge(
                gasUseWithoutPost.add(gasUsedByPost),
                relayData
            );
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 tokenActualCharge;
        address weth = uniV2Router02.WETH();
        address token0 = pair.token0();
        if (weth == token0) {
            tokenActualCharge = uniV2Router02.getAmountIn(
                valueRequested.add(ethActualCharge),
                reserve1,
                reserve0
            );
        } else {
            tokenActualCharge = uniV2Router02.getAmountIn(
                valueRequested.add(ethActualCharge),
                reserve0,
                reserve1
            );
        }
        uint256 tokenRefund = tokenPrecharge.sub(tokenActualCharge);
        _refundPayer(payer, token, tokenRefund);
        _depositProceedsToHub(ethActualCharge, address(token), weth);
        emit TokensCharged(
            gasUseWithoutPost,
            gasUsedByPost,
            ethActualCharge,
            tokenActualCharge
        );
    }

    function _refundPayer(
        address payer,
        IERC20 token,
        uint256 tokenRefund
    ) private {
        require(token.transfer(payer, tokenRefund), "failed refund");
    }

    function _depositProceedsToHub(
        uint256 ethActualCharge,
        address path0,
        address path1
    ) private {
        //solhint-disable-next-line
        address[] memory path = new address[](2);
        path[0] = path0;
        path[1] = path1;
        uniV2Router02.swapTokensForExactETH(
            ethActualCharge,
            uint256(-1),
            path,
            address(this),
            block.timestamp + 60 * 15
        );
        relayHub.depositFor{value: ethActualCharge}(address(this));
    }

    event TokensCharged(
        uint256 gasUseWithoutPost,
        uint256 gasJustPost,
        uint256 ethActualCharge,
        uint256 tokenActualCharge
    );

    function deposit() public payable {
        require(address(relayHub) != address(0), "relay hub address not set");
        relayHub.depositFor{value: msg.value}(address(this));
    }

    function withdrawAll(address payable destination) public {
        uint256 amount = relayHub.balanceOf(address(this));
        withdrawRelayHubDepositTo(amount, destination);
    }

    function approve(address addr) external onlyOwner {
        IERC20 token = IERC20(addr);
        token.approve(address(uniV2Router02), 0);
        token.approve(address(uniV2Router02), uint256(-1));
    }

    // Use reasonable gas limit later
    uint256 private constant POST_RELAYED_CALL_GAS_LIMIT_OVERRIDE = 2000000;

    function getGasLimits()
        public
        view
        override
        returns (GasLimits memory limits)
    {
        return
            GasLimits(
                PAYMASTER_ACCEPTANCE_BUDGET,
                PRE_RELAYED_CALL_GAS_LIMIT,
                POST_RELAYED_CALL_GAS_LIMIT_OVERRIDE
            );
    }
}
