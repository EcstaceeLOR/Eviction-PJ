// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TokenLaunchpad
/// @notice Fixed-price ERC-20 token sale paid with native ETH.
/// @dev Sale tokens are escrowed in this contract before the sale starts.
contract TokenLaunchpad {
    IERC20 public immutable token;
    address public immutable creator;
    address public immutable feeRecipient;

    // Price in wei per whole token unit represented by 1e18 sale-token units.
    uint256 public immutable price;
    uint256 public immutable allocation;
    uint256 public immutable startTime;
    uint256 public immutable endTime;
    uint256 public immutable hardCap;
    uint256 public immutable perWalletLimit;
    uint16 public immutable platformFeeBps;

    uint256 public totalRaised;
    uint256 public totalTokensSold;
    bool public proceedsWithdrawn;
    bool public unsoldRecovered;

    mapping(address => uint256) public contributed;
    mapping(address => uint256) public claimable;
    mapping(address => bool) public hasClaimed;

    uint256 private locked = 1;

    error Unauthorized();
    error InvalidConfig();
    error SaleNotActive();
    error SaleNotEnded();
    error HardCapExceeded();
    error WalletLimitExceeded();
    error IncorrectPayment();
    error AllocationExceeded();
    error NothingToClaim();
    error AlreadyClaimed();
    error AlreadyWithdrawn();
    error AlreadyRecovered();
    error TransferFailed();
    error Reentrancy();

    event SaleCreated(
        address indexed creator,
        address indexed token,
        uint256 price,
        uint256 allocation,
        uint256 startTime,
        uint256 endTime,
        uint256 hardCap,
        uint256 perWalletLimit,
        uint16 platformFeeBps
    );
    event Purchase(address indexed buyer, uint256 ethPaid, uint256 tokenAmount);
    event Claimed(address indexed buyer, uint256 tokenAmount);
    event ProceedsWithdrawn(address indexed creator, uint256 creatorAmount, uint256 platformFee);
    event UnsoldRecovered(address indexed creator, uint256 tokenAmount);

    modifier onlyCreator() {
        if (msg.sender != creator) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        address token_,
        address creator_,
        uint256 price_,
        uint256 allocation_,
        uint256 startTime_,
        uint256 endTime_,
        uint256 hardCap_,
        uint256 perWalletLimit_,
        address feeRecipient_,
        uint16 platformFeeBps_
    ) {
        if (
            token_ == address(0) || creator_ == address(0) || feeRecipient_ == address(0)
                || price_ == 0 || allocation_ == 0 || startTime_ <= block.timestamp
                || endTime_ <= startTime_ || hardCap_ == 0 || perWalletLimit_ == 0
                || perWalletLimit_ > hardCap_ || platformFeeBps_ > 10_000
        ) revert InvalidConfig();

        // The hard cap must not promise more tokens than the configured allocation.
        if ((hardCap_ * 1e18) / price_ > allocation_) revert InvalidConfig();

        token = IERC20(token_);
        creator = creator_;
        price = price_;
        allocation = allocation_;
        startTime = startTime_;
        endTime = endTime_;
        hardCap = hardCap_;
        perWalletLimit = perWalletLimit_;
        feeRecipient = feeRecipient_;
        platformFeeBps = platformFeeBps_;

        emit SaleCreated(
            creator_, token_, price_, allocation_, startTime_, endTime_, hardCap_, perWalletLimit_, platformFeeBps_
        );
    }

    /// @notice Creator escrows exactly the configured sale allocation.
    function fundSale() external onlyCreator {
        if (!token.transferFrom(msg.sender, address(this), allocation)) revert TransferFailed();
    }

    /// @notice Buy an exact number of token base units with native ETH.
    function buy(uint256 tokenAmount) external payable nonReentrant {
        if (block.timestamp < startTime || block.timestamp >= endTime) revert SaleNotActive();
        if (tokenAmount == 0) revert IncorrectPayment();

        uint256 requiredPayment = (tokenAmount * price) / 1e18;
        // Reject truncation/rounding ambiguity: payment must map exactly back to tokenAmount.
        if (requiredPayment == 0 || (requiredPayment * 1e18) / price != tokenAmount || msg.value != requiredPayment) {
            revert IncorrectPayment();
        }
        if (totalRaised + msg.value > hardCap) revert HardCapExceeded();
        if (contributed[msg.sender] + msg.value > perWalletLimit) revert WalletLimitExceeded();
        if (totalTokensSold + tokenAmount > allocation) revert AllocationExceeded();

        totalRaised += msg.value;
        totalTokensSold += tokenAmount;
        contributed[msg.sender] += msg.value;
        claimable[msg.sender] += tokenAmount;

        emit Purchase(msg.sender, msg.value, tokenAmount);
    }

    /// @notice Claim purchased tokens after the sale ends.
    function claim() external nonReentrant {
        if (block.timestamp < endTime) revert SaleNotEnded();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();

        hasClaimed[msg.sender] = true;
        claimable[msg.sender] = 0;
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();

        emit Claimed(msg.sender, amount);
    }

    /// @notice Creator withdraws proceeds after the sale; platform fee is separated atomically.
    function withdrawProceeds() external onlyCreator nonReentrant {
        if (block.timestamp < endTime) revert SaleNotEnded();
        if (proceedsWithdrawn) revert AlreadyWithdrawn();
        proceedsWithdrawn = true;

        uint256 fee = (totalRaised * platformFeeBps) / 10_000;
        uint256 creatorAmount = totalRaised - fee;

        if (fee != 0) {
            (bool feeOk,) = feeRecipient.call{value: fee}("");
            if (!feeOk) revert TransferFailed();
        }
        if (creatorAmount != 0) {
            (bool creatorOk,) = creator.call{value: creatorAmount}("");
            if (!creatorOk) revert TransferFailed();
        }

        emit ProceedsWithdrawn(creator, creatorAmount, fee);
    }

    /// @notice Return only unsold inventory, preserving every buyer's purchased tokens.
    function recoverUnsoldTokens() external onlyCreator nonReentrant {
        if (block.timestamp < endTime) revert SaleNotEnded();
        if (unsoldRecovered) revert AlreadyRecovered();
        unsoldRecovered = true;

        uint256 unsold = allocation - totalTokensSold;
        if (unsold != 0 && !token.transfer(creator, unsold)) revert TransferFailed();

        emit UnsoldRecovered(creator, unsold);
    }
}
