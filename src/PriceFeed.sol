/**
 * به نام خداوند جان و خرد
 * کز این برتر اندیشه بر نگذرد
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PriceFeed
 * @notice Oracle-style contract providing issue and redeem prices for FreeMarketMoney.
 * @dev Prices are expressed as tokens per ETH (e.g. IRR per ETH). Owner updates prices;
 *      zero means issue or redeem is disabled. Can receive ETH from accidental sends.
 */

contract PriceFeed {
    /// @notice Stores the current issue and redeem prices plus last update timestamp
    struct Prices {
        uint96 issue; /// Issue (buy) price: tokens per ETH
        uint96 redeem; /// Redeem (sell) price: tokens per ETH
        uint64 timestamp; /// Block timestamp of last update
    }

    /// @notice Current prices and last update time
    Prices private s_prices;

    /// @notice Address allowed to update prices and withdraw ETH
    address public immutable owner;

    /// @notice Thrown when a non-owner calls an owner-only function
    error NotOwner();

    /// @notice Emitted when prices are updated
    /// @param timestamp Block timestamp of the update
    /// @param issuePrice New issue price
    /// @param redeemPrice New redeem price
    event PriceUpdated(uint64 timestamp, uint96 issuePrice, uint96 redeemPrice);

    /// @notice Initializes the PriceFeed with the deployer as owner
    constructor() {
        owner = msg.sender;
    }

    /// @notice Updates the issue and redeem prices (owner only)
    /// @param issuePrice New issue price (tokens per ETH); zero disables issue
    /// @param redeemPrice New redeem price (tokens per ETH); zero disables redeem
    function updatePrice(uint96 issuePrice, uint96 redeemPrice) external {
        if (msg.sender != owner) revert NotOwner();

        uint64 ts = uint64(block.timestamp);

        s_prices = Prices(issuePrice, redeemPrice, ts);

        emit PriceUpdated(ts, issuePrice, redeemPrice);
    }

    /// @notice Returns the current issue (buy) price
    /// @return The issue price in tokens per ETH; zero means issue is disabled
    function getIssuePrice() external view returns (uint96) {
        return s_prices.issue;
    }

    /// @notice Returns the current redeem (sell) price
    /// @return The redeem price in tokens per ETH; zero means redeem is disabled
    function getRedeemPrice() external view returns (uint96) {
        return s_prices.redeem;
    }

    /// @notice Returns both issue and redeem prices in one call
    /// @return issue Current issue price
    /// @return redeem Current redeem price
    function getPrices() external view returns (uint96 issue, uint96 redeem) {
        Prices memory p = s_prices;
        return (p.issue, p.redeem);
    }

    /// @notice Withdraws all ETH from the contract to the owner (owner only)
    /// @dev Used to recover accidentally sent ETH
    function withdrawETH() public {
        if (msg.sender != owner) revert NotOwner();
        (bool sent,) = payable(owner).call{value: address(this).balance}("");
        require(sent, "Failed to send Ether");
    }
}

 
