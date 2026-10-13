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
| `CityFactory` | Siapa saja mendirikan kota (`createCity`); `cityInfos(start, count)` mengembalikan data semua kota dalam satu panggilan; platform hanya mengatur daftar implementasi adapter, parameter adapter, dan batas (fee maksimum, potongan platform, batas deposit). |
| `CityVault` | Vault ERC-4626 per kota. Fee kinerja dengan high-water mark dicetak sebagai share ke walikota dan treasury; `rebalance` hanya antara idle dan adapter kota itu dengan batas per panggilan; kunci sesi (`setSessionKey`, kunci kedua milik walikota untuk kerja harian) hanya boleh `rebalance`; `depositWithPermit` dan `redeemWithPermit` (share vault punya `permit`) untuk setor dan tarik tanpa gas lewat relayer; metadata kota (`community`, `mapURI`, `createdAt`) tersimpan onchain; `evacuate` oleh guardian hanya ke idle. |
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

## Alamat deploy (Monad testnet, chainId 10143)

Deploy ke-2, 13 Okt 2026, dengan `script/Deploy.s.sol`; kelima kontrak terverifikasi `exact_match` di Sourcify (MonadVision).
Daftar lengkap dengan hash transaksi dan blok: `deployments/monad-testnet.json`. Deploy pertama
(`deployments/monad-testnet.superseded-1.json`) sudah digantikan karena kontrak berubah; jangan dipakai.

