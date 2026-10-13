# nusastakes/contracts

Smart contracts for **Nusastakes**: every city is an ERC-4626 vault on Monad. Residents deposit a stablecoin, a mayor
spreads it over platform-approved adapters, and earns a fee only on the profit above a per-city high-water mark. No
function can send city funds anywhere except to that city's own adapters or to a share holder who is withdrawing.

> **Status: testnet demo (v3), not audited by a human.** Deployed on Monad testnet only; the addresses are in the table
> below and in `deployments/monad-testnet.json`. Yield di testnet adalah **simulasi** (lihat `MirrorYieldAdapter`);
> satu-satunya integrasi protokol sungguhan yang diuji adalah `ERC4626Adapter` ke vault Morpho AUSD di fork mainnet.

## Kontrak

| Kontrak | Fungsi |
| --- | --- |
| `CityFactory` | Siapa saja mendirikan kota (`createCity`); `cityInfos(start, count)` mengembalikan data semua kota dalam satu panggilan; platform hanya mengatur daftar implementasi adapter, parameter adapter, dan batas (fee maksimum, potongan platform, batas deposit). |
| `CityVault` | Vault ERC-4626 per kota. Fee kinerja dengan high-water mark dicetak sebagai share ke walikota dan treasury; `rebalance` hanya antara idle dan adapter kota itu dengan batas per panggilan; kunci sesi (`setSessionKey`, kunci kedua milik walikota untuk kerja harian) hanya boleh `rebalance`; `depositWithPermit` dan `redeemWithPermit` (share vault punya `permit`) untuk setor dan tarik tanpa gas lewat relayer; metadata kota (`community`, `mapURI`, `createdAt`, `style`) tersimpan onchain; `evacuate` oleh guardian hanya ke idle. **v3:** `quarantine`/`restoreAdapter` (siapa pun, hanya bila adapter benar-benar gagal) mengisolasi satu adapter rusak tanpa mengunci kota: adapter itu dihitung nol, setoran dan perubahan fee berhenti, dan semua yang menarik dibayar harga likuid yang sama; kunci sesi punya anggaran kumulatif per jam (`sessionBudgetBps`, bawaan 20%). |
| `CityGuardian` | Izin agen AI per kota (Satpam, Analis, Humas), usulan Analis yang harus disetujui walikota, dan penerima laporan Chainlink CRE untuk evakuasi. **v3:** `onHire` menerima sewa dari `AgentMarketplace` (hanya dari marketplace yang dikonfigurasi, hanya untuk walikota kota itu, tidak pernah untuk Satpam). |
| `AgentMarketplace` | **v3.** Marketplace umum untuk agen ERC-8004 (tidak tahu soal kota): pemilik agen memasang layanan dengan harga per periode, klien menyewa dan membayar **langsung ke dompet agen** (dikurangi biaya platform maksimal 10%), lalu hook opsional dipanggil (`CityGuardian` memberi peran di kota; aplikasi lain bisa menulis hook sendiri). Tidak pernah menyimpan dana; statistik sewa dan pendapatan dari pembayaran nyata. |
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

**v3 revisi 2**, 13 Okt 2026, dengan `script/Deploy.s.sol`; keenam kontrak terverifikasi `exact_match` di Sourcify (MonadVision).
Daftar lengkap dengan hash transaksi dan blok: `deployments/monad-testnet.json`. Deploy sebelumnya
(`monad-testnet.superseded-1.json`, `-2.json`, dan `-3.json`, yaitu v3 revisi 1) sudah digantikan; jangan dipakai. Alamat juga
tersedia di `GET /config` pada relayer.

| Kontrak | Alamat |
| --- | --- |
| `CityFactory` | [`0xDC9A322E95E7d9214fA794D39534a15B4aB3d9fF`](https://testnet.monadvision.com/address/0xDC9A322E95E7d9214fA794D39534a15B4aB3d9fF) |
| `CityGuardian` | [`0x74F881Ec300DfD1BfD26b4c0392f713fc775E7B9`](https://testnet.monadvision.com/address/0x74F881Ec300DfD1BfD26b4c0392f713fc775E7B9) |
| `AgentMarketplace` | [`0x241E3f8f02C53e075794989b9E7BD9832e539D29`](https://testnet.monadvision.com/address/0x241E3f8f02C53e075794989b9E7BD9832e539D29) |
| `ApyFeed` | [`0x3328AEbB57Ee0bc8d2C7f68468dEe6B9b50926b5`](https://testnet.monadvision.com/address/0x3328AEbB57Ee0bc8d2C7f68468dEe6B9b50926b5) |
| `YieldReserve` | [`0x40e194d12BC3F6a6b26E8B7808f749c88281Ef96`](https://testnet.monadvision.com/address/0x40e194d12BC3F6a6b26E8B7808f749c88281Ef96) |
| `MirrorYieldAdapter` (implementasi) | [`0x156fDb80Bd936f1CF1d45A1a167B660A82043080`](https://testnet.monadvision.com/address/0x156fDb80Bd936f1CF1d45A1a167B660A82043080) |
| AUSD testnet (bukan milik kami) | `0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC` |
| ERC-8004 Identity / Reputation Registry (bukan milik kami) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` / `0x8004B663056A597Dffe9eCcC1965A193B7388713` |

`YieldReserve` berisi AUSD testnet dari faucet publik. Yield yang dibayarkan adalah **simulasi** yang mengikuti
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

Ditemukan oleh tinjauan independen. Dua yang paling penting ditangani di v3, dengan syarat yang dinyatakan jujur:

- **Satu adapter rusak mengunci kota** (F-02): **ditangani di v3** lewat karantina (lihat tabel). Syaratnya: selama karantina
  adapter itu dihitung nol, setoran berhenti, `setFee` ditolak, dan yang menarik dibayar harga likuid yang sama (urutan keluar
  tidak berpengaruh) tetapi melepas bagiannya atas posisi yang terkunci, yang tetap untuk yang bertahan. Desain pertama (nilai
  beku) diganti setelah tinjauan independen menemukan penghitungan ganda. Tidak ada penghapusan adapter; menulisnya sebagai
  rugi butuh keputusan tata kelola.
- **Batas pergeseran per panggilan, bukan kumulatif** (F-05): **ditangani di v3 untuk kunci sesi** dengan anggaran kumulatif per jam
  (bawaan 20% dari total aset). Walikota sendiri tetap dibatasi hanya per panggilan (`maxShiftBps`). Dana tetap hanya bergerak
  antara idle dan adapter kota itu.
- Marketplace: tidak menjamin kualitas agen; pembayaran sewa tidak dikembalikan bila walikota memecat agen lebih awal; tidak ada
  bagi hasil fee; pemilik platform dapat menjeda listing dan sewa baru dan memilih aset pembayaran.
- `maxWithdraw`/`maxRedeem` tidak memperhitungkan likuiditas adapter (kecuali dalam karantina); `setFee` berlaku seketika sampai batas
  factory; APY terakhir di `ApyFeed` terus berlaku bila keeper berhenti.

Belum diaudit oleh manusia. Tinjauan independen oleh agen terpisah untuk v3 (temuan dan perbaikannya): lihat vault, TC61.

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
