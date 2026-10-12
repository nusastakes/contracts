// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CityVault} from "./CityVault.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {ICityFactory} from "./interfaces/ICityFactory.sol";

/// @title CityFactory
/// @notice Anyone can found a city; the platform only curates which adapter implementations may be used, and sets
/// the platform-wide limits. The platform never touches city funds.
contract CityFactory is Ownable, ICityFactory {
    using Clones for address;

    uint16 internal constant BPS = 10_000;
    /// @dev Hard ceilings so a compromised owner cannot set a confiscatory fee or platform cut.
    uint16 public constant MAX_FEE_CEILING_BPS = 5000;
    uint16 public constant MAX_PLATFORM_CUT_CEILING_BPS = 5000;

    address public immutable asset;
    address public guardian;
    address public platformTreasury;
    uint16 public platformCutBps = 1000;
    uint16 public maxFeeBps = 2000;
    uint256 public depositCap;

    mapping(address => bool) public allowedAdapterImpl;
    /// @dev Platform-chosen init params per implementation (for example the mirrored source or the target vault).
    /// Mayors choose an implementation, never its parameters.
    mapping(address => bytes) public adapterParams;
    mapping(address => bool) public isCity;
    mapping(address => bool) public isAdapterClone;
    address[] private _cities;

    event CityCreated(
        address indexed vault, address indexed mayor, string name, string community, uint16 feeBps, string mapURI
    );
    event AdapterDeployed(address indexed vault, address indexed adapter, address indexed implementation);
    event AdapterAllowed(address indexed implementation, bool allowed);
    event AdapterParamsSet(address indexed implementation, bytes params);
    event PlatformTreasurySet(address treasury);
    event PlatformCutSet(uint16 platformCutBps);
    event MaxFeeSet(uint16 maxFeeBps);
    event GuardianSet(address guardian);
    event DepositCapSet(uint256 depositCap);

    error ZeroAddress();
    error BpsTooHigh(uint16 bps, uint16 ceiling);
    error FeeTooHigh(uint16 feeBps, uint16 maxFeeBps);
    error AdapterNotAllowed(address implementation);
    error DuplicateAdapter(address implementation);
    error TooManyAdapters();
    error NoCode(address account);
    error EmptyName();

    constructor(address owner_, IERC20 asset_, address treasury_, address guardian_, uint256 depositCap_)
        Ownable(owner_)
    {
        if (address(asset_) == address(0) || treasury_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        asset = address(asset_);
        platformTreasury = treasury_;
        guardian = guardian_;
        depositCap = depositCap_;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Founding a city
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Deploys a vault with `msg.sender` as mayor, and one fresh clone of each chosen adapter implementation.
    function createCity(
        string calldata name,
        string calldata community,
        uint16 feeBps,
        address[] calldata adapterImpls,
        string calldata mapURI
    ) external returns (address vault) {
        if (bytes(name).length == 0) revert EmptyName();
        if (feeBps > maxFeeBps) revert FeeTooHigh(feeBps, maxFeeBps);
        uint256 n = adapterImpls.length;
        if (n > 8) revert TooManyAdapters();
        for (uint256 i; i < n; ++i) {
            address impl = adapterImpls[i];
            if (!allowedAdapterImpl[impl]) revert AdapterNotAllowed(impl);
            for (uint256 j; j < i; ++j) {
                if (adapterImpls[j] == impl) revert DuplicateAdapter(impl);
            }
        }

        CityVault city = new CityVault(
            CityVault.Init({
                asset: IERC20(asset),
                name: name,
                community: community,
                mapURI: mapURI,
                factory: address(this),
                mayor: msg.sender,
                guardian: guardian,
                feeBps: feeBps,
                platformCutBps: platformCutBps
            })
        );
        vault = address(city);

        address[] memory clones = new address[](n);
        for (uint256 i; i < n; ++i) {
            address impl = adapterImpls[i];
            address clone = impl.clone();
            isAdapterClone[clone] = true;
            IAdapter(clone).initialize(vault, asset, adapterParams[impl]);
            clones[i] = clone;
            emit AdapterDeployed(vault, clone, impl);
        }
        city.initAdapters(clones);

        isCity[vault] = true;
        _cities.push(vault);
        emit CityCreated(vault, msg.sender, name, community, feeBps, mapURI);
    }

    function cityCount() external view returns (uint256) {
        return _cities.length;
    }

    function cityAt(uint256 index) external view returns (address) {
        return _cities[index];
    }

    function cities() external view returns (address[] memory) {
        return _cities;
    }

    /// @dev One city's data for the UI, read in a single call.
    struct CityInfo {
        address vault;
        address mayor;
        string name;
        string community;
        string mapURI;
        uint16 feeBps;
        uint64 createdAt;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 pricePerShare;
        address[] adapters;
    }

    /// @notice Up to `count` cities starting at `start`, with everything the city list and leaderboard need.
    /// `pricePerShare` is net of the pending mayor fee and starts at 1e18, so `pricePerShare / 1e18 - 1` is the
    /// return since the city was founded.
    function cityInfos(uint256 start, uint256 count) external view returns (CityInfo[] memory infos) {
        uint256 total = _cities.length;
        if (start >= total) return infos;
        uint256 end = start + count > total ? total : start + count;
        infos = new CityInfo[](end - start);
        for (uint256 i = start; i < end; ++i) {
            CityVault v = CityVault(_cities[i]);
            infos[i - start] = CityInfo({
                vault: address(v),
                mayor: v.mayor(),
                name: v.name(),
                community: v.community(),
                mapURI: v.mapURI(),
                feeBps: v.feeBps(),
                createdAt: v.createdAt(),
                totalAssets: v.totalAssets(),
                totalSupply: v.totalSupply(),
                pricePerShare: v.pricePerShare(),
                adapters: v.adapters()
            });
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Platform settings
    // ---------------------------------------------------------------------------------------------------------

    function setAllowedAdapter(address impl, bool allowed) external onlyOwner {
        if (allowed && impl.code.length == 0) revert NoCode(impl);
        allowedAdapterImpl[impl] = allowed;
        emit AdapterAllowed(impl, allowed);
    }

    function setAdapterParams(address impl, bytes calldata params) external onlyOwner {
        adapterParams[impl] = params;
        emit AdapterParamsSet(impl, params);
    }

    function setPlatformTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert ZeroAddress();
        platformTreasury = treasury;
        emit PlatformTreasurySet(treasury);
    }

    /// @dev Applies to cities founded afterwards; existing cities keep the cut they were created with.
    function setPlatformCutBps(uint16 bps) external onlyOwner {
        if (bps > MAX_PLATFORM_CUT_CEILING_BPS) revert BpsTooHigh(bps, MAX_PLATFORM_CUT_CEILING_BPS);
        platformCutBps = bps;
        emit PlatformCutSet(bps);
    }

    function setMaxFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_CEILING_BPS) revert BpsTooHigh(bps, MAX_FEE_CEILING_BPS);
        maxFeeBps = bps;
        emit MaxFeeSet(bps);
    }

    /// @dev Applies to cities founded afterwards; each vault keeps the guardian it was created with.
    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapSet(cap);
    }
}
