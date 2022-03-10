// SPDX-License-Identifier: Unlicensed

pragma solidity >=0.8.4;

import '../libraries/Directives.sol';
import '../libraries/Encoding.sol';
import '../libraries/TokenFlow.sol';
import '../libraries/PriceGrid.sol';
import '../mixins/MarketSequencer.sol';
import '../mixins/SettleLayer.sol';
import '../mixins/PoolRegistry.sol';
import '../mixins/MarketSequencer.sol';
import '../mixins/ProtocolAccount.sol';
import '../mixins/ColdInjector.sol';

import "hardhat/console.sol";


/* @title Warm path callpath sidecar.
 * @notice Defines a proxy sidecar contract that's used to move code outside the 
 *         main contract to avoid Ethereum's contract code size limit. Contains top-
 *         level logic for the core liquidity provider actions:
 *              * Mint ambient liquidity
 *              * Mint concentrated range liquidity
 *              * Burn ambient liquidity
 *              * Burn concentrated range liquidity
 *         These methods are exposed as atomic single-action calls. Useful for traders
 *         who only need to execute a single action, and want to get the lowest gas fee
 *         possible. Compound calls are available in LongPath, but the overhead with
 *         parsing a longer OrderDirective makes the gas cost higher.
 * 
 * @dev    This exists as a standalone contract but will only ever contain proxy code,
 *         not state. As such it should never be called directly or externally, and should
 *         only be invoked with DELEGATECALL so that it operates on the contract state
 *         within the primary CrocSwap contract. */