| Kontrak | Alamat |
| --- | --- |
| `CityFactory` | [`0x6765F0C80F6a7D5EC7Af120d12e81628F641508E`](https://testnet.monadvision.com/address/0x6765F0C80F6a7D5EC7Af120d12e81628F641508E) |
| `CityGuardian` | [`0x083899bEE8138E5f951db568926393FDb1F418A2`](https://testnet.monadvision.com/address/0x083899bEE8138E5f951db568926393FDb1F418A2) |
| `ApyFeed` | [`0x707A675DDc976B0E9C6B520Dbd0326204F30d540`](https://testnet.monadvision.com/address/0x707A675DDc976B0E9C6B520Dbd0326204F30d540) |
| `YieldReserve` | [`0x18B15f540E231Fb75F9c86a080a69c3D0FAB27C1`](https://testnet.monadvision.com/address/0x18B15f540E231Fb75F9c86a080a69c3D0FAB27C1) |
| `MirrorYieldAdapter` (implementasi) | [`0x25BcA4f0ea34F115Cb7c620626fBBa95647E8690`](https://testnet.monadvision.com/address/0x25BcA4f0ea34F115Cb7c620626fBBa95647E8690) |
| AUSD testnet (bukan milik kami) | `0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC` |

`YieldReserve` berisi 30.000 AUSD testnet dari faucet publik. Yield yang dibayarkan adalah **simulasi** yang mengikuti
APY vault AUSD di mainnet; keeper di repo `relayer` menulis APY ke `ApyFeed` (saat ini sekitar 128 bps).
ABI JSON semua kontrak ada di `abi/` (dibuat ulang dengan `script/export-abi.sh`).

## Deploy ke Monad testnet

`script/Deploy.s.sol` men-deploy `CityGuardian`, `CityFactory`, `ApyFeed`, `YieldReserve`, dan implementasi
`MirrorYieldAdapter`, lalu menyambungkannya (adapter diizinkan, parameter sumber APY diset platform). Satu-satunya
rahasia adalah `DEPLOYER_PRIVATE_KEY`, dibaca dari environment, bukan dari file di repo.

```
export PATH="$PATH:$HOME/.foundry/bin"
cp ../.env.example ../.env          # isi DEPLOYER_PRIVATE_KEY (dan PLATFORM_TREASURY bila perlu); .env tidak ikut git
set -a; . ../.env; set +a

forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC                 # simulasi, tidak mengirim apa pun
forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast     # deploy sungguhan

./script/fund-reserve.sh <alamat YieldReserve> 3                              # isi reserve dari faucet AUSD (10.000 AUSD per tetes)
```

Pengaturan bawaan (semua bisa diganti lewat environment): aset AUSD testnet
`0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC`, forwarder CRE produksi `0xF8344CFd5c43616a4366C34E3EEE75af79a74482`,
chain selector `2183018362218727504`, batas deposit 1.000.000 AUSD per kota (`DEPOSIT_CAP`), jatah yield simulasi
1.000 AUSD per kota (`YIELD_QUOTA_PER_CITY`), `APY_UPDATER` dan `PLATFORM_TREASURY` sama dengan deployer. Laporan CRE
ditolak sampai pemilik mengunci `expectedAuthor` atau `expectedWorkflowId` pada guardian dan feed.

Monad menagih gas limit, bukan gas yang terpakai, dan base fee testnet sekitar 100 gwei; simulasi memperkirakan
sekitar 12,3 juta gas untuk seluruh skrip. Wallet yang baru diisi butuh beberapa detik sebelum bisa mengirim transaksi.

## Bukti mainnet (B4.8): skrip siap, belum dijalankan

Dua skrip menyiapkan bukti R25: satu kota kecil di Monad mainnet (chain 143) yang berinvestasi di vault Morpho
"Grove x Steakhouse High Yield AUSD" sungguhan, tanpa yield simulasi.

- `script/DeployMainnet.s.sol` men-deploy `CityGuardian`, `CityFactory` (batas deposit 200 AUSD), implementasi
  `ERC4626Adapter` yang diizinkan dengan parameter vault Morpho, lalu mendirikan satu kota. Deployer menjadi pemilik,
  walikota, dan treasury.
- `script/MainnetProof.s.sol` dijalankan dua kali oleh walikota yang sama: `PHASE=in AMOUNT=20000000 CITY=0x…`
  (approve, setor, pindahkan ke Morpho dalam beberapa `rebalance` sesuai batas per panggilan) dan, beberapa waktu
  kemudian, `PHASE=out CITY=0x…` (tarik kembali ke idle lalu `redeem` semua share).

Pengaman yang dipaksa di kode: berhenti bila bukan chain 143; kuncinya `MAINNET_DEPLOYER_PRIVATE_KEY`, variabel
berbeda dari `DEPLOYER_PRIVATE_KEY` testnet, sehingga skrip testnet tidak bisa menyentuh mainnet; batas deposit dan
`AMOUNT` paling banyak 200 AUSD; vault target harus ada dan asetnya AUSD. Tanpa `--broadcast` skrip hanya simulasi.

```
set -a; . ../.env; set +a                  # butuh MAINNET_DEPLOYER_PRIVATE_KEY dan MONAD_MAINNET_RPC
forge script script/DeployMainnet.s.sol --rpc-url $MONAD_MAINNET_RPC               # simulasi di fork
forge script script/DeployMainnet.s.sol --rpc-url $MONAD_MAINNET_RPC --broadcast   # sungguhan, butuh MON
PHASE=in AMOUNT=20000000 CITY=0x… forge script script/MainnetProof.s.sol --rpc-url $MONAD_MAINNET_RPC --broadcast
PHASE=out CITY=0x…                forge script script/MainnetProof.s.sol --rpc-url $MONAD_MAINNET_RPC --broadcast
```

Yang sudah diuji: `test/fork/MainnetScripts.t.sol` menjalankan kedua skrip di fork mainnet dengan kunci sekali pakai
(deploy, setor 20 AUSD, pindah ke Morpho, maju 30 hari dengan `vm.warp`, tarik kembali, `redeem`; dompet kembali utuh
sampai debu pembulatan) dan memeriksa penolakan batas di atas 200 AUSD. `forge script` tanpa `--broadcast` terhadap RPC
mainnet berjalan dan memperkirakan sekitar 11,2 juta gas, kira-kira 2,3 MON untuk deploy. Yang belum: tidak ada
transaksi mainnet yang pernah dikirim, dan `MainnetProof` belum diukur gasnya di jaringan. Eksekusi butuh dompet
mainnet dengan sekitar 20 sampai 50 AUSD dan beberapa MON, dan izin pemilik proyek.

## Batasan yang diketahui

Ditemukan oleh tinjauan independen dan sengaja belum diubah:

- **Satu adapter rusak mengunci kota** (F-02): bila `totalAssets()` sebuah adapter revert, semua fungsi yang menghitung
  harga share ikut revert, dan daftar adapter tidak bisa diubah setelah kota dibuat. Ada placeholder `TODO(F-02)` di
  `CityVault.totalAssets()`. Mitigasi sekarang: adapter hanya dari daftar platform dan bukti mainnet dibatasi 200 AUSD.
- **Batas pergeseran per panggilan, bukan kumulatif** (F-05): `maxShiftBps` dan batas kunci sesi berlaku per
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
