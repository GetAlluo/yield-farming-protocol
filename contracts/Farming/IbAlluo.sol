// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "./AlluoERC20Upgradable.sol";
import "../interfaces/ILiquidityBufferVault.sol";
import "../mock/interestHelper/Interest.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

contract IbAlluo is 
    Initializable, 
    PausableUpgradeable, 
    AlluoERC20Upgradable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable ,
    Interest
{
    using AddressUpgradeable for address;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // variable which grow after any action from user
    // based on current interest rate and time from last update call
    uint256 public growingRatio;

    // time of last ratio update
    uint256 public lastInterestCompound;

    // time limit for using update
    uint256 public updateTimeLimit;

    // constant for ratio calculation
    uint256 private multiplier;

    // interest per second, big number for accurate calculations (10**27)
    uint256 public interestPerSecond;

    // current annual interest rate with 2 decimals
    uint256 public annualInterest;

    // admin and reserves address
    address public wallet;

    // contract that will distribute money between the pool and the wallet
    address public liquidityBuffer; 

    // flag for upgrades availability
    bool public upgradeStatus;

    // list of tokens from which deposit available
    EnumerableSetUpgradeable.AddressSet private supportedTokens;

    event BurnedForWithdraw(address indexed user, uint256 amount);
    event Deposited(address indexed user, address token, uint256 amount);
    event NewWalletSet(address oldWallet, address newWallet);
    event NewBufferSet(address oldBuffer, address newBuffer);
    event UpdateTimeLimitSet(uint256 oldValue, uint256 newValue);
    event DepositTokenStatusChanged(address token, bool status);

    event InterestChanged(
        uint256 oldYearInterest, 
        uint256 newYearInterest,
        uint256 oldInterestPerSecond, 
        uint256 newInterestPerSecond
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(
        string memory _name, 
        string memory _symbol, 
        address _multiSigWallet, 
        address _buffer,
        address[] memory _supportedTokens,
        uint256 _interestPerSecond,
        uint256 _annualInterest
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        require(_multiSigWallet.isContract(), "IbAlluo: Not contract");
        require(_buffer.isContract(), "IbAlluo: Not contract");

        _grantRole(DEFAULT_ADMIN_ROLE, _multiSigWallet);
        _grantRole(UPGRADER_ROLE, _multiSigWallet);

        for(uint256 i = 0; i < _supportedTokens.length; i++){
            supportedTokens.add(_supportedTokens[i]);
            emit DepositTokenStatusChanged(_supportedTokens[i], true);
        }

        interestPerSecond = _interestPerSecond*10**13;
        annualInterest = _annualInterest;
        multiplier = 10**18;
        growingRatio = 10**18;
        updateTimeLimit = 60;
        lastInterestCompound = block.timestamp;

        wallet = _multiSigWallet;
        liquidityBuffer = _buffer;

        emit NewWalletSet(address(0), wallet);
        emit NewBufferSet(address(0), liquidityBuffer);
    }


    /**
     * @dev See {IERC20-approve} but it approves amount of tokens
     *      which represents asset value 
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * NOTE: Because of constantly growing ratio between IbAlluo and asset value
     *       we recommend to approve amount slightly more
     */
    function approveAssetValue(address spender, uint256 amount) public whenNotPaused returns (bool) {
        address owner = _msgSender();
        updateRatio();
        uint256 adjustedAmount = amount * multiplier / growingRatio;
        _approve(owner, spender, adjustedAmount);
        return true;
    }

    /**
     * @dev See {IERC20-transfer} but it transfers amount of tokens
     *      which represents asset value 
     */
    function transferAssetValue(address to, uint256 amount) public whenNotPaused returns (bool) {
        address owner = _msgSender();
        updateRatio();
        uint256 adjustedAmount = amount * multiplier / growingRatio;
        _transfer(owner, to, adjustedAmount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom} but it transfers amount of tokens
     *      which represents asset value 
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     */
    function transferFromAssetValue(
        address from,
        address to,
        uint256 amount
    ) public whenNotPaused returns (bool) {
        address spender = _msgSender();
        updateRatio();
        uint256 adjustedAmount = amount * multiplier / growingRatio;
        _spendAllowance(from, spender, adjustedAmount);
        _transfer(from, to, adjustedAmount);
        return true;
    }


    /// @notice  Updates the growingRatio
    /// @dev If more than the updateTimeLimit has passed, call changeRatio from interestHelper to get correct index
    ///      Then update the index and set the lastInterestCompound date.

    function updateRatio() public whenNotPaused {
        if (block.timestamp >= lastInterestCompound + updateTimeLimit) {
            growingRatio = changeRatio(growingRatio, interestPerSecond, lastInterestCompound);
            lastInterestCompound = block.timestamp;
        }
    }

    /// @notice  Allows deposits and updates the index, then mints the new appropriate amount.
    /// @dev When called, asset token is sent to the wallet, then the index is updated
    ///      so that the adjusted amount is accurate.
    /// @param _token Deposit token address
    /// @param _amount Amount (with token desimals) 

    function deposit(address _token, uint256 _amount) external {
        require(supportedTokens.contains(_token), "IbAlluo: Token not supported");

        IERC20Upgradeable(_token).safeTransferFrom(msg.sender, address(liquidityBuffer), _amount);
        updateRatio();

        ILiquidityBufferVault(liquidityBuffer).deposit(_token, _amount);

        uint256 amountIn18 = _amount * 10**(18 - AlluoERC20Upgradable(_token).decimals());
        uint256 adjustedAmount = amountIn18 * multiplier / growingRatio;
        _mint(msg.sender, adjustedAmount);
        emit Deposited(msg.sender, _token, _amount);
    }

    /// @notice  Withdraws accuratel
    /// @dev When called, immediately check for new interest index. Then find the adjusted amount in IbAlluo tokens
    ///      Then burn appropriate amount of IbAlluo tokens to receive asset token
    /// @param _targetToken Asset token
    /// @param _amount Amount (parsed 10**18)

    function withdraw(address _targetToken, uint256 _amount ) external {
        require(supportedTokens.contains(_targetToken), "IbAlluo: Token not supported");
        updateRatio();
        uint256 adjustedAmount = _amount * multiplier / growingRatio;
        _burn(msg.sender, adjustedAmount);

        ILiquidityBufferVault(liquidityBuffer).withdraw(msg.sender, _targetToken, _amount);
        emit BurnedForWithdraw(msg.sender, adjustedAmount);
    }
   
    /// @notice  Returns balance in asset value
    /// @param _address address of user

    function getBalance(address _address) public view returns (uint256) {
        uint256 _growingRatio = changeRatio(growingRatio, interestPerSecond, lastInterestCompound);
        return balanceOf(_address) * _growingRatio / multiplier;
    }

    /// @notice  Returns balance in asset value with correct info from update
    /// @param _address address of user

    function getBalanceForTransfer(address _address) public view returns (uint256) {

        if (block.timestamp >= lastInterestCompound + updateTimeLimit) {
            uint256 _growingRatio = changeRatio(growingRatio, interestPerSecond, lastInterestCompound);
            return balanceOf(_address) * _growingRatio / multiplier;
        }
        else{
            return balanceOf(_address) * growingRatio / multiplier;
        }
    }

    /// @notice  Sets the new interest rate 
    /// @dev When called, it sets the new interest rate after updating the index.
    /// @param _newAnnualInterest New annual interest rate with 2 decimals 850 == 8.50%
    /// @param _newInterestPerSecond New interest rate = interest per second (100000000244041*10**13 == 8% APY)
  
    function setInterest(uint256 _newAnnualInterest, uint256 _newInterestPerSecond)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 oldAnnualValue = annualInterest;
        uint256 oldValuePerSecond = interestPerSecond;
        updateRatio();
        annualInterest = _newAnnualInterest;
        interestPerSecond = _newInterestPerSecond * 10**10;
        emit InterestChanged(oldAnnualValue, annualInterest, oldValuePerSecond, interestPerSecond);
    }
    
    /// @notice migrates by minting balances.

    function migrateStep1(address _oldContract, address[] memory _users) external onlyRole(DEFAULT_ADMIN_ROLE){
        for(uint i = 0; i < _users.length; i++){
            uint256 oldBalance = AlluoERC20Upgradable(_oldContract).balanceOf(_users[i]);
            _mint(_users[i], oldBalance);
        }
    }

    /// @notice migrates by setting new interest variables.

    function migrateStep2() external onlyRole(DEFAULT_ADMIN_ROLE){
        _unpause();
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        interestPerSecond = 100000000244041*10**13;
        multiplier = 10**18;
        growingRatio = 10**18;
        lastInterestCompound = block.timestamp;
        annualInterest = 800;
        updateTimeLimit = 60;
    }
    
    function changeTokenStatus(address _token, bool _status) external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if(_status){
            supportedTokens.add(_token);
        }
        else{
            supportedTokens.remove(_token);
        }
        emit DepositTokenStatusChanged(_token, _status);
    }

    function setUpdateTimeLimit(uint256 _newLimit)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 oldValue = updateTimeLimit;
        updateTimeLimit = _newLimit;

        emit UpdateTimeLimitSet(oldValue, _newLimit);
    }

    function setWallet(address newWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newWallet.isContract(), "IbAlluo: Not contract");

        address oldValue = wallet;
        wallet = newWallet;

        emit NewWalletSet(oldValue, newWallet);
    }

    function setLiquidityBuffer(address newBuffer)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newBuffer.isContract(), "IbAlluo: Not contract");

        address oldValue = liquidityBuffer;
        liquidityBuffer = newBuffer;
        emit NewBufferSet(oldValue, liquidityBuffer);

    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function grantRole(bytes32 role, address account)
        public
        override
        onlyRole(getRoleAdmin(role))
    {
        if(role == DEFAULT_ADMIN_ROLE){
            require(account.isContract(), "IbAlluo: Not contract");
        }
        _grantRole(role, account);
    }

    function changeUpgradeStatus(bool _status)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        upgradeStatus = _status;
    }

    function getListSupportedTokens() public view returns (address[] memory) {
        return supportedTokens.values();
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._beforeTokenTransfer(from, to, amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {
        require(upgradeStatus, "IbAlluo: Upgrade not allowed");
        upgradeStatus = false;
    }
}