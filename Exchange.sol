// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

// REVERT LOG: 
// e00 : Incorrect input/output amount
// e01 : Collateral percentage out of range
// e02 : No unpaid interest
// e03 : Caller is not the borrower of given txId
// e04 : Refinance not applicable for given txId
// e05 : Interest has been paid within 90 days
// e06 : Input collateral amount exceeds accrued interest
// e07 : No amount to reinstate

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Exchange is Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _txId;

    uint public constant MIN_COLLAT = 120;
    uint public constant MAX_COLLAT = 200;
    uint public constant REFI_FEE = 10; 

    IERC20 public constant token0 = IERC20(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c); 
    IERC20 public constant token1 = IERC20(0x2170Ed0880ac9A755fd29B2688956BD959F933F8); 
    IERC20 public immutable distToken;

    AggregatorV3Interface private _priceFeed0;
    AggregatorV3Interface private _priceFeed1;

    struct Loan {
        uint amountLoaned;
        uint amountCollat;
        uint amountInterest;
        uint collateralPercentage;
        uint interestPaidTimestamp;
        address loanedTo;
        bool loanedForToken0; 
    }

    mapping(uint => Loan) private _loans;
    
    event TokensLoaned(address indexed recipient, uint id, uint256 amount, uint256 time);
    event InterestPaid(uint id, address payee, uint amount, uint time);

    constructor(
        address _distToken,
        address priceFeed0_,
        address priceFeed1_
    ) {
        _priceFeed0 = AggregatorV3Interface(priceFeed0_);
        _priceFeed1 = AggregatorV3Interface(priceFeed1_); 
        distToken = IERC20(_distToken);
    }

    function getRate0() public view returns (uint) {
        ( ,int price, , , ) = _priceFeed0.latestRoundData();
        return uint(price) / 1e8; 
    }

    function getRate1() public view returns (uint) {
        ( ,int price, , , ) = _priceFeed1.latestRoundData();
        return uint(price) / 1e8; 
    }
    
    function totalLended() external view returns (uint) {
        return _txId.current();

    }

    /// @notice Take loan against token0 
    /// @param amountIn amount of token0 to be provided as collateral
    /// @param amountOut amount of distToken to loan
    function takeLoan0(uint256 amountIn, uint256 amountOut) external {
        require(amountIn > 0 && amountOut > 0, "e00");

        uint collateral = (amountIn * getRate0() * 100) / amountOut;
        require(collateral >= MIN_COLLAT && collateral <= MAX_COLLAT, "e01");

        _txId.increment();
        uint256 cId = _txId.current();

        _loans[cId] = Loan(
            amountOut, 
            amountIn,
            0, 
            collateral, 
            block.timestamp, 
            msg.sender, 
            true
        );

        token0.transferFrom(msg.sender, address(this), amountIn);

        distToken.transfer(msg.sender, amountOut);

        emit TokensLoaned(msg.sender, cId, amountOut, block.timestamp);
    }

    /// @notice Take loan against token1
    /// @param amountIn amount of token1 to be provided as collateral
    /// @param amountOut amount of distToken to loan
    function takeLoan1(uint256 amountIn, uint256 amountOut) external {
        require(amountIn > 0 && amountOut > 0, "e00");

        uint collateral = (amountIn * getRate1() * 100) / amountOut;
        require(collateral >= MIN_COLLAT && collateral <= MAX_COLLAT, "e01");

        _txId.increment();
        uint256 cId = _txId.current();

        _loans[cId] = Loan(
            amountOut, 
            amountIn, 
            0,
            collateral, 
            block.timestamp, 
            msg.sender, 
            false
        );

        token1.transferFrom(msg.sender, address(this), amountIn);

        distToken.transfer(msg.sender, amountOut);

        emit TokensLoaned(msg.sender, cId, amountOut, block.timestamp);
    }

    function _getInterestPercentage(uint collateral) internal pure returns (uint256) {
        if(collateral >= 190 && collateral <= 200)
            return 1;
        else if(collateral >= 170 && collateral < 190)
            return 2;
        else if(collateral >= 150 && collateral < 170)
            return 3;
        else if(collateral >= 130 && collateral < 150)
            return 4;
        else if(collateral >= 120 && collateral < 130)
            return 5;
        else
            revert("e01");
    }

    /// @notice Pay accumulated interest for input txId
    /// @param txId transaction Id of the loan to pay interest for
    function payInterest(uint txId) external {
        uint totalInterest = getTotalInterest(txId);
        require(totalInterest > 0, "e02"); 

        _loans[txId].interestPaidTimestamp = block.timestamp;
        _loans[txId].amountInterest = 0;
        
        distToken.transferFrom(msg.sender, owner(), totalInterest);

        emit InterestPaid(txId, msg.sender, totalInterest, block.timestamp);
    }

    /// @notice Reimburse a portion of loaned amount
    /// @param txId transaction Id of the loan to reimburse
    /// @param amount amount of loan to reimburse 
    function reimburseLoan(uint txId, uint amount) external { 
        Loan storage loan = _loans[txId];

        require(msg.sender == loan.loanedTo, "e03");
        require(amount > 0 && amount <= loan.amountCollat, "e00");

        loan.amountInterest = getTotalInterest(txId);

        loan.interestPaidTimestamp = block.timestamp;
        loan.amountCollat -= amount;

        if(loan.amountCollat == 0) delete _loans[txId];
        
        distToken.transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Refinance for a specific txId
    /// @param txId transaction Id of loan to refinance 
    function refinance(uint txId) external {
        Loan storage loan = _loans[txId];
        require(msg.sender == loan.loanedTo, "e03");

        uint rate = loan.loanedForToken0 ? getRate0() : getRate1();
        uint fee = (loan.amountLoaned * REFI_FEE) / 100;
        uint claimable = ((rate * loan.amountCollat * 100) / loan.collateralPercentage) - loan.amountLoaned - fee;

        require(claimable > 0, "e04");

        loan.amountInterest = getTotalInterest(txId);
        loan.interestPaidTimestamp = block.timestamp;
        loan.amountLoaned += claimable;

        distToken.transfer(owner(), fee);
        distToken.transfer(msg.sender, claimable);
    }

    /// @notice Returns total accumulated interest for `txId`
    function getTotalInterest(uint txId) public view returns (uint256) {
        uint annualInterest = (_loans[txId].amountLoaned * _getInterestPercentage(_loans[txId].collateralPercentage)) / 100;
        uint currentInterest = (annualInterest * (block.timestamp - _loans[txId].interestPaidTimestamp)) / 365 days;
        return currentInterest + _loans[txId].amountInterest;
    }

    function getLoanInfo(uint txId) external view returns (Loan memory) {
        return _loans[txId]; 
    }
    
    /* | --- ONLY OWNER --- | */

    /// @notice Collect unpaid interest for `txId` using provided collateral
    /// @param txId transaction id to collect interest for
    /// @param collateralAmount amount of collateral to be used to pay for interest
    /// NOTE: Can only be called if interest has not been paid for `txId` in over 90 days
    function collectInterest(uint txId, uint collateralAmount) external onlyOwner {
        Loan storage loan = _loans[txId];
        require(block.timestamp - loan.interestPaidTimestamp >= 90 days, "e05");
        
        uint cInterest = getTotalInterest(txId);
        uint amountStable = collateralAmount * (loan.loanedForToken0 ? getRate0() : getRate1());
        require(cInterest >= amountStable, "e06");
        
        loan.interestPaidTimestamp = block.timestamp;
        loan.amountInterest = cInterest - amountStable;
        loan.amountCollat -= collateralAmount;

        if(loan.loanedForToken0) 
            token0.transfer(msg.sender, collateralAmount);
        else 
            token1.transfer(msg.sender, collateralAmount);
    }
    
    /// @notice Reinstate and remove a specific loan
    /// @param txId transaction id to reinstate
    function reinstate(uint txId) external onlyOwner {
        Loan memory loan = _loans[txId]; 
        if(loan.amountCollat == 0) revert("e07");

        delete _loans[txId];

        if(loan.loanedForToken0) 
            token0.transfer(loan.loanedTo, loan.amountCollat);
        else 
            token1.transfer(loan.loanedTo, loan.amountCollat);

    }

    function withdrawTokens(uint amount) external onlyOwner {
        distToken.transfer(msg.sender, amount);
    }

}
