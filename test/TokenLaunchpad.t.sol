// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TokenLaunchpad} from "../src/TokenLaunchpad.sol";

contract MockERC20 {
    string public name = "Launch Token";
    string public symbol = "LCH";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TokenLaunchpadTest is Test {
    MockERC20 token;
    TokenLaunchpad sale;

    address creator = makeAddr("creator");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 start;
    uint256 end;
    uint256 constant PRICE = 0.01 ether; // per token
    uint256 constant ALLOCATION = 100 ether; // 100 tokens
    uint256 constant HARD_CAP = 1 ether;
    uint256 constant WALLET_LIMIT = 0.6 ether;
    uint16 constant FEE_BPS = 250; // 2.5%

    function setUp() public {
        token = new MockERC20();
        start = block.timestamp + 1 days;
        end = start + 7 days;
        sale = new TokenLaunchpad(
            address(token), creator, PRICE, ALLOCATION, start, end, HARD_CAP, WALLET_LIMIT, feeRecipient, FEE_BPS
        );

        token.mint(creator, ALLOCATION);
        vm.prank(creator);
        token.approve(address(sale), ALLOCATION);
        vm.prank(creator);
        sale.fundSale();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    function _buy(address buyer, uint256 tokens) internal {
        uint256 payment = (tokens * PRICE) / 1e18;
        vm.prank(buyer);
        sale.buy{value: payment}(tokens);
    }

    function testRejectsPurchaseBeforeStartAndAtEnd() public {
        vm.expectRevert(TokenLaunchpad.SaleNotActive.selector);
        vm.prank(alice);
        sale.buy{value: 0.1 ether}(10 ether);

        vm.warp(start);
        _buy(alice, 10 ether);

        vm.warp(end);
        vm.expectRevert(TokenLaunchpad.SaleNotActive.selector);
        vm.prank(bob);
        sale.buy{value: 0.1 ether}(10 ether);
    }

    function testMultipleBuyersAreTracked() public {
        vm.warp(start);
        _buy(alice, 20 ether);
        _buy(bob, 30 ether);

        assertEq(sale.contributed(alice), 0.2 ether);
        assertEq(sale.contributed(bob), 0.3 ether);
        assertEq(sale.claimable(alice), 20 ether);
        assertEq(sale.claimable(bob), 30 ether);
        assertEq(sale.totalRaised(), 0.5 ether);
        assertEq(sale.totalTokensSold(), 50 ether);
    }

    function testRejectsIncorrectPayment() public {
        vm.warp(start);
        vm.expectRevert(TokenLaunchpad.IncorrectPayment.selector);
        vm.prank(alice);
        sale.buy{value: 0.09 ether}(10 ether);
    }

    function testEnforcesWalletLimit() public {
        vm.warp(start);
        _buy(alice, 60 ether);

        vm.expectRevert(TokenLaunchpad.WalletLimitExceeded.selector);
        vm.prank(alice);
        sale.buy{value: 0.01 ether}(1 ether);
    }

    function testEnforcesHardCapAcrossBuyers() public {
        vm.warp(start);
        _buy(alice, 60 ether);
        _buy(bob, 40 ether);

        assertEq(sale.totalRaised(), HARD_CAP);
        vm.expectRevert(TokenLaunchpad.HardCapExceeded.selector);
        vm.prank(attacker);
        sale.buy{value: 0.01 ether}(1 ether);
    }

    function testClaimsOnlyAfterSale() public {
        vm.warp(start);
        _buy(alice, 25 ether);

        vm.expectRevert(TokenLaunchpad.SaleNotEnded.selector);
        vm.prank(alice);
        sale.claim();

        vm.warp(end);
        vm.prank(alice);
        sale.claim();

        assertEq(token.balanceOf(alice), 25 ether);
        assertEq(sale.claimable(alice), 0);

        vm.expectRevert(TokenLaunchpad.AlreadyClaimed.selector);
        vm.prank(alice);
        sale.claim();
    }

    function testUnauthorizedAndEarlyWithdrawalsRevert() public {
        vm.warp(start);
        _buy(alice, 20 ether);

        vm.warp(end);
        vm.expectRevert(TokenLaunchpad.Unauthorized.selector);
        vm.prank(attacker);
        sale.withdrawProceeds();

        TokenLaunchpad freshSale = new TokenLaunchpad(
            address(token), creator, PRICE, ALLOCATION, block.timestamp + 1, block.timestamp + 2, HARD_CAP, WALLET_LIMIT,
            feeRecipient, FEE_BPS
        );
        vm.expectRevert(TokenLaunchpad.SaleNotEnded.selector);
        vm.prank(creator);
        freshSale.withdrawProceeds();
    }

    function testCreatorWithdrawsNetAndPlatformGetsFee() public {
        vm.warp(start);
        _buy(alice, 60 ether);
        _buy(bob, 40 ether);
        vm.warp(end);

        uint256 creatorBefore = creator.balance;
        uint256 feeBefore = feeRecipient.balance;
        vm.prank(creator);
        sale.withdrawProceeds();

        uint256 fee = (HARD_CAP * FEE_BPS) / 10_000;
        assertEq(creator.balance - creatorBefore, HARD_CAP - fee);
        assertEq(feeRecipient.balance - feeBefore, fee);
        assertEq(address(sale).balance, 0);
    }

    function testRecoverUnsoldPreservesBuyerClaims() public {
        vm.warp(start);
        _buy(alice, 20 ether);
        _buy(bob, 30 ether);
        vm.warp(end);

        vm.prank(creator);
        sale.recoverUnsoldTokens();
        assertEq(token.balanceOf(creator), 50 ether);
        assertEq(token.balanceOf(address(sale)), 50 ether);

        vm.prank(alice);
        sale.claim();
        vm.prank(bob);
        sale.claim();

        assertEq(token.balanceOf(alice), 20 ether);
        assertEq(token.balanceOf(bob), 30 ether);
        assertEq(token.balanceOf(address(sale)), 0);
    }
}
