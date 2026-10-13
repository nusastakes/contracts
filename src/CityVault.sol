// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAdapter} from "./interfaces/IAdapter.sol";
import {ICityFactory} from "./interfaces/ICityFactory.sol";

/// @title CityVault
/// @notice One city = one ERC-4626 vault. Residents deposit the asset, the mayor spreads it over platform-approved
/// adapters, and earns a fee only on profit above a per-city high-water mark. There is no function that sends assets
/// anywhere except to an adapter owned by this city, or to a share holder who is withdrawing.
contract CityVault is ERC4626, ERC20Permit, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint16 internal constant BPS = 10_000;
    uint8 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant OFFSET_UNIT = 10 ** DECIMALS_OFFSET;
    /// @dev Share price is kept as assets-per-share scaled so that the starting price is exactly PRICE_SCALE.
    uint256 internal constant PRICE_SCALE = 1e18;
    uint256 public constant MAX_ADAPTERS = 8;

    address public immutable mayor;
    address public immutable factory;
    address public immutable guardian;
    /// @dev Share of the mayor's fee that goes to the platform treasury. Fixed when the city is created.
    uint16 public immutable platformCutBps;

    /// @dev City metadata kept onchain so the UI can read it without scanning logs (public RPCs limit `eth_getLogs`).
    string public community;
    string public mapURI;
    uint64 public immutable createdAt;

    uint16 public feeBps;
    uint16 public maxShiftBps = 5000;
    uint256 public highWaterMark;

    address public sessionKey;
    uint64 public sessionKeyExpiry;
    uint16 public sessionKeyMaxShiftBps;

    mapping(address => bool) public isAdapter;
    address[] private _adapters;
    bool private _adaptersSet;

    /// @dev F-02: an adapter whose `totalAssets()` reverts can be put in quarantine by anyone, and only while it really
    /// fails (`quarantine` probes it). A quarantined adapter counts as ZERO in `totalAssets()`, so the books can never
    /// show money that is not there, deposits stop, the fee rate cannot be raised, and everybody who withdraws is paid
    /// the same liquid price (liquid assets per share) no matter who leaves first. The price of that simplicity is
    /// that a holder who withdraws during a quarantine gives up their share of the quarantined position; it stays with
    /// those who remain and is theirs again if the adapter is restored. One broken adapter no longer locks the city.
    mapping(address => bool) public quarantined;
    uint256 public quarantinedCount;
    /// @dev Gas given to the probe, the same for `quarantine` and `restoreAdapter` so a borderline adapter cannot be flipped
    /// in and out of quarantine by calling one cap against the other. It is generous (no sane adapter reads its position for
    /// that much) and it bounds what a gas-burning adapter can cost whoever probes it; Monad charges the gas limit, so a
    /// quarantine or restore transaction should carry a bit over this.
    uint256 internal constant PROBE_GAS = 3_000_000;

    /// @dev B1.10 (finding F-05): the session key's cumulative budget per rolling window, in basis points of total
    /// assets. The mayor's own calls are not limited by it.
    uint64 public constant SESSION_WINDOW = 1 hours;
    uint16 public sessionBudgetBps = 2000;
    uint64 public sessionWindowStart;
    uint256 public sessionWindowShifted;

    /// @notice City theme and civic-works code chosen by the mayor, for example "klasik.taman" packed as ASCII bytes.
    /// The web app renders it; nothing else reads it.
    bytes32 public style;

    event Rebalanced(
        address indexed caller, address indexed from, address indexed to, uint256 amount, bytes32 planHash
    );
    event Evacuated(address indexed adapter, uint256 amount);
    event SessionKeySet(address indexed sessionKey, uint64 expiry, uint16 maxShiftBps);
    event FeeAccrued(uint256 feeShares, uint256 platformShares, uint256 mayorShares, uint256 newHighWaterMark);
    event FeeSet(uint16 oldFeeBps, uint16 newFeeBps);
    event MaxShiftSet(uint16 maxShiftBps);
    event PlanKeyRevealed(bytes32 indexed entryId, bytes32 key);
    event AdapterQuarantined(address indexed adapter);
    event AdapterRestored(address indexed adapter, uint256 assets);
    event SessionBudgetSet(uint16 budgetBps);
    event StyleSet(bytes32 style);

    error NotMayor();
    error NotGuardian();
    error NotFactory();
    error NotAuthorizedToRebalance();
    error AdaptersAlreadySet();
    error TooManyAdapters();
    error InvalidAdapter(address adapter);
    error UnknownAdapter(address adapter);
    error SameAdapter();
    error ZeroAmount();
    error InsufficientIdle(uint256 idle, uint256 amount);
    error InsufficientLiquidity(uint256 missing);
    error ShiftTooHigh(uint256 amount, uint256 maxAmount);
    error FeeTooHigh(uint16 feeBps, uint16 maxFeeBps);
    error BpsOutOfRange(uint16 bps);
    error ExpiryInPast(uint64 expiry);
    error PermitNotHonoured(address owner);
    error AdapterIsQuarantined(address adapter);
    error AlreadyQuarantined(address adapter);
    error AdapterNotBroken(address adapter);
    error NotQuarantined(address adapter);
    error AdapterStillBroken(address adapter);
    error SessionBudgetExceeded(uint256 used, uint256 cap);
    error QuarantineActive();
    error QuarantineExitsAreSelfOnly();

    modifier onlyMayor() {
        if (msg.sender != mayor) revert NotMayor();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /// @dev Everything the factory passes in when it founds a city.
    struct Init {
        IERC20 asset;
        string name;
        string community;
        string mapURI;
        address factory;
        address mayor;
        address guardian;
        uint16 feeBps;
        uint16 platformCutBps;
    }

    constructor(Init memory p) ERC20(p.name, "CITY") ERC4626(p.asset) ERC20Permit(p.name) {
        if (p.feeBps > ICityFactory(p.factory).maxFeeBps()) {
            revert FeeTooHigh(p.feeBps, ICityFactory(p.factory).maxFeeBps());
        }
        if (p.platformCutBps > BPS) revert BpsOutOfRange(p.platformCutBps);
        factory = p.factory;
        mayor = p.mayor;
        guardian = p.guardian;
        feeBps = p.feeBps;
        platformCutBps = p.platformCutBps;
        community = p.community;
        mapURI = p.mapURI;
        createdAt = uint64(block.timestamp);
        highWaterMark = PRICE_SCALE;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Registers this city's adapter clones. Callable once, by the factory that created the vault.
    function initAdapters(address[] calldata adapters_) external {
        if (msg.sender != factory) revert NotFactory();
        if (_adaptersSet) revert AdaptersAlreadySet();
        if (adapters_.length > MAX_ADAPTERS) revert TooManyAdapters();
        _adaptersSet = true;
        for (uint256 i; i < adapters_.length; ++i) {
            address a = adapters_[i];
            if (a == address(0) || isAdapter[a] || IAdapter(a).vault() != address(this)) revert InvalidAdapter(a);
            isAdapter[a] = true;
            _adapters.push(a);
        }
    }

    function adapters() external view returns (address[] memory) {
        return _adapters;
    }

    // ---------------------------------------------------------------------------------------------------------
    // ERC-4626
    // ---------------------------------------------------------------------------------------------------------

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /// @dev Both ERC4626 and ERC20Permit sit on ERC20; ERC4626's version (asset decimals + offset) is the one we want.
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @notice Idle assets plus every healthy adapter's position. A quarantined adapter counts as zero.
    /// @dev Strict on purpose for healthy adapters: if one reverts, pricing reverts too, because guessing its value would
    /// let someone trade against a wrong price. Anyone can call `quarantine` to end that state.
    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        uint256 n = _adapters.length;
        for (uint256 i; i < n; ++i) {
            address a = _adapters[i];
            if (!quarantined[a]) total += IAdapter(a).totalAssets();
        }
    }

    /// @notice Puts an adapter whose `totalAssets()` fails into quarantine. Anyone may call it, and it only works while the
    /// adapter really fails (reverts, runs out of its probe gas, or returns something that is not one word).
    function quarantine(address adapter) external nonReentrant {
        if (!isAdapter[adapter]) revert UnknownAdapter(adapter);
        if (quarantined[adapter]) revert AlreadyQuarantined(adapter);
        (bool ok,) = _probe(adapter);
        if (ok) revert AdapterNotBroken(adapter);
        quarantined[adapter] = true;
        ++quarantinedCount;
        emit AdapterQuarantined(adapter);
    }

    /// @notice Ends the quarantine of an adapter that works again. Anyone may call it, and it only works if the probe
    /// succeeds. The adapter is valued at what it reports now.
    function restoreAdapter(address adapter) external nonReentrant {
        if (!quarantined[adapter]) revert NotQuarantined(adapter);
        (bool ok, uint256 value) = _probe(adapter);
        if (!ok) revert AdapterStillBroken(adapter);
        quarantined[adapter] = false;
        --quarantinedCount;
        emit AdapterRestored(adapter, value);
    }

    function _probe(address adapter) internal view returns (bool ok, uint256 value) {
        bytes memory ret;
        (ok, ret) = adapter.staticcall{gas: PROBE_GAS}(abi.encodeCall(IAdapter.totalAssets, ()));
        if (ok && ret.length == 32) value = abi.decode(ret, (uint256));
        else ok = false;
    }

    /// @dev Deposits are limited so that total assets never pass the platform-wide cap.
    function maxDeposit(address) public view override returns (uint256) {
        if (quarantinedCount > 0) return 0; // no new money while a position cannot be priced
        uint256 cap = ICityFactory(factory).depositCap();
        uint256 total = totalAssets();
        return cap > total ? cap - total : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _requireSelfExitDuringQuarantine(owner);
        _accrueFee();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _requireSelfExitDuringQuarantine(owner);
        _accrueFee();
        return super.redeem(shares, receiver, owner);
    }

    /// @dev While an adapter is in quarantine the exit price is the liquid price, which is lower than the price a holder saw
    /// when they signed a permit or granted an allowance. Nobody else may trigger their exit then: only the holder, in a
    /// transaction they chose after seeing the quarantine.
    function _requireSelfExitDuringQuarantine(address owner) internal view {
        if (quarantinedCount > 0 && msg.sender != owner) revert QuarantineExitsAreSelfOnly();
    }

    /// @dev Pulls liquidity from adapters (in order) when idle assets do not cover a withdrawal.
    function _transferOut(address to, uint256 assets) internal override {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) _pullFromAdapters(assets - idle);
        super._transferOut(to, assets);
    }

    /// @dev A healthy adapter whose withdrawal fails (for example a paused protocol) is skipped, so one illiquid adapter
    /// cannot block a withdrawal that idle cash and the other adapters can pay; it reverts only if the total falls short.
    function _pullFromAdapters(uint256 needed) internal {
        IERC20 token = IERC20(asset());
        uint256 n = _adapters.length;
        for (uint256 i; i < n && needed > 0; ++i) {
            if (quarantined[_adapters[i]]) continue;
            IAdapter adapter = IAdapter(_adapters[i]);
            uint256 available = adapter.totalAssets();
            if (available == 0) continue;
            uint256 before = token.balanceOf(address(this));
            if (available <= needed) {
                try adapter.withdrawAll() returns (uint256) {} catch {}
            } else {
                try adapter.withdraw(needed) returns (uint256) {} catch {}
            }
            uint256 got = token.balanceOf(address(this)) - before;
            needed = got >= needed ? 0 : needed - got;
        }
        if (needed > 0) revert InsufficientLiquidity(needed);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Gasless deposit
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Deposits `assets` from `owner` using an EIP-2612 permit that `owner` signed. Anyone (the relayer) may
    /// send it and pays the gas; shares are always minted to `owner`, never to the sender.
    /// @dev The permit call is wrapped in try/catch so that a permit someone else already submitted does not make
    /// this transaction revert. When the permit fails, the call is only honoured if the sender is `owner`, or if the
    /// allowance is exactly `assets`, which is what a front-run copy of the same permit leaves behind. A standing
    /// (for example unlimited) allowance therefore cannot be used by a third party to force a deposit.
    function depositWithPermit(address owner, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        returns (uint256 shares)
    {
        try IERC20Permit(asset()).permit(owner, address(this), assets, deadline, v, r, s) {}
        catch {
            if (msg.sender != owner && IERC20(asset()).allowance(owner, address(this)) != assets) {
                revert PermitNotHonoured(owner);
            }
        }
        _accrueFee();
        uint256 maxAssets = maxDeposit(owner);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(owner, assets, maxAssets);
        shares = previewDeposit(assets);
        _deposit(owner, owner, assets, shares);
    }

    /// @notice Redeems `shares` that `owner` holds and pays the assets to `owner`, authorised by an EIP-2612 permit
    /// over the share token that `owner` signed with this vault as spender. Anyone (the relayer) may send it and pays
    /// the gas, so a resident can withdraw without holding MON. The assets can only go to `owner`.
    /// @dev Same rules as `depositWithPermit`: if the permit fails, the call is only honoured when the sender is
    /// `owner`, or the allowance equals `shares` (a front-run copy of the same permit). The allowance the permit set
    /// is cleared afterwards.
    function redeemWithPermit(address owner, uint256 shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _requireSelfExitDuringQuarantine(owner);
        try this.permit(owner, address(this), shares, deadline, v, r, s) {}
        catch {
            if (msg.sender != owner && allowance(owner, address(this)) != shares) revert PermitNotHonoured(owner);
        }
        _accrueFee();
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        assets = previewRedeem(shares);
        _withdraw(owner, owner, owner, assets, shares);
        _approve(owner, address(this), 0, false);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Performance fee with high-water mark
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Anyone may crystallise the pending fee.
    function harvestFee() external nonReentrant {
        _accrueFee();
    }

    /// @dev Price of one share unit, scaled so a fresh vault starts at PRICE_SCALE. Uses the same virtual
    /// assets/shares as the ERC-4626 conversions so deposits and withdrawals never move it.
    function _pricePerShare(uint256 total, uint256 supply) internal pure returns (uint256) {
        return (total + 1).mulDiv(PRICE_SCALE * OFFSET_UNIT, supply + OFFSET_UNIT);
    }

    /// @notice Share price after the pending performance fee has been taken out.
    function pricePerShare() external view returns (uint256) {
        (uint256 total, uint256 supply) = _totalsAfterFee();
        return _pricePerShare(total, supply);
    }

    /// @notice Fee shares that `harvestFee` (or the next deposit/withdrawal) would mint right now.
    function pendingFeeShares() external view returns (uint256) {
        return _pendingFeeShares(totalAssets(), totalSupply());
    }

    /// @dev Fee shares owed for the profit above the high-water mark. Fee shares dilute holders so that they keep
    /// exactly `total - feeAssets`.
    function _pendingFeeShares(uint256 total, uint256 supply) internal view returns (uint256) {
        if (supply == 0 || feeBps == 0) return 0;
        uint256 virtualSupply = supply + OFFSET_UNIT;
        uint256 virtualAssets = total + 1;
        uint256 price = _pricePerShare(total, supply);
        if (price <= highWaterMark) return 0;

        uint256 profit = (price - highWaterMark).mulDiv(virtualSupply, PRICE_SCALE * OFFSET_UNIT);
        uint256 feeAssets = profit.mulDiv(feeBps, BPS);
        if (feeAssets == 0) return 0;
        return feeAssets.mulDiv(virtualSupply, virtualAssets - feeAssets);
    }

    /// @dev Total assets and total shares as they will be once the pending fee is minted. ERC-4626 previews use
    /// these so that `previewRedeem` and friends never promise more than the next real withdrawal pays.
    function _totalsAfterFee() internal view returns (uint256 total, uint256 supply) {
        total = totalAssets();
        supply = totalSupply();
        supply += _pendingFeeShares(total, supply);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 total, uint256 supply) = _totalsAfterFee();
        return assets.mulDiv(supply + OFFSET_UNIT, total + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 total, uint256 supply) = _totalsAfterFee();
        return shares.mulDiv(total + 1, supply + OFFSET_UNIT, rounding);
    }

    /// @dev Mints fee shares to the platform treasury and the mayor if the share price is above the high-water mark.
    /// Returns total assets, so callers do not have to walk the adapters twice.
    function _accrueFee() internal returns (uint256 total) {
        total = totalAssets();
        uint256 supply = totalSupply();
        uint256 price = _pricePerShare(total, supply);
        if (supply == 0) {
            highWaterMark = price;
            return total;
        }
        if (price <= highWaterMark) return total;
        if (feeBps == 0) {
            highWaterMark = price;
            return total;
        }

        uint256 feeShares = _pendingFeeShares(total, supply);
        if (feeShares == 0) return total;

        uint256 platformShares = feeShares.mulDiv(platformCutBps, BPS);
        uint256 mayorShares = feeShares - platformShares;
        if (platformShares > 0) _mint(ICityFactory(factory).platformTreasury(), platformShares);
        if (mayorShares > 0) _mint(mayor, mayorShares);

        highWaterMark = _pricePerShare(total, supply + feeShares);
        emit FeeAccrued(feeShares, platformShares, mayorShares, highWaterMark);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Allocation
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Moves assets between idle (`address(0)`) and this city's adapters.
    /// @dev Callable by the mayor, or by the session key while it has not expired. A single call may move at most
    /// `maxShiftBps` of total assets (the lower of that and the session key's own limit for the session key).
    function rebalance(address from, address to, uint256 amount, bytes32 planHash) external nonReentrant {
        uint256 limit;
        bool bySessionKey;
        if (msg.sender == mayor) {
            limit = maxShiftBps;
        } else if (_isActiveSessionKey(msg.sender)) {
            limit = Math.min(maxShiftBps, sessionKeyMaxShiftBps);
            bySessionKey = true;
        } else {
            revert NotAuthorizedToRebalance();
        }
        _rebalance(msg.sender, from, to, amount, planHash, limit, bySessionKey);
    }

    /// @notice Runs a mayor-approved proposal from the guardian. Same limit as the mayor's own rebalance.
    function executeProposal(address from, address to, uint256 amount, bytes32 planHash)
        external
        nonReentrant
        onlyGuardian
    {
        _rebalance(msg.sender, from, to, amount, planHash, maxShiftBps, false);
    }

    /// @notice Pulls everything out of one adapter back to idle. Only moves toward the safer side, so the guardian
    /// may do it without the mayor.
    function evacuate(address adapter) external nonReentrant onlyGuardian {
        if (!isAdapter[adapter]) revert UnknownAdapter(adapter);
        _accrueFee();
        uint256 withdrawn = IAdapter(adapter).withdrawAll();
        emit Evacuated(adapter, withdrawn);
    }

    function _isActiveSessionKey(address account) internal view returns (bool) {
        return account != address(0) && account == sessionKey && block.timestamp < sessionKeyExpiry;
    }

    /// @dev Spends `amount` of the session key's rolling budget; the window restarts an hour after it opened.
    function _spendSessionBudget(uint256 amount, uint256 total) internal {
        if (block.timestamp >= uint256(sessionWindowStart) + SESSION_WINDOW) {
            sessionWindowStart = uint64(block.timestamp);
            sessionWindowShifted = 0;
        }
        uint256 cap = total.mulDiv(sessionBudgetBps, BPS);
        uint256 used = sessionWindowShifted + amount;
        if (used > cap) revert SessionBudgetExceeded(used, cap);
        sessionWindowShifted = used;
    }

    function _rebalance(
        address caller,
        address from,
        address to,
        uint256 amount,
        bytes32 planHash,
        uint256 limit,
        bool bySessionKey
    ) internal {
        if (amount == 0) revert ZeroAmount();
        if (from == to) revert SameAdapter();
        if (from != address(0) && !isAdapter[from]) revert UnknownAdapter(from);
        if (to != address(0) && !isAdapter[to]) revert UnknownAdapter(to);
        if (to != address(0) && quarantined[to]) revert AdapterIsQuarantined(to);

        uint256 total = _accrueFee();
        uint256 maxAmount = total.mulDiv(limit, BPS);
        if (amount > maxAmount) revert ShiftTooHigh(amount, maxAmount);
        if (bySessionKey) _spendSessionBudget(amount, total);

        IERC20 token = IERC20(asset());
        uint256 moved = amount;
        if (from == address(0)) {
            uint256 idle = token.balanceOf(address(this));
            if (idle < amount) revert InsufficientIdle(idle, amount);
        } else {
            uint256 before = token.balanceOf(address(this));
            IAdapter(from).withdraw(amount);
            moved = token.balanceOf(address(this)) - before;
        }

        if (to != address(0) && moved > 0) {
            token.forceApprove(to, moved);
            IAdapter(to).deposit(moved);
            token.forceApprove(to, 0);
        }

        emit Rebalanced(caller, from, to, moved, planHash);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Mayor settings
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Registers one session key (a second key of the mayor for day-to-day work, kept in the web session
    /// instead of the main key) that may only call `rebalance`, within its own limit, until `expiry`. Pass
    /// `address(0)` to remove it.
    function setSessionKey(address newSessionKey, uint64 expiry, uint16 shiftBps) external onlyMayor {
        if (shiftBps > BPS) revert BpsOutOfRange(shiftBps);
        sessionWindowStart = 0;
        sessionWindowShifted = 0;
        if (newSessionKey == address(0)) {
            sessionKey = address(0);
            sessionKeyExpiry = 0;
            sessionKeyMaxShiftBps = 0;
            emit SessionKeySet(address(0), 0, 0);
            return;
        }
        if (expiry <= block.timestamp) revert ExpiryInPast(expiry);
        sessionKey = newSessionKey;
        sessionKeyExpiry = expiry;
        sessionKeyMaxShiftBps = shiftBps;
        emit SessionKeySet(newSessionKey, expiry, shiftBps);
    }

    /// @notice Changes the fee. Pending fee is crystallised at the old rate first, and the new rate is capped by
    /// the factory.
    function setFee(uint16 newFeeBps) external nonReentrant onlyMayor {
        // A raise could be applied to profit that is hidden in a quarantined adapter and was earned at the old rate.
        if (quarantinedCount > 0) revert QuarantineActive();
        uint16 maxFee = ICityFactory(factory).maxFeeBps();
        if (newFeeBps > maxFee) revert FeeTooHigh(newFeeBps, maxFee);
        _accrueFee();
        emit FeeSet(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setMaxShift(uint16 newMaxShiftBps) external onlyMayor {
        if (newMaxShiftBps > BPS) revert BpsOutOfRange(newMaxShiftBps);
        maxShiftBps = newMaxShiftBps;
        emit MaxShiftSet(newMaxShiftBps);
    }

    /// @notice Sets the session key's cumulative budget per hour, as basis points of total assets (default 20%).
    function setSessionBudget(uint16 budgetBps) external onlyMayor {
        if (budgetBps > BPS) revert BpsOutOfRange(budgetBps);
        sessionBudgetBps = budgetBps;
        emit SessionBudgetSet(budgetBps);
    }

    /// @notice Sets the city's theme and civic-works code (ASCII packed into 32 bytes). Display only.
    function setStyle(bytes32 newStyle) external onlyMayor {
        style = newStyle;
        emit StyleSet(newStyle);
    }

    /// @notice Publishes the key of one sealed strategy-book entry. Only emits; nothing else changes.
    function revealPlanKey(bytes32 entryId, bytes32 key) external onlyMayor {
        emit PlanKeyRevealed(entryId, key);
    }
}
