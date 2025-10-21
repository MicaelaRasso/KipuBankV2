// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*Imports*/
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*Interfaces*/
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/*
@title KipuBank for ETHKipu's Ethereum Developer Pack
@author Micaela Rasso
@notice This contract is part of the third project of the Ethereum Developer Pack 
@custom:security This is an educative contract and should not be used in production
*/
contract KipuBankV2 is Ownable, ReentrancyGuard{

/*State variables*/
    ///@notice Mapping of user address to their balance per token.
    mapping (address token => mapping(address user => uint256 balance)) private s_balances;

    /// @notice Supported tokens mapping.
    mapping (address token => bool isSupported) public s_supportedTokens; //es necesario?

    ///@notice Total number of deposits made per token.
    mapping(address => uint256) public s_totalDepositsByToken;

    ///@notice Total number of withdrawals made per token.
    mapping(address => uint256) public s_totalWithdrawalsByToken;

    /// @notice Chainlink BTC/USD price feed.
    AggregatorV3Interface public s_btcFeed;

    /// @notice Chainlink ETH/USD price feed.
    AggregatorV3Interface public s_ethFeed;

    ///@notice Maximum Ether capacity that the bank can hold.
    uint256 public immutable i_bankCap;

    ///@notice Maximum allowed withdrawal amount per transaction.
    uint256 public immutable i_maxWithdrawal;

    /// @notice USDC ERC20 token instance.
    IERC20 public immutable i_usdc;

    /// @notice BTC ERC20 token instance.
    IERC20 public immutable i_btc;

/*Constants*/
    uint16 constant ORACLE_HEARTBEAT = 3600;   
    uint256 constant DECIMAL_FACTOR_ETH = 1 * 10 ** 18;
    uint256 constant DECIMAL_FACTOR_USDC = 1 * 10 ** 2;
    uint256 constant DECIMAL_FACTOR_BTC = 1 * 10 ** 8;

/*Events*/
    /*
    @notice Emitted when a withdrawal is successful.
    @param receiver The address receiving the withdrawn Ether.
    @param amount The amount of Ether withdrawn.
    */
    event KipuBank_SuccessfulWithdrawal (address receiver, uint256 amount);

    /*
    @notice Emitted when a deposit is successful.
    @param receiver The address making the deposit.
    @param amount The amount of Ether deposited.
    */
    event KipuBank_SuccessfulDeposit(address receiver, uint256 amount);

    event KipuBank_ChainlinkFeedUpdated(address feed);

/*Errors*/
    /*
    @notice Thrown when a withdrawal fails.
    @param error Encoded error message returned by the failed call.
    */
    error KipuBank_FailedWithdrawal (bytes error);

    /*
    @notice Thrown when a fallback call fails.
    @param error Encoded error message for the failed operation.
    */
    error KipuBank_FailedOperation(bytes error);

    /*
    @notice Thrown when a withdrawal is attempted without sufficient funds.
    @param error Encoded error message.
    */
    error KipuBank_InsufficientFounds(bytes error);

    /*
    @notice Thrown when a deposit exceeds the bank capacity.
    @param error Encoded error message.
    */
    error KipuBank_FailedDeposit(bytes error);

    error KipuBank_DeniedContract();

    error KipuBank_NotSupportedToken(address token);

    error KipuBank_OracleCompromised();

    error KipuBank_StalePrice();

/*Modifiers*/
    /*
    @dev Ensures that a withdrawal can only be made if it does not exceed the maximum allowed amount and the user has sufficient balance.
    @param amount The requested withdrawal amount.
    */
    modifier amountAvailable(uint256 amount, address token){
        if(i_maxWithdrawal < amount) revert KipuBank_FailedWithdrawal("Amount exceeds the maximum withdrawal");
        if(s_balances[token][msg.sender] < amount) revert KipuBank_InsufficientFounds("Not enough founds");
        _;
    }

    modifier _areFundsExceeded(uint256 amount, address token){
        uint256 founds = _consultFounds();
        uint256 newAmount = _convertToUSD(amount, token);
        if(founds + newAmount > i_bankCap)
            revert KipuBank_FailedDeposit("Total KipuBank's founds exceeded");
        _;
    }

    modifier _onlySupportedToken(address token){
        if(!s_supportedTokens[token])
            revert KipuBank_NotSupportedToken(token);
        _;
    }

    modifier _isTokenTransferAllowed(address _token, uint256 _amount) {
    if (_token != address(0)) {
        IERC20 token = IERC20(_token);
        if (token.allowance(msg.sender, address(this)) < _amount) {
            revert KipuBank_FailedOperation("ERC20: Insufficient allowance for transferFrom");
        }
    }
    _;
}

/*Functions*/
//constructor
    /*
    @notice Deploys the contract with bank limits.
    @param _bankCap The maximum capacity of the bank.
    @param _maxWithdrawal The maximum withdrawal amount allowed.
    */
    constructor(
        address initialOwner, 
        address _ethFeed, address _btcFeed, 
        address _btc, address _usdc, 
        uint256 _bankCap, uint256 _maxWithdrawal
        ) Ownable(initialOwner)
        {
        if (_bankCap < 10 || _maxWithdrawal < 1) revert KipuBank_DeniedContract();
        
        i_bankCap = _bankCap * 10**8;
        i_maxWithdrawal  = _maxWithdrawal* 10**8;

        s_supportedTokens[address(0)] = true;
        s_supportedTokens[_usdc] = true;
        i_usdc = IERC20(_usdc);
        s_supportedTokens[_btc] = true;
        i_btc = IERC20(_btc);

        s_btcFeed = AggregatorV3Interface(_btcFeed);
        s_ethFeed = AggregatorV3Interface(_ethFeed);
    }

//receive & fallback
    /*
    @notice Allows contract to receive Ether directly.
    @dev Automatically calls the internal deposit function.
    */
    receive() external payable{
        _depositEther(msg.sender, msg.value);
    }

    /*
    @notice Handles calls with unknown data.
    @dev Always reverts with a failed operation error.
    */
    fallback() external{
        revert KipuBank_FailedOperation("Operation does not exists or data was incorrect");
    }

//external
     /*
    @notice Returns the total Ether amount stored in the contract.
    @return amount The total Ether amount stored.
    */
    function consultKipuBankFounds() external view returns (uint256 amount_){
        return _consultFounds() / 10**8;
    }

    /*
    @notice Allows users to deposit Ether into the bank.
    @dev Emits {KipuBank_SuccessfulDeposit}.
    */
    function deposit() external payable nonReentrant{
        _depositEther(msg.sender, msg.value);
    }

    /*
    @notice Allows users to withdraw Ether from the bank.
    @dev Emits {KipuBank_SuccessfulWithdrawal} on success.
    @custom:error KipuBank_FailedWithdrawal Thrown when transfer fails.
    */
    function withdraw(uint256 amount) external nonReentrant amountAvailable(amount, address(0)){
        //Checks that the amount is Available
        //Effects
        s_balances[address(0)][msg.sender] -= amount;
        _actualizeOperations(false, address(0));
        (bool success, bytes memory error) = payable(msg.sender).call{value: amount}("");
        
        //Interactions
        if (!success) 
            revert KipuBank_FailedWithdrawal(error);
        emit KipuBank_SuccessfulWithdrawal(msg.sender, amount);
    }


    function depositUSDC(uint256 amount) external nonReentrant _onlySupportedToken(address(i_usdc)) _isTokenTransferAllowed(address(i_usdc), amount) _areFundsExceeded(amount, address(i_usdc)){
        //Checks that the token is supported by KipuBank
        //Effects
        i_usdc.transferFrom(msg.sender, address(this), amount);
        s_balances[address(i_usdc)][msg.sender] += amount;
        _actualizeOperations(true, address(i_usdc));
        //Interactions
        emit KipuBank_SuccessfulDeposit(msg.sender, amount);
    }
 
    function withdrawUSDC(uint256 amount) external nonReentrant _onlySupportedToken(address(i_usdc)) amountAvailable(amount, address(i_usdc)){
        //Checks that the balance has sufficient amount to withdraw
        //Effects
        s_balances[address(i_usdc)][msg.sender] -= amount;
        _actualizeOperations(false, address(i_usdc));
        //Interactions
        emit KipuBank_SuccessfulWithdrawal(msg.sender, amount);
        i_usdc.transfer(msg.sender, amount);
    }

    function depositBTC(uint256 amount) external nonReentrant  _onlySupportedToken(address(i_btc)) _isTokenTransferAllowed(address(i_btc), amount) _areFundsExceeded(amount, address(i_btc)){
        //Checks that the token is supported by KipuBank
        //Effects
        i_btc.transferFrom(msg.sender, address(this), amount);
        s_balances[address(i_btc)][msg.sender] += amount;
        _actualizeOperations(true, address(i_btc));
        //Interactions
        emit KipuBank_SuccessfulDeposit(msg.sender, amount);
    }
 
    function withdrawBTC(uint256 amount) external nonReentrant _onlySupportedToken(address(i_btc)) amountAvailable(amount, address(i_btc)){
        //Checks that the balance has sufficient amount to withdraw
        //Effects
        s_balances[address(i_btc)][msg.sender] -= amount;
        _actualizeOperations(false, address(i_btc));
        //Interactions
        emit KipuBank_SuccessfulWithdrawal(msg.sender, amount);
        i_btc.transfer(msg.sender, amount);
    }

    function setFeeds(address _btcFeed, address _ethFeed) external onlyOwner{
        s_btcFeed = AggregatorV3Interface(_btcFeed);
        emit KipuBank_ChainlinkFeedUpdated(_btcFeed);
        s_ethFeed = AggregatorV3Interface(_ethFeed);
        emit KipuBank_ChainlinkFeedUpdated(_ethFeed);
    }

    function emergencyWithdrawal(address token, uint256 amount, address recipient) external onlyOwner {
        if (token == address(0)) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) revert KipuBank_FailedWithdrawal("ETH transfer failed");
        } else {
            IERC20(token).transfer(recipient, amount);
        }
    }

