# Vendored Chainlink CRE receiver files

Copied, not rewritten. Both files are SPDX MIT.

| File | Upstream path | Upstream SHA-256 | Local SHA-256 |
| --- | --- | --- | --- |
| `IReceiver.sol` | `smartcontractkit/documentation`, `public/samples/CRE/IReceiver.sol` | `dae0906d7de2e634f14d3b6794194d5bae38803e76e8029710611c7348c5a5e0` | `fd785b66226209f10035359ef41948a80099fed8ef83ca39a8eb4a2d50238539` |
| `ReceiverTemplate.sol` | `smartcontractkit/documentation`, `public/samples/CRE/ReceiverTemplate.sol` | `cebb2e698a20ca6ba41e8bff1777a537df0715c923d9e263f2b5b3f8fe06677d` | `ec78ed092c1c5b59b25263d3f09fb82e7547e010c7ba0c51d256a884cef49362` |

Last upstream change of both: commit `9def17c8928f6b4daea50b7ff5e12094696f0860` (2026-01-19). Downloaded from `main` at
commit `5dbdbb0fcfe5401df47a13389b806120b78d7f73` (2026-10-09).

The only change from upstream is the `IERC165` import, which now points at OpenZeppelin
(`@openzeppelin/contracts/utils/introspection/IERC165.sol`) instead of a local copy, so that it does not clash with
OpenZeppelin's own `ERC165`. Research and checks: `Analysis/Town-Civilization/05-Rencana/TC47 - CRE konsumen kontrak untuk CityGuardian.md`.

Not audited, as far as we could find. `ReceiverTemplate.setForwarderAddress(address(0))` disables the sender check; the
platform owner key must be protected accordingly.
