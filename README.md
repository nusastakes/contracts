# nusastakes/contracts

Smart contracts for **Nusastakes**: every city is an ERC-4626 vault on Monad. Residents deposit a stablecoin, a mayor
spreads it over platform-approved adapters, and earns a fee only on the profit above a per-city high-water mark. No
function can send city funds anywhere except to that city's own adapters or to a share holder who is withdrawing.

> **Status: testnet demo, not audited, not deployed yet.** Tidak ada alamat deploy di dokumen ini sampai kontrak
> benar-benar di-deploy. Yield di testnet adalah **simulasi** (lihat `MirrorYieldAdapter`); satu-satunya integrasi
> protokol sungguhan yang diuji adalah `ERC4626Adapter` ke vault Morpho AUSD di fork mainnet.

## Kontrak

| Kontrak | Fungsi |
| --- | --- |
| `CityFactory` | Siapa saja mendirikan kota (`createCity`); platform hanya mengatur daftar implementasi adapter, parameter adapter, dan batas (fee maksimum, potongan platform, batas deposit). |
| `CityVault` | Vault ERC-4626 per kota. Fee kinerja dengan high-water mark dicetak sebagai share ke walikota dan treasury; `rebalance` hanya antara idle dan adapter kota itu dengan batas per panggilan; kunci wakil (`setDeputy`) hanya boleh `rebalance`; `depositWithPermit` untuk deposit tanpa gas lewat relayer; `evacuate` oleh guardian hanya ke idle. |
| `CityGuardian` | Izin agen AI per kota (Satpam, Analis, Humas), usulan Analis yang harus disetujui walikota, dan penerima laporan Chainlink CRE untuk evakuasi. |
| `CreConsumer` | Pemeriksaan tambahan untuk laporan CRE: target, chain selector, dan identitas workflow harus dikunci sebelum laporan diterima. |
| `adapters/ERC4626Adapter` | Adapter generik ke vault ERC-4626 mana pun yang asetnya sama (diuji ke Morpho di fork mainnet). |
| `adapters/MirrorYieldAdapter` | **Simulasi** yield untuk testnet: mengikuti APY vault AUSD mainnet dari `ApyFeed`, dibayar dari `YieldReserve`. Selalu diberi label simulasi. |
| `ApyFeed` | Catatan APY vault mainnet, ditulis keeper atau laporan CRE yang tervalidasi. |
| `YieldReserve` | AUSD faucet milik platform; setiap adapter mendapat jatah yield sendiri sehingga saldo yang sama tidak dihitung dua kali. |

## Cara menjalankan

Butuh Foundry >= 1.8.0 (diuji dengan 1.8.5). Kompilator `solc` 0.8.37, `evm_version = "osaka"`, `network = "monad"`.

```
curl -L https://foundry.paradigm.xyz | bash && foundryup
export PATH="$PATH:$HOME/.foundry/bin"

forge build
forge test                                            # tanpa jaringan; fork test dilewati
MONAD_MAINNET_RPC=https://rpc.monad.xyz forge test    # termasuk fork test Morpho mainnet
```

Alias RPC `monad_testnet` dan `monad_mainnet` di `foundry.toml` membaca `MONAD_TESTNET_RPC` dan `MONAD_MAINNET_RPC`
dari lingkungan. Jangan menaruh private key di file; deploy memakai variabel lingkungan.

Memasang ulang pustaka bila `lib/` kosong:

```
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0 --no-git
forge install foundry-rs/forge-std --no-git
```

## Tes

Tes unit, fuzz, dan invarian (termasuk dua kota yang berbagi satu `YieldReserve`) ada di `test/`. Fork test
`test/fork/MorphoFork.t.sol` menyetor ke vault Morpho "Grove x Steakhouse High Yield AUSD" di Monad mainnet dengan
batas 200 AUSD, melakukan `rebalance`, lalu menarik semuanya (Morpho membulatkan setoran turun 1 satuan terkecil,
jadi 200 AUSD menjadi 199,999998 di dalam vault; penarikan penuh memakai `redeem`). Bunga 30 hari di fork hanya
simulasi waktu (`vm.warp`), bukan yield nyata. `forge test` tanpa RPC melewati tes ini.

## Batasan yang diketahui

Ditemukan oleh tinjauan independen dan sengaja belum diubah:

- **Satu adapter rusak mengunci kota** (F-02): bila `totalAssets()` sebuah adapter revert, semua fungsi yang menghitung
  harga share ikut revert, dan daftar adapter tidak bisa diubah setelah kota dibuat. Ada placeholder `TODO(F-02)` di
  `CityVault.totalAssets()`. Mitigasi sekarang: adapter hanya dari daftar platform dan bukti mainnet dibatasi 200 AUSD.
- **Batas pergeseran per panggilan, bukan kumulatif** (F-05): `maxShiftBps` dan batas kunci wakil berlaku per
  panggilan `rebalance`, jadi beberapa panggilan berurutan bisa memindahkan lebih banyak. Dana tetap hanya bergerak
  antara idle dan adapter kota itu.
- `maxWithdraw`/`maxRedeem` tidak memperhitungkan likuiditas adapter; `setFee` berlaku seketika sampai batas factory;
  APY terakhir di `ApyFeed` terus berlaku bila keeper berhenti.

Belum diaudit oleh manusia.

## Repo lain di organisasi

- [nusastakes/web](https://github.com/nusastakes/web): antarmuka web dan kota 3D
- [nusastakes/relayer](https://github.com/nusastakes/relayer): relayer gas dan keeper APY
- [nusastakes/cre-guardian](https://github.com/nusastakes/cre-guardian): workflow Chainlink CRE "City Guardian"

## Penggunaan alat AI

- Kontrak dan tes ditulis dengan Claude Code (model Claude Sonnet 5.5 untuk pengerjaan; Claude Opus untuk rencana dan
  pemeriksaan ulang). Satu tinjauan adversarial dilakukan oleh agen Claude terpisah yang menulis PoC; temuannya
  (termasuk satu bug nyata pada reserve yield bersama) diperbaiki dan diberi tes regresi.
- Semua keluaran AI diperiksa pengembang. Klaim yang belum diuji ditulis "belum diuji" di dokumentasi. Tinjauan AI
  bukan pengganti audit manusia.
- LLM tidak pernah memindahkan dana di luar aturan deterministik kontrak: agen hanya bisa mengusulkan (disetujui
  walikota) atau mengevakuasi dana ke idle.

## Komponen yang sudah ada sebelumnya

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) v5.7.0 (commit
  `cab19933c33c2ad1d4c7a84864a3601dddfd16f3`, MIT), disalin ke `lib/openzeppelin-contracts` tanpa submodule.
- [forge-std](https://github.com/foundry-rs/forge-std) di `lib/forge-std`.
- `src/vendor/chainlink/IReceiver.sol` dan `ReceiverTemplate.sol` dari `smartcontractkit/documentation` (MIT), hanya
  impor `IERC165` yang diubah; asal dan SHA-256 ada di `src/vendor/chainlink/README.md`.
- Foundry sebagai toolchain.

## Lisensi

MIT. Lihat `LICENSE`.
