//SPDX-License-Identifier: MIT
pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "@opengsn/gsn/contracts/BasePaymaster.sol";
import "@opengsn/gsn/contracts/forwarder/IForwarder.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";

/**
 * a sample paymaster that requires an external signature on the request.
 * - the client creates a request.
 * - the client uses a RelayProvider with a callback function asyncApprovalData
 * - the callback sends the request over to a dapp-specific web service, to verify the request.
 * - the service verifies the request, signs it and return the signature.
 * - the client now sends this signed approval as the "approvalData" field of the GSN request.
 * - the paymaster verifies the signature.
 * This way, any external logic can be used to validate the request.
 * e.g.:
 * - OAuth, or any other login mechanism.
 * - Captcha approval
 * - off-chain payment system (note that its a payment for gas, so probably it doesn't require any KYC)
 * - etc.
 */
contract VerifyingPaymaster is Ownable, BasePaymaster {

    address public signer;

    function preRelayedCall(
        GsnTypes.RelayRequest calldata relayRequest,
        bytes calldata signature,
        bytes calldata approvalData,
        uint256 maxPossibleGas
    )
    external
    override
    virtual
    returns (bytes memory context, bool revertOnRecipientRevert) {
        (signature, maxPossibleGas);

        require(approvalData.length == 65, "invalid approvalData signature");

        bytes32 requestHash = getRequestHash(relayRequest);
        require(signer == ECDSA.recover(requestHash, approvalData), "wrong approvalData signature");

        return ("", false);
    }

    function getRequestHash(GsnTypes.RelayRequest calldata relayRequest) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                packForwardRequest(relayRequest.request),
                packRelayData(relayRequest.relayData)
            )
        );
    }

    function packForwardRequest(IForwarder.ForwardRequest calldata req) public pure returns (bytes memory) {
        return abi.encode(req.from, req.to, req.value, req.gas, req.nonce, req.data);
    }

    function packRelayData(GsnTypes.RelayData calldata d) public pure returns (bytes memory) {
        return abi.encode(d.gasPrice, d.pctRelayFee, d.baseRelayFee, d.relayWorker, d.paymaster, d.paymasterData, d.clientId);
    }

    function postRelayedCall(
        bytes calldata context,
        bool success,
        uint256 gasUseWithoutPost,
        GsnTypes.RelayData calldata relayData
    ) external override virtual {
        (context, success, gasUseWithoutPost, relayData);
    }

    function versionPaymaster() external view override virtual returns (string memory){
        return "2.0.0+opengsn.vpm.ipaymaster";
    }

    function setSigner(address _signer) public onlyOwner {
        signer = _signer;
    }
}
