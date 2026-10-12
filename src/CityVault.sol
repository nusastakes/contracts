// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
contract CityVault is ERC4626, ReentrancyGuard {
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

    uint16 public feeBps;
    uint16 public maxShiftBps = 5000;
    uint256 public highWaterMark;

    address public deputy;
    uint64 public deputyExpiry;
    uint16 public deputyMaxShiftBps;

    mapping(address => bool) public isAdapter;
    address[] private _adapters;
    bool private _adaptersSet;

    event Rebalanced(
        address indexed caller, address indexed from, address indexed to, uint256 amount, bytes32 planHash
    );
    event Evacuated(address indexed adapter, uint256 amount);
    event DeputySet(address indexed deputy, uint64 expiry, uint16 maxShiftBps);
    event FeeAccrued(uint256 feeShares, uint256 platformShares, uint256 mayorShares, uint256 newHighWaterMark);
    event FeeSet(uint16 oldFeeBps, uint16 newFeeBps);
    event MaxShiftSet(uint16 maxShiftBps);
    event PlanKeyRevealed(bytes32 indexed entryId, bytes32 key);

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

    modifier onlyMayor() {
        if (msg.sender != mayor) revert NotMayor();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(
        IERC20 asset_,
        string memory name_,
        address factory_,
        address mayor_,
        address guardian_,
        uint16 feeBps_,
        uint16 platformCutBps_
    ) ERC20(name_, "CITY") ERC4626(asset_) {
        if (feeBps_ > ICityFactory(factory_).maxFeeBps()) {
            revert FeeTooHigh(feeBps_, ICityFactory(factory_).maxFeeBps());
        }
        if (platformCutBps_ > BPS) revert BpsOutOfRange(platformCutBps_);
        factory = factory_;
        mayor = mayor_;
        guardian = guardian_;
        feeBps = feeBps_;
        platformCutBps = platformCutBps_;
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

    /// @notice Idle assets plus every adapter's position.
    /// @dev KNOWN LIMITATION (independent review F-02): this calls every adapter, and the adapter list cannot change
    /// after `initAdapters`. If one adapter's `totalAssets()` reverts (for example the protocol underneath is paused),
    /// every function that prices shares reverts too, so deposits, withdrawals, `rebalance` and `evacuate` of the
    /// healthy adapters are stuck until the adapter works again.
    /// TODO(F-02, placeholder, not implemented): a way to retire a broken adapter, for example a guardian-plus-mayor
    /// `removeAdapter(address)` that skips the broken adapter's `totalAssets()` and writes its position off. It needs
    /// a design decision first, because treating a failing adapter as worth 0 lets depositors buy shares cheaply.
    /// Mitigation today: adapters come only from the platform allow-list, and the mainnet proof is capped at 200 AUSD.
    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        uint256 n = _adapters.length;
        for (uint256 i; i < n; ++i) {
            total += IAdapter(_adapters[i]).totalAssets();
        }
    }

    /// @dev Deposits are limited so that total assets never pass the platform-wide cap.
    function maxDeposit(address) public view override returns (uint256) {
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
        _accrueFee();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.redeem(shares, receiver, owner);
    }

    /// @dev Pulls liquidity from adapters (in order) when idle assets do not cover a withdrawal.
    function _transferOut(address to, uint256 assets) internal override {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) _pullFromAdapters(assets - idle);
        super._transferOut(to, assets);
    }

    function _pullFromAdapters(uint256 needed) internal {
        IERC20 token = IERC20(asset());
        uint256 n = _adapters.length;
        for (uint256 i; i < n && needed > 0; ++i) {
            IAdapter adapter = IAdapter(_adapters[i]);
            uint256 available = adapter.totalAssets();
            if (available == 0) continue;
            uint256 before = token.balanceOf(address(this));
            if (available <= needed) adapter.withdrawAll();
            else adapter.withdraw(needed);
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
    /// @dev Callable by the mayor, or by the deputy while their key has not expired. A single call may move at most
    /// `maxShiftBps` of total assets (the lower of that and the deputy's own limit for the deputy).
    function rebalance(address from, address to, uint256 amount, bytes32 planHash) external nonReentrant {
        uint256 limit;
        if (msg.sender == mayor) {
            limit = maxShiftBps;
        } else if (_isActiveDeputy(msg.sender)) {
            limit = Math.min(maxShiftBps, deputyMaxShiftBps);
        } else {
            revert NotAuthorizedToRebalance();
        }
        _rebalance(msg.sender, from, to, amount, planHash, limit);
    }

    /// @notice Runs a mayor-approved proposal from the guardian. Same limit as the mayor's own rebalance.
    function executeProposal(address from, address to, uint256 amount, bytes32 planHash)
        external
        nonReentrant
        onlyGuardian
    {
        _rebalance(msg.sender, from, to, amount, planHash, maxShiftBps);
    }

    /// @notice Pulls everything out of one adapter back to idle. Only moves toward the safer side, so the guardian
    /// may do it without the mayor.
    function evacuate(address adapter) external nonReentrant onlyGuardian {
        if (!isAdapter[adapter]) revert UnknownAdapter(adapter);
        _accrueFee();
        uint256 withdrawn = IAdapter(adapter).withdrawAll();
        emit Evacuated(adapter, withdrawn);
    }

    function _isActiveDeputy(address account) internal view returns (bool) {
        return account != address(0) && account == deputy && block.timestamp < deputyExpiry;
    }

    function _rebalance(address caller, address from, address to, uint256 amount, bytes32 planHash, uint256 limit)
        internal
    {
        if (amount == 0) revert ZeroAmount();
        if (from == to) revert SameAdapter();
        if (from != address(0) && !isAdapter[from]) revert UnknownAdapter(from);
        if (to != address(0) && !isAdapter[to]) revert UnknownAdapter(to);

        uint256 total = _accrueFee();
        uint256 maxAmount = total.mulDiv(limit, BPS);
        if (amount > maxAmount) revert ShiftTooHigh(amount, maxAmount);

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

    /// @notice Registers one deputy key that may only call `rebalance`, within its own limit, until `expiry`.
    /// Pass `address(0)` to remove the deputy.
    function setDeputy(address newDeputy, uint64 expiry, uint16 shiftBps) external onlyMayor {
        if (shiftBps > BPS) revert BpsOutOfRange(shiftBps);
        if (newDeputy == address(0)) {
            deputy = address(0);
            deputyExpiry = 0;
            deputyMaxShiftBps = 0;
            emit DeputySet(address(0), 0, 0);
            return;
        }
        if (expiry <= block.timestamp) revert ExpiryInPast(expiry);
        deputy = newDeputy;
        deputyExpiry = expiry;
        deputyMaxShiftBps = shiftBps;
        emit DeputySet(newDeputy, expiry, shiftBps);
    }

    /// @notice Changes the fee. Pending fee is crystallised at the old rate first, and the new rate is capped by
    /// the factory.
    function setFee(uint16 newFeeBps) external nonReentrant onlyMayor {
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

    /// @notice Publishes the key of one sealed strategy-book entry. Only emits; nothing else changes.
    function revealPlanKey(bytes32 entryId, bytes32 key) external onlyMayor {
        emit PlanKeyRevealed(entryId, key);
    }
}
