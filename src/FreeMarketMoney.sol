/**
 * به نام خداوند جان و خرد
 * کز این برتر اندیشه بر نگذرد
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FreeMarketMoney
 * @notice ERC20 token backed by ETH, with issue/redeem at market prices from a PriceFeed.
 * @dev Users send ETH to issue tokens (buy) or redeem tokens for ETH (sell). Commission (0.1%)
 *      accrues to the owner. Supports redemption by transferring tokens to `address(this)` or to
 *      the `redeemAddress` sink, and supports ENS reverse records.
 */

import {ERC20} from "@openzeppelin/contracts/token/erc20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Interface for the ENS Reverse Registrar (sets primary name for contract address)
/// @dev See https://docs.ens.domains/registry/reverse
interface IReverseRegistrar {
    function setName(string calldata name) external;
}

/// @notice Interface for the PriceFeed used by FreeMarketMoney
/// @dev Prices are expressed as tokens per ETH (ETH/TOKEN price). Zero means issue/redeem disabled.
interface PriceFeedInterface {
    function getIssuePrice() external view returns (uint256);
    function getRedeemPrice() external view returns (uint256);
}

/// @title FreeMarketMoney
/// @notice ERC20 token backed by ETH with market-driven issue and redeem
contract FreeMarketMoney is ERC20, Ownable, ReentrancyGuard {
    /// @notice Enum representing the type of supply change action (Issue or Redeem)
    enum Action {
        Issue,
        Redeem
    }

    /// @notice Emitted when tokens are bought or sold, tracking supply changes
    /// @param action The action type (Issue or Redeem)
    /// @param timestamp The block timestamp of the transaction
    /// @param price The market price used for the transaction
    /// @param ethAmount The amount of reserve coins (ETH) involved
    /// @param change The amount of tokens minted or burned
    /// @param wallet The address performing the action
    event SupplyChange(
        Action action, uint256 timestamp, uint256 price, uint256 ethAmount, uint256 change, address wallet
    );

    // ============ State Variables ============

    /// @notice Address of the PriceFeed contract (mutable for upgradability)
    /// @dev PriceFeed returns a price expressed as *tokens per ETH* (not wei per token).
    ///      All calculations in this contract assume that convention; callers and tests
    ///      should be aware of it to avoid confusion.
    address private priceFeedAddress;
    /// @notice Whether the PriceFeed address can be updated. Set to false via makePriceFeedPermanent() to lock.
    bool public priceFeedAddressCanChange = true;

    /// @notice Emitted when the price feed address is updated
    /// @param oldAddress Previous price feed
    /// @param newAddress New price feed
    event PriceFeedUpdated(address indexed oldAddress, address indexed newAddress);

    /// @notice Mutable token display name (owner can update via setTokenName)
    string private _name;
    /// @notice Mutable token symbol (owner can update via setTokenSymbol)
    string private _symbol;
    /// @notice Commission rate: 1 represents 0.1% (1/1000)
    uint256 private constant COMMISSION_RATE = 1;

    /// @notice Divisor for commission calculations (1000 = 0.1% precision)
    uint256 private constant COMMISSION_UNIT = 1000;

    /// @notice Number of decimals for this token (6 decimals like USDC)
    uint8 private constant DECIMALS = 6;

    /// @notice 10^6, used for token amount calculations
    uint256 private constant DECIMALS_MULTIPLIER = 10 ** DECIMALS;

    /// @notice Conversion factor between 18-decimal ETH and 6-decimal token
    /// @dev Equals 1e18 / 10^6 = 1e12
    uint256 private constant COIN_TOKEN_DECIMALS_MULTIPLIER = 1e18 / DECIMALS_MULTIPLIER;

    /// @notice ENS Reverse Registrar for setting the contract's primary ENS name
    /// @dev Mainnet: 0xa58E81fe9b61B5c3fE2AFD33CF304c454AbFc7Cb
    IReverseRegistrar public constant reverseRegistrar = IReverseRegistrar(0xa58E81fe9b61B5c3fE2AFD33CF304c454AbFc7Cb);

    /// @notice Accumulated commission from issue and redeem, withdrawable by owner
    uint256 public ownerIncome = 0;

    /// @notice Alternate "send-to-redeem" sink address that triggers redemption on transfer
    /// @dev Some wallets/exchanges handle transfers to EOAs more reliably than transfers to
    ///      contracts. Transfers to either `address(this)` or `redeemAddress` redeem the sender's
    ///      tokens and pay ETH back to the token sender (`from`), not to the sink address.
    address public constant redeemAddress = 0x5e11111111111111111111111111111111111111;

    // ============ Constructor ============

    /// @notice Deploys the fund with default name and symbol
    constructor() ERC20("", "") Ownable(msg.sender) {
        _name = "Riale Bazaar Azad";
        _symbol = "RIALE";
    }

    /// @notice Sets the primary ENS name for this contract's address (owner only)
    /// @param _ensName The ENS name to associate with this contract
    function setEnsName(string calldata _ensName) public onlyOwner {
        reverseRegistrar.setName(_ensName);
    }

    /// @notice Updates the token display name (owner only)
    /// @param newName The new token name
    function setTokenName(string memory newName) public onlyOwner {
        _name = newName;
    }

    /// @notice Updates the token symbol (owner only)
    /// @param newSymbol The new token symbol
    function setTokenSymbol(string memory newSymbol) public onlyOwner {
        _symbol = newSymbol;
    }

    /// @notice Returns the current token name
    /// @return The token name (mutable via setTokenName)
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Returns the current token symbol
    /// @return The token symbol (mutable via setTokenSymbol)
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    // ============ PriceFeed Management ============

    /// @notice Returns the current PriceFeed contract address
    /// @return The address of the PriceFeed contract
    function getPriceFeedAddress() public view returns (address) {
        return priceFeedAddress;
    }

    /// @notice Updates the PriceFeed contract address (owner only)
    /// @dev Reverts if priceFeedAddressCanChange is false
    /// @param _priceFeedAddress New address of the PriceFeed contract
    function setPriceFeedAddress(address _priceFeedAddress) public nonReentrant onlyOwner {
        require(priceFeedAddressCanChange, "Price feed can't be updated");
        require(_priceFeedAddress != address(0), "Price feed address cannot be zero");
        address old = priceFeedAddress;
        priceFeedAddress = _priceFeedAddress;
        emit PriceFeedUpdated(old, _priceFeedAddress);
    }

    /// @notice Locks the PriceFeed address so it can no longer be changed (owner only)
    function makePriceFeedPermanent() public onlyOwner {
        priceFeedAddressCanChange = false;
    }

    /// @notice Returns the number of decimals for this token
    /// @return 6 decimals (same as USDC)
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Withdraws accumulated commission to the owner (owner only)
    /// @dev Keeps a minimum balance of 1 wei to avoid zero-storage gas edge cases
    function withdrawIncome() public nonReentrant onlyOwner {
        uint256 income = ownerIncome;
        require(income > 2, "No income to withdraw");
        ownerIncome = 1;
        (bool sent,) = payable(owner()).call{value: income - 1}("");
        require(sent, "Failed to send Ether");
    }

    // ============ Price Fetching ============

    /// @notice Fetches the current issue (buy) price from PriceFeed
    /// @return The current issue price in TOKEN per ETH (ETH/TOKEN price, like ETH/RIAL price)
    function getMarketIssuePrice() public view returns (uint256) {
        uint256 issuePrice = PriceFeedInterface(priceFeedAddress).getIssuePrice();
        require(issuePrice > 0, "Issue is disabled");
        return issuePrice;
    }

    /// @notice Fetches the current redeem (sell) price from PriceFeed
    /// @return The current redeem price in TOKEN per ETH (ETH/TOKEN price, like ETH/RIAL price)
    function getMarketRedeemPrice() public view returns (uint256) {
        uint256 redeemPrice = PriceFeedInterface(priceFeedAddress).getRedeemPrice();
        require(redeemPrice > 0, "Redeem is disabled");
        return redeemPrice;
    }

    // ============ Issue Function ============

    /// @notice Issues (mints) tokens in exchange for ETH sent
    /// @dev Commission (0.1%) accrues to ownerIncome; remainder used at getMarketIssuePrice()
    /// @return issueAmount The number of tokens minted to msg.sender
    function issue() public payable returns (uint256) {
        require(msg.value > 0, "Value must be greater than 0");

        // Calculate commission (0.1% of msg.value)
        uint256 commission = (msg.value * COMMISSION_RATE) / COMMISSION_UNIT;
        uint256 coinToToken = msg.value - commission;
        require(coinToToken > 0, "Amount after commission is zero");

        // Fetch current issue price and calculate token amount (tokens per ETH)
        uint256 issuePrice = getMarketIssuePrice();
        uint256 issueAmount = (coinToToken * issuePrice) * DECIMALS_MULTIPLIER / 1e18;
        require(issueAmount > 0, "Issue amount underflows to zero");

        // Effects: mint tokens before external interactions
        _mint(msg.sender, issueAmount);

        ownerIncome += commission;

        emit SupplyChange(Action.Issue, block.timestamp, issuePrice, coinToToken, issueAmount, msg.sender);
        return issueAmount;
    }

    // ============ Redeem Functions ============

    /// @notice Calculates redemption amounts for Redeeming tokens
    /// @param amount Number of tokens (6-decimal) to redeem
    /// @return ethAmount Total ETH value before commission
    /// @return commission Commission amount (0.1%)
    /// @return ethToPay Net ETH amount to send to unitHolder
    /// @dev Uses algorithmic pricing: if reserve < supported supply, price adjusts downward
    function getRedeemAmount(uint256 amount) public view returns (uint256, uint256, uint256) {
        uint256 redeemPrice = getMarketRedeemPrice();

        // Calculate what the supply SHOULD be at current price
        uint256 supportedSupply = (fundEth() * redeemPrice * DECIMALS_MULTIPLIER) / 1e18;

        uint256 ethAmount;

        if (supportedSupply > totalSupply()) {
            // Reserve is sufficient: use fixed redeem price
            ethAmount = (amount * COIN_TOKEN_DECIMALS_MULTIPLIER) / redeemPrice;
        } else {
            // Reserve is insufficient: adjust price based on available reserve
            ethAmount = (amount * fundEth()) / totalSupply();
        }

        require(ethAmount > 0, "Nothing to pay!");

        // Calculate commission and net payout
        uint256 commission = (ethAmount * COMMISSION_RATE) / COMMISSION_UNIT;
        uint256 ethToPay = ethAmount - commission;

        return (ethAmount, commission, ethToPay);
    }

    /// @notice Returns the ETH balance available as reserve (total balance minus ownerIncome)
    /// @return The ETH amount backing the token supply
    function fundEth() public view returns (uint256) {
        return address(this).balance - ownerIncome;
    }

    /// @notice Returns the effective redeem price implied by current reserves
    /// @dev Computes price = totalSupply / effective ETH backing using getRedeemAmount
    /// @return price Current redeem price in tokens per ETH
    function getActualRedeemPrice() public view returns (uint256) {
        uint256 amount = totalSupply();
        (uint256 ethAmount,,) = getRedeemAmount(amount);
        uint256 price = _calculateEthToTokenPrice(amount, ethAmount);
        return price;
    }

    /// @notice Helper to compute tokens-per-ETH price from token and ETH amounts
    /// @param tokenAmount Token amount (6 decimals)
    /// @param ethAmount ETH amount (18 decimals)
    /// @return Price as tokens per ETH, scaled by COIN_TOKEN_DECIMALS_MULTIPLIER
    function _calculateEthToTokenPrice(uint256 tokenAmount, uint256 ethAmount) internal pure returns (uint256) {
        return (tokenAmount * COIN_TOKEN_DECIMALS_MULTIPLIER) / ethAmount;
    }

    /// @notice Internal helper that implements the redeem mechanics for a given unitHolder
    /// @param unitHolder Address whose tokens will be burned and who will receive ETH
    /// @param amount Number of tokens (6-decimal) to redeem
    /// @dev This logic is identical whether the call originates from `redeem()` or via a
    ///      transfer to the contract; splitting it out avoids duplication.
    function _executeRedeem(address unitHolder, uint256 amount) internal nonReentrant returns (uint256) {
        require(amount > 0, "Amount must be greater than zero");
        require(balanceOf(unitHolder) >= amount, "Not enough tokens to redeem");

        (uint256 ethAmount, uint256 commission, uint256 ethToPay) = getRedeemAmount(amount);

        _burn(unitHolder, amount);

        (bool sent,) = payable(unitHolder).call{value: ethToPay}("");
        require(sent, "Failed to send Ether");

        ownerIncome += commission;

        uint256 price = _calculateEthToTokenPrice(amount, ethAmount);
        emit SupplyChange(Action.Redeem, block.timestamp, price, ethAmount, amount, unitHolder);
        return ethToPay;
    }

    /// @notice Redeems tokens for ETH
    /// @param amount Number of tokens (6-decimal) to redeem
    /// @return Net ETH sent to caller after commission
    /// @dev Commission accrues to ownerIncome; net ETH sent to msg.sender
    function redeem(uint256 amount) public returns (uint256) {
        return _executeRedeem(msg.sender, amount);
    }

    // ============ Update Overrides ============

    /// @notice Centralized update hook that intercepts token transfers to the contract
    /// @dev Transfers to `address(this)` or to `redeemAddress` trigger redemption (burn sender's
    ///      tokens and pay ETH back to the sender). Otherwise delegates to ERC20.
    /// @param from Sender address (or zero for mint)
    /// @param to Recipient address (or zero for burn)
    /// @param amount Token amount
    function _update(address from, address to, uint256 amount) internal override {
        if ((to == address(this) || to == redeemAddress) && from != address(0) && msg.sender != address(this)) {
            _executeRedeem(from, amount);
            return;
        } else {
            super._update(from, to, amount);
        }
    }

    // ============ Fallback Functions ============

    /// @notice Allows direct ETH transfers to trigger issue() function
    receive() external payable {
        issue();
    }

    /// @notice Fallback function for any unrecognized calls with ETH
    fallback() external payable {
        issue();
    }
}
