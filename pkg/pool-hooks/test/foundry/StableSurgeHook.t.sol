// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { PoolRoleAccounts } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { StablePool } from "@balancer-labs/v3-pool-stable/contracts/StablePool.sol";

import { StablePoolFactory } from "@balancer-labs/v3-pool-stable/contracts/StablePoolFactory.sol";
import { CommonAuthentication } from "@balancer-labs/v3-vault/contracts/CommonAuthentication.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { StableMath } from "@balancer-labs/v3-solidity-utils/contracts/math/StableMath.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { PoolSwapParams, SwapKind } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { StableSurgeHookDeployer } from "./utils/StableSurgeHookDeployer.sol";
import { StableSurgeHook } from "../../contracts/StableSurgeHook.sol";
import { StableSurgeHookMock } from "../../contracts/test/StableSurgeHookMock.sol";
import { StableSurgeMedianMathMock } from "../../contracts/test/StableSurgeMedianMathMock.sol";

contract StableSurgeHookTest is BaseVaultTest, StableSurgeHookDeployer {
    using ArrayHelpers for *;
    using CastingHelpers for *;
    using FixedPoint for uint256;

    uint256 internal constant DEFAULT_AMP_FACTOR = 200;
    uint256 constant DEFAULT_POOL_TOKEN_COUNT = 2;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    StableSurgeHookMock internal stableSurgeHook;

    StableSurgeMedianMathMock stableSurgeMedianMathMock = new StableSurgeMedianMathMock();

    function setUp() public override {
        super.setUp();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));
        // Allow router to burn BPT tokens.
        vm.prank(lp);
        IERC20(pool).approve(address(router), MAX_UINT256);
    }

    function createPoolFactory() internal override returns (address) {
        return address(new StablePoolFactory(IVault(address(vault)), 365 days, "Factory v1", "Pool v1"));
    }

    function createHook() internal override returns (address) {
        vm.prank(poolFactory);
        stableSurgeHook = deployStableSurgeHookMock(
            vault,
            DEFAULT_MAX_SURGE_FEE_PERCENTAGE,
            DEFAULT_SURGE_THRESHOLD_PERCENTAGE,
            "Test"
        );
        vm.label(address(stableSurgeHook), "StableSurgeHook");
        return address(stableSurgeHook);
    }

    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        PoolRoleAccounts memory roleAccounts;

        newPool = StablePoolFactory(poolFactory).create(
            "Stable Pool",
            "STABLEPOOL",
            vault.buildTokenConfig(tokens.asIERC20()),
            DEFAULT_AMP_FACTOR,
            roleAccounts,
            DEFAULT_SWAP_FEE_PERCENTAGE,
            poolHooksContract,
            false,
            false,
            ZERO_BYTES32
        );
        vm.label(address(newPool), label);

        return (
            address(newPool),
            abi.encode(
                StablePool.NewPoolParams({
                    name: "Stable Pool",
                    symbol: "STABLEPOOL",
                    amplificationParameter: DEFAULT_AMP_FACTOR,
                    version: "Pool v1"
                }),
                vault
            )
        );
    }

    function testValidVault() public {
        vm.expectRevert(CommonAuthentication.VaultNotSet.selector);
        deployStableSurgeHook(
            IVault(address(0)),
            DEFAULT_MAX_SURGE_FEE_PERCENTAGE,
            DEFAULT_SURGE_THRESHOLD_PERCENTAGE,
            ""
        );
    }

    function testSuccessfulRegistry() public view {
        assertEq(
            stableSurgeHook.getSurgeThresholdPercentage(pool),
            DEFAULT_SURGE_THRESHOLD_PERCENTAGE,
            "Surge threshold is wrong"
        );
    }

    function testUnbalancedAddLiquidityWhenSurging() public {
        // Unbalance the pool first.
        uint256[] memory initialBalances = new uint256[](2);
        initialBalances[daiIdx] = 10e18;
        initialBalances[usdcIdx] = 100_000e18;
        vault.manualSetPoolBalances(pool, initialBalances, initialBalances);

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[daiIdx] = 0;
        amountsIn[usdcIdx] = 100e18;

        uint256[] memory expectedBalancesAfterAdd = new uint256[](2);
        expectedBalancesAfterAdd[daiIdx] = initialBalances[daiIdx] + amountsIn[daiIdx];
        expectedBalancesAfterAdd[usdcIdx] = initialBalances[usdcIdx] + amountsIn[usdcIdx];

        StableSurgeHook.SurgeFeeData memory surgeFeeData = stableSurgeHook.getSurgeFeeData(pool);

        // Add USDC --> more unbalanced.
        uint256 newTotalImbalance = stableSurgeMedianMathMock.calculateImbalance(expectedBalancesAfterAdd);
        assertTrue(
            stableSurgeHook.isSurging(surgeFeeData, initialBalances, newTotalImbalance),
            "Not surging after add"
        );

        vm.expectRevert(IVaultErrors.AfterAddLiquidityHookFailed.selector);
        vm.prank(alice);
        router.addLiquidityUnbalanced(pool, amountsIn, 0, false, "");

        // Proportional is always fine
        vm.prank(alice);
        router.addLiquidityProportional(pool, initialBalances, 1e18, false, bytes(""));
    }

    function testUnbalancedAddLiquidityWhenNotSurging() public {
        // Start balanced
        uint256[] memory initialBalances = new uint256[](2);
        initialBalances[daiIdx] = 100_000e18;
        initialBalances[usdcIdx] = 100_000e18;
        vault.manualSetPoolBalances(pool, initialBalances, initialBalances);

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[daiIdx] = 10e18;
        amountsIn[usdcIdx] = 100e18;

        uint256[] memory expectedBalancesAfterAdd = new uint256[](2);
        expectedBalancesAfterAdd[daiIdx] = initialBalances[daiIdx] + amountsIn[daiIdx];
        expectedBalancesAfterAdd[usdcIdx] = initialBalances[usdcIdx] + amountsIn[usdcIdx];

        StableSurgeHook.SurgeFeeData memory surgeFeeData = stableSurgeHook.getSurgeFeeData(pool);

        // Should not surge, close to balance
        uint256 newTotalImbalance = stableSurgeMedianMathMock.calculateImbalance(expectedBalancesAfterAdd);
        assertFalse(stableSurgeHook.isSurging(surgeFeeData, initialBalances, newTotalImbalance), "Surging after add");

        // Does not revert
        vm.prank(alice);
        router.addLiquidityUnbalanced(pool, amountsIn, 0, false, "");
    }

    function testRemoveLiquidityWhenSurging() public {
        // Unbalance the pool first.
        uint256[] memory initialBalances = new uint256[](2);
        initialBalances[daiIdx] = poolInitAmount / 1000;
        initialBalances[usdcIdx] = poolInitAmount;
        vault.manualSetPoolBalances(pool, initialBalances, initialBalances);

        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[daiIdx] = initialBalances[daiIdx] / 2;
        amountsOut[usdcIdx] = 0;

        uint256[] memory expectedBalancesAfterRemove = new uint256[](2);
        expectedBalancesAfterRemove[daiIdx] = initialBalances[daiIdx] - amountsOut[daiIdx];
        expectedBalancesAfterRemove[usdcIdx] = initialBalances[usdcIdx] - amountsOut[usdcIdx];

        StableSurgeHook.SurgeFeeData memory surgeFeeData = stableSurgeHook.getSurgeFeeData(pool);

        // Remove DAI --> more unbalanced.
        uint256 newTotalImbalance = stableSurgeMedianMathMock.calculateImbalance(expectedBalancesAfterRemove);
        assertTrue(
            stableSurgeHook.isSurging(surgeFeeData, initialBalances, newTotalImbalance),
            "Not surging after remove"
        );

        uint256 bptBalance = IERC20(pool).balanceOf(lp);

        vm.expectRevert(IVaultErrors.AfterRemoveLiquidityHookFailed.selector);
        vm.prank(lp);
        router.removeLiquiditySingleTokenExactOut(address(pool), bptBalance, dai, amountsOut[daiIdx], false, bytes(""));

        uint256[] memory minAmountsOut = new uint256[](2);
        // Proportional is always fine
        vm.prank(lp);
        router.removeLiquidityProportional(pool, bptBalance / 2, minAmountsOut, false, bytes(""));
    }

    function testUnbalancedRemoveLiquidityWhenNotSurging() public {
        // Start balanced
        uint256[] memory initialBalances = new uint256[](2);
        initialBalances[daiIdx] = poolInitAmount;
        initialBalances[usdcIdx] = poolInitAmount;
        vault.manualSetPoolBalances(pool, initialBalances, initialBalances);

        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[daiIdx] = poolInitAmount / 1000;
        amountsOut[usdcIdx] = 0;

        uint256[] memory expectedBalancesAfterRemove = new uint256[](2);
        expectedBalancesAfterRemove[daiIdx] = initialBalances[daiIdx] - amountsOut[daiIdx];
        expectedBalancesAfterRemove[usdcIdx] = initialBalances[usdcIdx] - amountsOut[usdcIdx];

        StableSurgeHook.SurgeFeeData memory surgeFeeData = stableSurgeHook.getSurgeFeeData(pool);

        // Should not surge, close to balance
        uint256 newTotalImbalance = stableSurgeMedianMathMock.calculateImbalance(expectedBalancesAfterRemove);
        assertFalse(
            stableSurgeHook.isSurging(surgeFeeData, initialBalances, newTotalImbalance),
            "Surging after remove"
        );

        uint256 bptBalance = IERC20(pool).balanceOf(lp);
        // Does not revert
        vm.prank(lp);
        router.removeLiquiditySingleTokenExactOut(address(pool), bptBalance, dai, amountsOut[daiIdx], false, bytes(""));
    }

    function testSwap__Fuzz(uint256 amountGivenScaled18, uint256 swapFeePercentageRaw, uint256 kindRaw) public {
        amountGivenScaled18 = bound(amountGivenScaled18, 1e18, poolInitAmount / 2);
        SwapKind kind = SwapKind(bound(kindRaw, 0, 1));

        vault.manualUnsafeSetStaticSwapFeePercentage(pool, bound(swapFeePercentageRaw, 0, 1e16));
        uint256 swapFeePercentage = vault.getStaticSwapFeePercentage(pool);

        BaseVaultTest.Balances memory balancesBefore = getBalances(alice);

        if (kind == SwapKind.EXACT_IN) {
            vm.prank(alice);
            router.swapSingleTokenExactIn(pool, usdc, dai, amountGivenScaled18, 0, MAX_UINT256, false, bytes(""));
        } else {
            vm.prank(alice);
            router.swapSingleTokenExactOut(
                pool,
                usdc,
                dai,
                amountGivenScaled18,
                MAX_UINT256,
                MAX_UINT256,
                false,
                bytes("")
            );
        }

        uint256 actualSwapFeePercentage = _calculateFee(
            amountGivenScaled18,
            kind,
            swapFeePercentage,
            [poolInitAmount, poolInitAmount].toMemoryArray()
        );

        BaseVaultTest.Balances memory balancesAfter = getBalances(alice);

        uint256 actualAmountOut = balancesAfter.aliceTokens[daiIdx] - balancesBefore.aliceTokens[daiIdx];
        uint256 actualAmountIn = balancesBefore.aliceTokens[usdcIdx] - balancesAfter.aliceTokens[usdcIdx];

        uint256 expectedAmountOut;
        uint256 expectedAmountIn;
        if (kind == SwapKind.EXACT_IN) {
            // extract swap fee
            expectedAmountIn = amountGivenScaled18;
            uint256 swapAmount = amountGivenScaled18.mulUp(actualSwapFeePercentage);

            uint256 amountCalculatedScaled18 = StablePool(pool).onSwap(
                PoolSwapParams({
                    kind: kind,
                    indexIn: usdcIdx,
                    indexOut: daiIdx,
                    amountGivenScaled18: expectedAmountIn - swapAmount,
                    balancesScaled18: [poolInitAmount, poolInitAmount].toMemoryArray(),
                    router: address(0),
                    userData: bytes("")
                })
            );

            expectedAmountOut = amountCalculatedScaled18;
        } else {
            expectedAmountOut = amountGivenScaled18;
            uint256 amountCalculatedScaled18 = StablePool(pool).onSwap(
                PoolSwapParams({
                    kind: kind,
                    indexIn: usdcIdx,
                    indexOut: daiIdx,
                    amountGivenScaled18: expectedAmountOut,
                    balancesScaled18: [poolInitAmount, poolInitAmount].toMemoryArray(),
                    router: address(0),
                    userData: bytes("")
                })
            );
            expectedAmountIn =
                amountCalculatedScaled18 +
                amountCalculatedScaled18.mulDivUp(actualSwapFeePercentage, actualSwapFeePercentage.complement());
        }

        assertEq(expectedAmountIn, actualAmountIn, "Amount in should be expectedAmountIn");
        assertEq(expectedAmountOut, actualAmountOut, "Amount out should be expectedAmountOut");
    }

    function _calculateFee(
        uint256 amountGivenScaled18,
        SwapKind kind,
        uint256 swapFeePercentage,
        uint256[] memory balances
    ) internal view returns (uint256) {
        uint256 amountCalculatedScaled18 = StablePool(pool).onSwap(
            PoolSwapParams({
                kind: kind,
                indexIn: usdcIdx,
                indexOut: daiIdx,
                amountGivenScaled18: amountGivenScaled18,
                balancesScaled18: balances,
                router: address(0),
                userData: bytes("")
            })
        );

        uint256[] memory newBalances = new uint256[](balances.length);
        ScalingHelpers.copyToArray(balances, newBalances);

        if (kind == SwapKind.EXACT_IN) {
            newBalances[usdcIdx] += amountGivenScaled18;
            newBalances[daiIdx] -= amountCalculatedScaled18;
        } else {
            newBalances[usdcIdx] += amountCalculatedScaled18;
            newBalances[daiIdx] -= amountGivenScaled18;
        }

        uint256 newTotalImbalance = stableSurgeMedianMathMock.calculateImbalance(newBalances);
        uint256 oldTotalImbalance = stableSurgeMedianMathMock.calculateImbalance(balances);

        if (
            newTotalImbalance == 0 ||
            (newTotalImbalance <= oldTotalImbalance || newTotalImbalance <= DEFAULT_SURGE_THRESHOLD_PERCENTAGE)
        ) {
            return swapFeePercentage;
        }

        return
            swapFeePercentage +
            (stableSurgeHook.getMaxSurgeFeePercentage(pool) - swapFeePercentage).mulDown(
                (newTotalImbalance - DEFAULT_SURGE_THRESHOLD_PERCENTAGE).divDown(
                    DEFAULT_SURGE_THRESHOLD_PERCENTAGE.complement()
                )
            );
    }
}
