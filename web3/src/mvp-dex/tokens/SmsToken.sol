// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BasicERC20.sol";

/**
 * @title SmsToken
 * @dev SMS token for MVP DEX testing
 */
contract SmsToken is BasicERC20 {
    constructor() BasicERC20(
        "SMS Token",
        "SMS",
        18,
        500_000_000 * 10**18  // 500 million tokens
    ) {
        // All tokens minted to deployer
    }
}
