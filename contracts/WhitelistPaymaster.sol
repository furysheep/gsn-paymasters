pragma solidity ^0.6.2;
pragma experimental ABIEncoderV2;

import "./AcceptEverythingPaymaster.sol";

///a sample paymaster that has whitelists for senders and targets.
/// - if at least one sender is whitelisted, then ONLY whitelisted senders are allowed.
/// - if at least one target is whitelisted, then ONLY whitelisted targets are allowed.
contract WhitelistPaymaster is AcceptEverythingPaymaster {

    bool useSenderWhitelist;
    bool useTargetWhitelist;
    mapping (address=>bool) public senderWhitelist;
    mapping (address=>bool) public targetWhitelist;

    function whitelistSender(address sender) public onlyOwner {
        senderWhitelist[sender]=true;
        useSenderWhitelist = true;
    }
    function whitelistTarget(address target) public onlyOwner {
        targetWhitelist[target]=true;
        useTargetWhitelist = true;
    }

    function acceptRelayedCall(
        GSNTypes.RelayRequest calldata relayRequest,
        bytes calldata approvalData,
        uint256 maxPossibleCharge
    ) external override virtual view
    returns (bytes memory) {
        (relayRequest, approvalData, maxPossibleCharge);

        if ( useSenderWhitelist ) {
            require( senderWhitelist[relayRequest.relayData.senderAddress], "sender not whitelisted");
        }
        if ( useTargetWhitelist ) {
            require( targetWhitelist[relayRequest.target], "target not whitelisted");
        }
        return "";
    }
}