//private
    /*
    @dev Handles the actual deposit logic.
    @param addr The address of the depositor.
    @param amount The amount of Ether to deposit.
    */
    function _depositEther(address addr, uint256 amount) private _areFundsExceeded(amount, address(0)){
        s_balances[address(0)][addr] += amount;
        _actualizeOperations(true, address(0));

        emit KipuBank_SuccessfulDeposit(addr, amount);
    }

    /*
    @dev Updates the actual Ether amount stored in the contract.
    @param isDeposit Boolean indicating if operation is deposit (true) or withdrawal (false).
    @param amount The amount to update.
    */
    function _actualizeOperations(bool isDeposit, address token) private{
        if(isDeposit){
            s_totalDepositsByToken[token] += 1;
        }else{
            s_totalWithdrawalsByToken[token] += 1;
        }
    }

//view & pure
 
    function _consultFounds() internal view returns (uint256 amount_){
        uint256 ethBalance = address(this).balance;
        uint256 usdcBalance = i_usdc.balanceOf(address(this));
        uint256 btcBalance = i_btc.balanceOf(address(this));

        uint256 ethToUSD = _convertEthToUSD(ethBalance);    
        uint256 usdcToUSD = _convertUsdcToUSD(usdcBalance);   
        uint256 btcToUSD =  _convertBtcToUSD(btcBalance);

        return ethToUSD + usdcToUSD + btcToUSD;
    }

    function _chainlinkFeedETH() internal view returns (uint256 ethUSDPrice_) {
        (, int256 ethUSDPrice,, uint256 updatedAt,) = s_ethFeed.latestRoundData();
        if (ethUSDPrice == 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBank_StalePrice();
        ethUSDPrice_ = uint256(ethUSDPrice);
    }

    function _convertEthToUSD(uint256 _ethAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_ethAmount * _chainlinkFeedETH()) / DECIMAL_FACTOR_ETH;
    }

    function _convertUsdcToUSD(uint256 _usdcAmount) internal pure returns (uint256 convertedAmount_) {
        convertedAmount_ = _usdcAmount * DECIMAL_FACTOR_USDC;
    }

    function _chainlinkFeedBTC() internal view returns (uint256 btcUSDPrice_) {
        (, int256 btcUSDPrice,, uint256 updatedAt,) = s_btcFeed.latestRoundData();
        if (btcUSDPrice == 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBank_StalePrice();
        btcUSDPrice_ = uint256(btcUSDPrice);
    }

    function _convertBtcToUSD(uint256 _btcAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_btcAmount * _chainlinkFeedBTC()) / DECIMAL_FACTOR_BTC;
    }

    function _convertToUSD(uint256 _amount, address _token) internal view returns (uint256 convertedAmount_) 
    {
        if (_token == address(0)) {
            convertedAmount_ = _convertEthToUSD(_amount);
        } else if (_token == address(i_usdc)) {
            convertedAmount_ = _convertUsdcToUSD(_amount);
        } else if (_token == address(i_btc)) {
            convertedAmount_ = _convertBtcToUSD(_amount);
        }else {
            revert KipuBank_NotSupportedToken(_token); 
    }
        return convertedAmount_;
    }
}