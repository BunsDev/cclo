# Cross-Chain Liquidity Operator (CCLO)

A simple way to add liquidity to Uniswap V4 pools on multiple chains using Uniswap v4 hooks and Chainlink's CCIP.

## Why CCLO?

### Liquidity is fragmented

- With the rise of L2s such as Arbitrum, Optimism, and more, users are moving their funds across a multitude of chains to explore and use different applications.
- This introduces large amounts of liquidity fragmentation, where doing a swap on a particular chain can introduce large amounts of slippage.
- This is bad for users because they feel locked into chains once they have shifted their liquidity around. Frequent bridging introduces vulnerability to smart contract hacks and make an unpleasant experience.
- This bad for developers because developing on chains with lesser liquidity can mean lesser users because users tend to follow where the liquidity is best.

### We can fix this problem with chain abstraction over Uniswap v4 and Chainlink's CCIP

- Uniswap v4 introduces hooks where we can run arbitrary logic before and after different actions such as a swap, or modification of liquidity.
- CCLO is a hook contract designed to allow chain abstraction and greater sharing of liquidity across chains by providing a seamless integration of multiple chains behind the scenes.

**Users can provide liquidity across multiple chains simply by interacting with a single hook contract on one chain.**

## CCLO Architecture

![CCLO Architecture](./cclo-architecture.png)

## Example sequence

To be added.

## Future Improvements

#### Just-in-time (JIT) liquidity provision for swaps:

- User makes a swap on chain A which does not have either 1) enough liquidity to support the swap or 2) non-optimal amount of liquidity (introduces large slippage)
- CCLO bridges over liquidity from other chains to pool together liquidity for the user to have a more optimal swap

#### Complex strategies for swaps and liquidity provision:

- Due to the time limitations of the hookathon, in our demo, we demonstrate the ability to provide liquidity in a fix split across 2 chains.
- More complex strategies for sharing liquidity can be adopted so users have a wider selection. Further, liquidity sharing can be more dynamic and actively balanced by others e.g. Eigenlayer AVS
