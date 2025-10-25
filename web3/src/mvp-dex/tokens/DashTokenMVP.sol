// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BasicERC20.sol";

/**
 * @title DashTokenMVP
 * @dev Minimal DASH token for MVP DEX
 */
contract DashTokenMVP is BasicERC20 {
    constructor() BasicERC20(
        "Dash Protocol Token",
        "DASH",
        18,
        1_000_000_000 * 10**18  // 1 billion tokens
    ) {
        // All tokens minted to deployer
    }
}
