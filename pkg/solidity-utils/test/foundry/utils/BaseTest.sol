// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";

import { ERC4626TestToken } from "../../../contracts/test/ERC4626TestToken.sol";
import { ERC20TestToken } from "../../../contracts/test/ERC20TestToken.sol";
import { WETHTestToken } from "../../../contracts/test/WETHTestToken.sol";

abstract contract BaseTest is Test {
    using CastingHelpers for *;

    uint256 internal constant DEFAULT_BALANCE = 1e9 * 1e18;

    // Reasonable block.timestamp `MAY_1_2023`
    uint32 internal constant START_TIMESTAMP = 1_682_899_200;

    uint256 internal constant MAX_UINT256 = type(uint256).max;
    // Raw token balances are stored in half a slot, so the max is uint128.
    uint256 internal constant MAX_UINT128 = type(uint128).max;

    bytes32 internal constant ZERO_BYTES32 = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 internal constant ONE_BYTES32 = 0x0000000000000000000000000000000000000000000000000000000000000001;

    address internal constant ZERO_ADDRESS = address(0);

    // Default admin.
    address payable internal admin;
    uint256 internal adminKey;
    // Default liquidity provider.
    address payable internal lp;
    uint256 internal lpKey;
    // Default user.
    address payable internal alice;
    uint256 internal aliceKey;
    // Default counterparty.
    address payable internal bob;
    uint256 internal bobKey;
    // Malicious user.
    address payable internal hacker;
    uint256 internal hackerKey;
    // Broke user.
    address payable internal broke;
    uint256 internal brokeUserKey;

    // List of all users
    address payable[] internal users;
    uint256[] internal userKeys;

    // ERC20 tokens used for tests.
    ERC20TestToken internal dai;
    ERC20TestToken internal usdc;
    WETHTestToken internal weth;
    ERC20TestToken internal wsteth;
    ERC20TestToken internal veBAL;
    ERC4626TestToken internal waDAI;
    ERC4626TestToken internal waWETH;
    ERC4626TestToken internal waUSDC;
    ERC20TestToken internal usdc6Decimals;
    ERC20TestToken internal wbtc8Decimals;

    // List of all ERC20 tokens
    IERC20[] internal tokens;

    // List of all ERC4626 tokens
    IERC4626[] internal erc4626Tokens;

    // List of all ERC20 odd decimal tokens
    IERC20[] internal oddDecimalTokens;

    bool private _initialized;

    // Default balance for accounts
    uint256 private _defaultAccountBalance = DEFAULT_BALANCE;

    // ------------------------------ Initialization ------------------------------
    function setUp() public virtual {
        // Set timestamp only if testing locally
        if (block.chainid == 31337) {
            // Set block.timestamp to something better than 0
            vm.warp(START_TIMESTAMP);
        }

        _initTokens();
        _initAccounts();

        // Must mock rates after giving wrapped tokens to users, but before creating pools and initializing buffers.
        mockERC4626TokenRates();
    }

    function setDefaultAccountBalance(uint256 balance) internal {
        if (isInitialized()) {
            revert("Cannot change default account balance after initialization");
        }
        _defaultAccountBalance = balance;
    }

    function defaultAccountBalance() internal view returns (uint256) {
        return _defaultAccountBalance;
    }

    // @dev Returns whether the test has been initialized.
    function isInitialized() internal view returns (bool) {
        return _initialized;
    }

    function _initTokens() private {
        // Deploy the base test contracts.
        dai = createERC20("DAI", 18);
        // "USDC" is deliberately 18 decimals to test one thing at a time.
        usdc = createERC20("USDC", 18);
        wsteth = createERC20("WSTETH", 18);
        weth = new WETHTestToken();
        vm.label(address(weth), "WETH");
        veBAL = createERC20("veBAL", 18);

        // Tokens with different decimals.
        usdc6Decimals = createERC20("USDC-6", 6);
        wbtc8Decimals = createERC20("WBTC", 8);

        // Fill the token list.
        tokens.push(dai);
        tokens.push(usdc);
        tokens.push(weth);
        tokens.push(wsteth);
        oddDecimalTokens.push(usdc6Decimals);
        oddDecimalTokens.push(wbtc8Decimals);

        // Deploy ERC4626 tokens.
        waDAI = createERC4626("Wrapped aDAI", "waDAI", 18, dai);
        waWETH = createERC4626("Wrapped aWETH", "waWETH", 18, weth);
        // "waUSDC" is deliberately 18 decimals to test one thing at a time.
        waUSDC = createERC4626("Wrapped aUSDC", "waUSDC", 18, usdc);

        // Fill the ERC4626 token list.
        erc4626Tokens.push(waDAI);
        erc4626Tokens.push(waWETH);
        erc4626Tokens.push(waUSDC);
    }

    function _initAccounts() private {
        // Create users for testing.
        (admin, adminKey) = createUser("admin");
        (lp, lpKey) = createUser("lp");
        (alice, aliceKey) = createUser("alice");
        (bob, bobKey) = createUser("bob");
        (hacker, hackerKey) = createUser("hacker");
        address brokeNonPay;
        (brokeNonPay, brokeUserKey) = makeAddrAndKey("broke");
        broke = payable(brokeNonPay);
        vm.label(broke, "broke");

        // Fill the users list
        users.push(admin);
        userKeys.push(adminKey);
        users.push(lp);
        userKeys.push(lpKey);
        users.push(alice);
        userKeys.push(aliceKey);
        users.push(bob);
        userKeys.push(bobKey);
        users.push(broke);
        userKeys.push(brokeUserKey);
    }

    // ------------------------------ Helpers ------------------------------

    /**
     * @notice Manipulate rates of ERC4626 tokens.
     * @dev It's important to not have a 1:1 rate when testing ERC4626 tokens, so we can differentiate between
     * wrapped and underlying amounts. For certain tests, we may need to override these rates for simplicity.
     */
    function mockERC4626TokenRates() internal virtual {
        waDAI.inflateUnderlyingOrWrapped(0, 6 * defaultAccountBalance());
        waUSDC.inflateUnderlyingOrWrapped(23 * defaultAccountBalance(), 0);
    }

    function getSortedIndexes(
        address tokenA,
        address tokenB
    ) internal pure returns (uint256 idxTokenA, uint256 idxTokenB) {
        idxTokenA = tokenA > tokenB ? 1 : 0;
        idxTokenB = idxTokenA == 0 ? 1 : 0;
    }

    function getSortedIndexes(address[] memory addresses) public pure returns (uint256[] memory sortedIndexes) {
        uint256 length = addresses.length;
        address[] memory sortedAddresses = new address[](length);

        // Clone address array to sortedAddresses, so the original array does not change.
        for (uint256 i = 0; i < length; i++) {
            sortedAddresses[i] = addresses[i];
        }

        sortedAddresses = InputHelpers.sortTokens(sortedAddresses.asIERC20()).asAddress();

        sortedIndexes = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = 0; j < length; j++) {
                if (addresses[i] == sortedAddresses[j]) {
                    sortedIndexes[i] = j;
                }
            }
        }
    }

    /// @dev Creates an ERC20 test token, labels its address.
    function createERC20(string memory name, uint8 decimals) internal returns (ERC20TestToken token) {
        token = new ERC20TestToken(name, name, decimals);
        vm.label(address(token), name);
    }

    /// @dev Creates an ERC4626 test token and labels its address.
    function createERC4626(
        string memory name,
        string memory symbol,
        uint8 decimals,
        IERC20 underlying
    ) internal returns (ERC4626TestToken token) {
        token = new ERC4626TestToken(underlying, name, symbol, decimals);
        vm.label(address(token), symbol);
    }

    /// @dev Generates a user, labels its address, and funds it with test assets.
    function createUser(string memory name) internal returns (address payable, uint256) {
        (address user, uint256 key) = makeAddrAndKey(name);
        vm.label(user, name);
        vm.deal(payable(user), defaultAccountBalance());

        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(address(tokens[i]), user, defaultAccountBalance());
        }

        for (uint256 i = 0; i < oddDecimalTokens.length; ++i) {
            deal(address(oddDecimalTokens[i]), user, defaultAccountBalance());
        }

        for (uint256 i = 0; i < erc4626Tokens.length; ++i) {
            // Give underlying tokens to the user, for depositing in the wrapped token.
            if (erc4626Tokens[i].asset() == address(weth)) {
                vm.deal(user, user.balance + defaultAccountBalance());

                vm.prank(user);
                weth.deposit{ value: defaultAccountBalance() }();
            } else {
                ERC20TestToken(erc4626Tokens[i].asset()).mint(user, defaultAccountBalance());
            }

            // Deposit underlying to mint wrapped tokens to the user.
            vm.startPrank(user);
            IERC20(erc4626Tokens[i].asset()).approve(address(erc4626Tokens[i]), defaultAccountBalance());
            erc4626Tokens[i].deposit(defaultAccountBalance(), user);
            vm.stopPrank();
        }

        return (payable(user), key);
    }

    function getDecimalScalingFactor(uint8 decimals) internal pure returns (uint256 scalingFactor) {
        require(decimals <= 18, "Decimals must be between 0 and 18");
        uint256 decimalDiff = 18 - decimals;
        scalingFactor = 10 ** decimalDiff;

        return scalingFactor;
    }

    /// @dev Returns `amount - amount/base`; e.g., if base = 100, decrease `amount` by 1%; if 1000, 0.1%, etc.
    function less(uint256 amount, uint256 base) internal pure returns (uint256) {
        return (amount * (base - 1)) / base;
    }
}