contract WarmPath is MarketSequencer, SettleLayer, PoolRegistry, ProtocolAccount {

    using SafeCast for uint128;
    using TokenFlow for TokenFlow.PairSeq;
    using CurveMath for CurveMath.CurveState;
    using Chaining for Chaining.PairFlow;

    /* @notice Consolidated method for all atomic liquidity provider actions.
     * @dev    We consolidate multiple call types into a single method to reduce the 
     *         contract size in the main contract by paring down methods.
     * 
     * @param code The command code corresponding to the actual method being called. */
    function userCmd (bytes calldata input) public payable {
        (uint8 code, address base, address quote, uint256 poolIdx,
         int24 bidTick, int24 askTick, uint128 liq,
         uint128 limitLower, uint128 limitHigher,
         uint8 reserveFlags, address lpConduit) =
            abi.decode(input, (uint8,address,address,uint256,int24,int24,
                               uint128,uint128,uint128,uint8,address));
        
        if (code == 1) {
            mint(base, quote, poolIdx, bidTick, askTick, liq, lpConduit,
                 limitLower, limitHigher, reserveFlags);
        } else if (code == 11) {
            mintQty(base, quote, poolIdx, bidTick, askTick, true, liq, lpConduit,
                 limitLower, limitHigher, reserveFlags);
        } else if (code == 12) {
            mintQty(base, quote, poolIdx, bidTick, askTick, false, liq, lpConduit,
                 limitLower, limitHigher, reserveFlags);
            
        } else if (code == 2) {
            burn(base, quote, poolIdx, bidTick, askTick, liq,
                 limitLower, limitHigher, reserveFlags);
        } else if (code == 21) {
            burnQty(base, quote, poolIdx, bidTick, askTick, true, liq,
                 limitLower, limitHigher, reserveFlags);
        } else if (code == 22) {
            burnQty(base, quote, poolIdx, bidTick, askTick, false, liq,
                 limitLower, limitHigher, reserveFlags);
            
        } else if (code == 3) {
            mint(base, quote, poolIdx, liq, lpConduit, limitLower, limitHigher,
                 reserveFlags);
        } else if (code == 31) {
            mintQty(base, quote, poolIdx, true, liq, lpConduit, limitLower, limitHigher,
                    reserveFlags);
        } else if (code == 32) {
            mintQty(base, quote, poolIdx, false, liq, lpConduit, limitLower, limitHigher,
                    reserveFlags);
            
        } else if (code == 4) {
            burn(base, quote, poolIdx, liq, limitLower, limitHigher, reserveFlags);
        } else if (code == 41) {
            burnQty(base, quote, poolIdx, true, liq, limitLower, limitHigher,
                    reserveFlags);
        } else if (code == 42) {
            burnQty(base, quote, poolIdx, false, liq, limitLower, limitHigher,
                    reserveFlags);
            
        } else if (code == 5) {
            harvest(base, quote, poolIdx, bidTick, askTick, limitLower, limitHigher,
                    reserveFlags);            
        }
    }

    /* @notice Mints liquidity as a concentrated liquidity range order.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being minted on.
     * @param bidTick The price tick index of the lower boundary of the range order.
     * @param askTick The price tick index of the upper boundary of the range order.
     * @param liq The total amount of liquidity being minted. Represented as sqrt(X*Y)
     *            for the equivalent constant-product AMM.
     @ @param lpConduit The address of the LP conduit to deposit the minted position at
     *                  (direct owned liquidity if 0)
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is minted at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold.
     * @param reserveFlags If true, settlement is first attempted with the surplus 
     *                   collateral (if any) that the user holds at the exchange. */    
    function mint (address base, address quote, uint256 poolIdx,
                   int24 bidTick, int24 askTick, uint128 liq, address lpConduit, 
                   uint128 limitLower, uint128 limitHigher,
                   uint8 reserveFlags) internal {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        verifyPermitMint(pool, base, quote, bidTick, askTick, liq);

        (int128 baseFlow, int128 quoteFlow) =
            mintOverPool(bidTick, askTick, liq, pool, limitLower, limitHigher,
                         lpConduit);
        settleFlows(base, quote, baseFlow, quoteFlow, reserveFlags);
    }
    
    /* @notice Burns liquidity as a concentrated liquidity range order.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being burned on.
     * @param bidTick The price tick index of the lower boundary of the range order.
     * @param askTick The price tick index of the upper boundary of the range order.
     * @param liq The total amount of liquidity being burned. Represented as sqrt(X*Y)
     *            for the equivalent constant-product AMM.
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is burned at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold. 
     * @param reserveFlags If true, settlement is first attempted with the surplus 
     *                   collateral (if any) that the user holds at the exchange. */
    function burn (address base, address quote, uint256 poolIdx,
                   int24 bidTick, int24 askTick, uint128 liq,
                   uint128 limitLower, uint128 limitHigher, uint8 reserveFlags) internal {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        verifyPermitBurn(pool, base, quote, bidTick, askTick, liq);
        
        (int128 baseFlow, int128 quoteFlow) =
            burnOverPool(bidTick, askTick, liq, pool, limitLower, limitHigher);
        settleFlows(base, quote, baseFlow, quoteFlow, reserveFlags);
    }

    /* @notice Harvests the rewards for a concentrated liquidity position.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being burned on.
     * @param bidTick The price tick index of the lower boundary of the range order.
     * @param askTick The price tick index of the upper boundary of the range order.
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is burned at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold. 
     * @param reserveFlags If true, settlement is first attempted with the surplus 
     *                   collateral (if any) that the user holds at the exchange. */
    function harvest (address base, address quote, uint256 poolIdx,
                      int24 bidTick, int24 askTick, 
                      uint128 limitLower, uint128 limitHigher, uint8 reserveFlags)
        internal {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        
        // On permissioned pools harvests are treated like a special case burn
        // with 0 liquidity. Note that unlike a true 0 burn, ambient liquidity will still
        // be returned, so oracles should handle 0 as special case if that's an issue. 
        verifyPermitBurn(pool, base, quote, bidTick, askTick, 0);
        
        (int128 baseFlow, int128 quoteFlow) =
            harvestOverPool(bidTick, askTick, pool, limitLower, limitHigher);
        settleFlows(base, quote, baseFlow, quoteFlow, reserveFlags);
    }

    /* @notice Mints ambient liquidity that's active at every price.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being minted on.
     * @param liq The total amount of liquidity being minted. Represented as sqrt(X*Y)
     *            for the equivalent constant-product AMM.
     @ @param lpConduit The address of the LP conduit to deposit the minted position at
     *                  (direct owned liquidity if 0)
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is minted at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold. 
     * @param reserveFlags If true, settlement is first attempted with the surplus 
     *                   collateral (if any) that the user holds at the exchange. */
    function mint (address base, address quote, uint256 poolIdx, uint128 liq,
                   address lpConduit, uint128 limitLower, uint128 limitHigher,
                   uint8 reserveFlags) internal {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        verifyPermitMint(pool, base, quote, 0, 0, liq);
        
        (int128 baseFlow, int128 quoteFlow) =
            mintOverPool(liq, pool, limitLower, limitHigher, lpConduit);
        settleFlows(base, quote, baseFlow, quoteFlow, reserveFlags);
    }

    function mintQty (address base, address quote, uint256 poolIdx, bool inBase,
                      uint128 qty, address lpConduit, uint128 limitLower,
                      uint128 limitHigher, uint8 reserveFlags) internal {
        bytes32 poolKey = PoolSpecs.encodeKey(base, quote, poolIdx);
        CurveMath.CurveState memory curve = snapCurve(poolKey);
        uint128 liq = Chaining.sizeAmbientLiq(qty, true, curve.priceRoot_, inBase);
        mint(base, quote, poolIdx, liq, lpConduit, limitLower, limitHigher, reserveFlags);
    }

    function mintQty (address base, address quote, uint256 poolIdx,
                      int24 bidTick, int24 askTick, bool inBase,
                      uint128 qty, address lpConduit, uint128 limitLower,
                      uint128 limitHigher, uint8 reserveFlags) internal {
        bytes32 poolKey = PoolSpecs.encodeKey(base, quote, poolIdx);
        CurveMath.CurveState memory curve = snapCurve(poolKey);
        uint128 liq = Chaining.sizeConcLiq(qty, true, curve.priceRoot_,
                                           bidTick, askTick, inBase);
        mint(base, quote, poolIdx, bidTick, askTick,
             liq, lpConduit, limitLower, limitHigher, reserveFlags);
    }

    
    /* @notice Burns ambient liquidity that's active at every price.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being burned on.
     * @param liq The total amount of liquidity being burned. Represented as sqrt(X*Y)
     *            for the equivalent constant-product AMM.
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is burned at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold. 
     * @param reserveFlags If true, settlement is first attempted with the surplus 
     *                   collateral (if any) that the user holds at the exchange. */
    function burn (address base, address quote, uint256 poolIdx, uint128 liq,
                   uint128 limitLower, uint128 limitHigher, uint8 reserveFlags) internal {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        verifyPermitBurn(pool, base, quote, 0, 0, liq);
        
        (int128 baseFlow, int128 quoteFlow) =
            burnOverPool(liq, pool, limitLower, limitHigher);
        settleFlows(base, quote, baseFlow, quoteFlow, reserveFlags);
    }

    function burnQty (address base, address quote, uint256 poolIdx, bool inBase,
                      uint128 qty, uint128 limitLower, uint128 limitHigher,
                      uint8 reserveFlags) internal {
        bytes32 poolKey = PoolSpecs.encodeKey(base, quote, poolIdx);
        CurveMath.CurveState memory curve = snapCurve(poolKey);
        uint128 liq = Chaining.sizeAmbientLiq(qty, false, curve.priceRoot_, inBase);
        burn(base, quote, poolIdx, liq, limitLower, limitHigher, reserveFlags);
    }

    function burnQty (address base, address quote, uint256 poolIdx,
                      int24 bidTick, int24 askTick, bool inBase,
                      uint128 qty, uint128 limitLower,
                      uint128 limitHigher, uint8 reserveFlags) internal {
        bytes32 poolKey = PoolSpecs.encodeKey(base, quote, poolIdx);
        CurveMath.CurveState memory curve = snapCurve(poolKey);
        uint128 liq = Chaining.sizeConcLiq(qty, false, curve.priceRoot_,
                                           bidTick, askTick, inBase);
        burn(base, quote, poolIdx, bidTick, askTick,
             liq, limitLower, limitHigher, reserveFlags);
    }
}
