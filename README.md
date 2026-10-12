# contracts

Proyek Foundry untuk kontrak kota (vault ERC-4626, adapter yield, kunci wakil). Isi kontrak dikerjakan di T5, sesudah keputusan Gate A (sudah diputuskan: C, hibrida).

## Toolchain

- Foundry 1.8.5 (`forge`, `cast`, `anvil`); syarat Monad: Foundry >= 1.8.0.
- `solc` 0.8.37, `evm_version = "osaka"`, `network = "monad"`, optimizer 200 run (lihat `foundry.toml`).
- OpenZeppelin Contracts v5.7.0 (commit `cab19933c33c2ad1d4c7a84864a3601dddfd16f3`) dan forge-std, disalin ke `lib/` tanpa submodule (`--no-git`).
- Remapping ada di `remappings.txt`.

## Perintah

```
export PATH="$PATH:$HOME/.foundry/bin"
forge build
forge test
forge test --fork-url $MONAD_MAINNET_RPC   # fork test mainnet, hanya setelah variabel di .env diisi
```

Alias RPC `monad_testnet` dan `monad_mainnet` membaca `MONAD_TESTNET_RPC` dan `MONAD_MAINNET_RPC` dari lingkungan. Variabel itu hanya perlu diisi saat alias dipakai.

## Memasang ulang pustaka

```
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0 --no-git
forge install foundry-rs/forge-std --no-git
```
