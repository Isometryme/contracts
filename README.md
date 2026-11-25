# Isometry contracts

Vault contracts for copy trading on Hyperliquid, deployed on HyperEVM (chain 999).

A bot is an NFT bound to its creator, with a vault of its own that carries its record. A copy is a second vault, owned by the buyer, that follows the bot inside the buyer's limits. Each vault holds its own HyperCore account, so orders, positions and equity live on Hyperliquid while the rules that govern them live here.

## Layout

| File | Purpose |
| --- | --- |
| `src/BotHub.sol` | Registers bots and their operators, stores targets, carries each target to the copies and then to the bot's own vault |
| `src/CopyMarket.sol` | Sells copies: takes the copy price and the first deposit, splits the price, opens the buyer's vault |
| `src/VaultFactory.sol` | Clones the vault implementation (EIP-1167) for BotHub and CopyMarket |
| `src/AgentVault.sol` | One owner's HyperCore account following one bot: order sizing, limit checks, guard, fees, deposits and withdrawals |
| `src/ProtocolBounds.sol` | Tradable assets and the outer ranges every vault's limits must sit inside |
| `src/HostedOperator.sol` | Operator of hosted bots, forwarding `setTarget` and `ping` from the engine's signer keys |
| `src/FeeCollector.sol` | Receives the protocol's share of copy prices and performance fees |
| `src/PrecompileReader.sol` | Reads equity, positions, oracle prices and size decimals from HyperCore's read precompiles |
| `src/lib/CoreActions.sol` | Encodes the three CoreWriter actions the vault uses: limit order, spot send, USD class transfer |
| `src/Types.sol` | Shared structs and protocol constants |

Every link between contracts is immutable and set in a constructor. The cycle between BotHub, CopyMarket, the vault implementation and the factory is closed by predicting `CREATE` addresses; `test/Base.t.sol` shows the order.

## From a target to an order

1. The bot's operator calls `BotHub.setTarget(botId, asset, targetBps, limitPx)`. `targetBps` is the share of equity to hold, signed for direction.
2. Anyone calls `BotHub.propagate(botId, nonce, maxVaults)`. Copies receive the target in batches, and the bot's own vault receives it once every copy has.
3. Each vault sizes the order from its own equity and the HyperCore oracle price, clamps it to its leverage, asset list and order size, prices it inside its band, and sends it to HyperCore as an IOC limit order.
4. A vault that cannot take the order emits `ApplySkipped(vault, reason)` and the batch carries on.

## The guard

`checkGuard()` is open to anyone. It trips a vault when equity falls below the peak by more than the drawdown limit, when the day's loss passes the daily limit, or when the bot has been silent longer than the vault's heartbeat. A tripped vault takes reduce-only orders only, and `unwind(asset)` closes each position at the edge of the exit band.

## Fees in code

| Constant | Value | Meaning |
| --- | --- | --- |
| `COPY_PRICE_PROTOCOL_BPS` | 500 | 5% of the copy price to the protocol, the rest to the bot creator |
| `MAX_PERF_FEE_BPS` | 3000 | Highest performance fee a bot can set |
| `SELLER_PERF_SHARE_BPS` | 8000 | 80% of a copy's performance fee to the bot creator |
| `HOSTED_PLATFORM_FEE_BPS` | 1000 | Fee on profit of a hosted bot's own vault |
| `CRYSTALLISE_INTERVAL` | 30 days | Shortest time between two performance fee charges |
| `FEE_RAISE_DELAY` | 7 days | Wait before a higher performance fee applies |
| `MIN_COPY_PRICE` | 1 USDC | Lowest copy price |
| `MIN_MASTER_EQUITY` | 10 USDC | Equity a bot's vault needs before it can be listed |

Performance fees count profit above a high-water mark, rounding toward the payer, and the creator's and protocol's parts always add up to the fee charged.

## Deployed on HyperEVM (999)

| Contract | Address |
| --- | --- |
| BotHub | [`0x0DC615730abb364f6b6985e814DA7E14Bc0239b2`](https://hyperevmscan.io/address/0x0DC615730abb364f6b6985e814DA7E14Bc0239b2) |
| CopyMarket | [`0x74AC8b9cef515dd6068D6c358263d91cCEdd558B`](https://hyperevmscan.io/address/0x74AC8b9cef515dd6068D6c358263d91cCEdd558B) |
| VaultFactory | [`0x00c8A079979CbAc837755d0076e45Ae68bAA4434`](https://hyperevmscan.io/address/0x00c8A079979CbAc837755d0076e45Ae68bAA4434) |
| AgentVault (implementation) | [`0x9e9bC68396099fdd768a754709CC1fd55A282825`](https://hyperevmscan.io/address/0x9e9bC68396099fdd768a754709CC1fd55A282825) |
| ProtocolBounds | [`0x2Db348548d3A204c5F6cdb03d7de9Bc04bF72715`](https://hyperevmscan.io/address/0x2Db348548d3A204c5F6cdb03d7de9Bc04bF72715) |
| HostedOperator | [`0x4EEa061be9c4401aB4FF56ECa43Cd6Ea6eb623D3`](https://hyperevmscan.io/address/0x4EEa061be9c4401aB4FF56ECa43Cd6Ea6eb623D3) |
| FeeCollector | [`0x16a1242B0B383f3658FEfB85470D7B3757aB5f50`](https://hyperevmscan.io/address/0x16a1242B0B383f3658FEfB85470D7B3757aB5f50) |
| PrecompileReader | [`0xDc27688Ca76436081E24AC25D9D8C684dE127D99`](https://hyperevmscan.io/address/0xDc27688Ca76436081E24AC25D9D8C684dE127D99) |

USDC on HyperEVM is `0xb88339CB7199b77E23DB6E890353E22632Ba630f`; deposits reach HyperCore through Circle's CoreDepositWallet at `0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24`.

## Build and test

Requires [Foundry](https://getfoundry.sh). `forge-std` is vendored in `lib/`, so a plain clone builds.

```bash
forge build
forge test
```

`forge test` runs 189 tests in 15 suites: unit tests per contract, an economics suite, a deterministic deep run across many vaults, and an invariant campaign with these properties:

| Invariant | Property |
| --- | --- |
| `invariant_A1_vaultsHoldExactlyWhatTheyOwe` | What each vault holds on HyperEVM, plus what is on its way, equals what it owes its owner, the creator and the protocol |
| `invariant_G8_G9_onlyKnownActionsOnValidTicks` | Vaults send only the three known CoreWriter actions, priced on valid ticks |
| `invariant_M1_botsStayWithTheirCreator` | A bot NFT stays with the address that registered it |
| `invariant_IR2_signersAreTheAdminsList` | The hosted signer set changes only through its two listed functions |

## Reproducing the deployed bytecode

The compiler is pinned in `foundry.toml` (solc 0.8.38, `via_ir`, 200 runs, Cancun). Build, then compare each artifact's `deployedBytecode` with `eth_getCode` at the address above, masking the positions listed in `immutableReferences`. All eight contracts match exactly, the CBOR metadata hash included. The [verify](https://github.com/Isometryme/verify) repository does this in one command.

## License

[MIT](LICENSE)
