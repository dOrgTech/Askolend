pragma solidity ^0.6.0;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./compound/Exponential.sol";
import "./compound/InterestRateModel.sol";
import "./interfaces/UniswapOracleFactoryI.sol";
import "./MoneyMarketInstance.sol";
////////////////////////////////////////////////////////////////////////////////////////////
/// @title AskoRiskToken
/// @author Christopher Dixon
////////////////////////////////////////////////////////////////////////////////////////////
/**
The AskoRiskToken contract is an ERC20 contract designed to be owned by a MoneyMarketInstance contract. This contract's
token represents a Risk lending pool in a MoneyMarketInstance contract.
This contract uses the OpenZeppelin contract Library to inherit functions from
  Ownable.sol && ERC20.sol
**/

contract AskoRiskToken is Ownable, ERC20, Exponential {

  uint internal initialExchangeRateMantissa;
  uint public reserveFactorMantissa;
  uint public accrualBlockNumber;
  uint public borrowIndex;
  uint public totalBorrows;
  uint public totalReserves;
  uint public constant borrowRateMaxMantissa = 0.0005e16;
  uint public constant reserveFactorMaxMantissa = 1e18;
  uint public liquidationIncentiveMantissa = .001e18; //.001

  bool public isALR;


  IERC20 public asset;
  InterestRateModel public interestRateModel;
  MoneyMarketInstance public MMI;
  MoneyMarketFactoryI public MMF;
  UniswapOracleFactoryI public UOF;

  mapping(address => BorrowSnapshot) internal accountBorrows;
  mapping(address => uint) nonCompliant;// tracks user to a market to a time


/**
@notice struct for borrow balance information
@member principal Total balance (with accrued interest), after applying the most recent balance-changing action
@member interestIndex Global borrowIndex as of the most recent balance-changing action
*/
  struct BorrowSnapshot {
      uint principal;
      uint interestIndex;
  }

/**
@notice onlyMMInstance is a modifier used to make a function only callable by theproperMoneyMarketInstance contract
**/
    modifier onlyMMInstance()  {
      require(msg.sender == address(MMI));
      _;
    }

    event InterestAccrued(uint accrualBlockNumber, uint borrowIndex, uint totalBorrows, uint totalReserves);
    event Minted(address lender, uint amountMinted);
    event Redeemed(address redeemer, uint amountART, uint assetAmountRedeemed);
    event Burn(address account, uint amount);
    event Borrowed(address borrower, uint amountBorrowed);
    event Repayed(address borrower, uint amountRepayed);
    event NonCompliantTimerStart(address borrower);
    event Accountliquidated(address borrower, address liquidator, uint amountRepayed, address ARTowed, address ARTcollateral);
    event NonCompliantTimerReset(address borrower);

/**
@notice the constructor function is fired during the contract deployment process. The constructor can only be fired once and
is used to set up the name, symbol, and decimal variables for the AskoRiskToken contract.
@param _interestRateModel is the address of the  interest rate model for a specific ART
@param _asset is the address of the underlying asset for a specific ART contract
@param _oracleFactory is teh address of the uniswap oracle factory contract
@param _tokenName is the name of the asset the MoneyMarketInstance that owns this contract represents
@param _tokenSymbol is the symbol of the asset the MoneyMarketInstance that owns this contract represents
@param _isALR signifies whether or not a specific AskoRiskToken instance is a high risk or low risk token.
@param _initialExchangeRate is the initial exchange rate mantissa for a specific ART
@dev these two perameters become hyphenated with "AHR" during this process( e.x: AHR-wBitcoin, AHR-wBTC)
**/
  constructor (
    address _interestRateModel,
    address _asset,
    address _oracleFactory,
    address _MoneyMarketControl,
    string memory _tokenName,
    string memory _tokenSymbol,
    bool _isALR,
    uint _initialExchangeRate
    )
    public
    ERC20(
      _tokenName,
      _tokenSymbol
    )
      {
        asset = IERC20(_asset);//instanciate the asset as a usable ERC20 contract instance
        MMI = MoneyMarketInstance(msg.sender);//instanciates this contracts MoneyMarketInstance contract
        interestRateModel = InterestRateModel(_interestRateModel);//instanciates the this contracts interest rate model as a contract
        UOF = UniswapOracleFactoryI(_oracleFactory);//instantiatesthe UniswapOracleFactory as a contract
        MMF = MoneyMarketFactoryI(_MoneyMarketControl);
        isALR = _isALR;// sets the isALR varaible to determine whether or not a specific contract is an ALR token
        initialExchangeRateMantissa = _initialExchangeRate;//sets the initialExchangeRateMantissa
        accrualBlockNumber = getBlockNumber();
        borrowIndex = mantissaOne;
      }

/**
@notice Get the underlying balance of the `owners`
@param owner The address of the account to query
@return The amount of underlying owned by `owner`
*/
    function balanceOfUnderlying(address owner) external  returns (uint) {
        Exp memory exchangeRate = Exp({mantissa: exchangeRateCurrent()});
        (MathError mErr, uint balance) = mulScalarTruncate(exchangeRate, balanceOf(owner));
        require(mErr == MathError.NO_ERROR);
        return balance;
    }

/**
@notice Get the underlying balance of the `owners`
@param owner The address of the account to query
@return The amount of underlying owned by `owner`
**/
    function balanceOfUnderlyingPrior(address owner) public view returns (uint) {
        Exp memory exchangeRate = Exp({mantissa: exchangeRatePrior()});
        (MathError mErr, uint balance) = mulScalarTruncate(exchangeRate, balanceOf(owner));
        require(mErr == MathError.NO_ERROR);
        return balance;
    }

/**
@notice getCashPrior is a view funcion that returns and ART's balance of its underlying asset
**/
    function getCashPrior() internal view returns (uint){
      return asset.balanceOf(address(this));
    }

/**
@notice Applies accrued interest to total borrows and reserves
@dev This calculates interest accrued from the last checkpointed block
    up to the current block and writes new checkpoint to storage.
*/
    function accrueInterest() public {
//Remember the initial block number
      uint currentBlockNumber = getBlockNumber();
      uint accrualBlockNumberPrior = accrualBlockNumber;

      //Read the previous values out of storage
      uint cashPrior = getCashPrior();
      uint borrowsPrior = totalBorrows;
      uint reservesPrior = totalReserves;
      uint borrowIndexPrior = borrowIndex;
//Short-circuit accumulating 0 interest
      if(accrualBlockNumberPrior != currentBlockNumber) {
//Calculate the current borrow interest rate
      uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
      require(borrowRateMantissa <= borrowRateMaxMantissa);

//Calculate the number of blocks elapsed since the last accrual
      (MathError mathErr, uint blockDelta) = subUInt(currentBlockNumber, accrualBlockNumberPrior);
//Calculate the interest accumulated into borrows and reserves and the new index:
      Exp memory simpleInterestFactor;
      uint interestAccumulated;
      uint totalBorrowsNew;
      uint totalReservesNew;
      uint borrowIndexNew;
//simpleInterestFactor = borrowRate * blockDelta
      (mathErr, simpleInterestFactor) = mulScalar(Exp({mantissa: borrowRateMantissa}), blockDelta);
//interestAccumulated = simpleInterestFactor * totalBorrows
      (mathErr, interestAccumulated) = mulScalarTruncate(simpleInterestFactor, borrowsPrior);
//totalBorrowsNew = interestAccumulated + totalBorrows
      (mathErr, totalBorrowsNew) = addUInt(interestAccumulated, borrowsPrior);
//totalReservesNew = interestAccumulated * reserveFactor + totalReserves
      (mathErr, totalReservesNew) = mulScalarTruncateAddUInt(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
//borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
      (mathErr, borrowIndexNew) = mulScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);
      //Write the previously calculated values into storage
      accrualBlockNumber = currentBlockNumber;
      borrowIndex = borrowIndexNew;
      totalBorrows = totalBorrowsNew;
      totalReserves = totalReservesNew;

emit InterestAccrued(accrualBlockNumber, borrowIndex, totalBorrows, totalReserves);
    }
  }

/**
@notice returns last calculated account's borrow balance using the prior borrowIndex
@param account The address whose balance should be calculated after updating borrowIndex
@return The calculated balance
**/
    function borrowBalancePrior(address account) public view returns (uint) {
      MathError mathErr;
      uint principalTimesIndex;
      uint result;

//Get borrowBalance and borrowIndex
      BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

//If borrowBalance = 0 then borrowIndex is likely also 0.
//Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
      if (borrowSnapshot.principal == 0) {
        return (0);
      }

//Calculate new borrow balance using the interest index:
//recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
      (mathErr, principalTimesIndex) = mulUInt(borrowSnapshot.principal, borrowIndex);
      if (mathErr != MathError.NO_ERROR) {
        return (0);
      }

      (mathErr, result) = divUInt(principalTimesIndex, borrowSnapshot.interestIndex);
      if (mathErr != MathError.NO_ERROR) {
        return (0);
      }

      return (result);
    }

/**
@notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
@param account The address whose balance should be calculated after updating borrowIndex
@return The calculated balance
**/
    function borrowBalanceCurrent(address account) public returns (uint) {
      accrueInterest();
      borrowBalancePrior(account);
    }

/**
@notice Get a snapshot of the account's balances, and the cached exchange rate
@dev This is used to perform liquidity checks.
@param account Address of the account to snapshot
@return (token balance, borrow balance, exchange rate mantissa)
**/
      function getAccountSnapshot(address account) external returns ( uint, uint, uint) {
          uint tokenBalance = balanceOf(account);
          uint borrowBalance = borrowBalanceCurrent(account);
          uint exchangeRateMantissa = exchangeRateCurrent();
        return ( tokenBalance, borrowBalance, exchangeRateMantissa);
      }

/**
@notice getBlockNumber allows for easy retrieval of block number
**/
      function getBlockNumber() internal view returns (uint) {
          return block.number;
      }

/**
@notice Returns the current per-block borrow interest rate for this ART
@return The borrow interest rate per block, scaled by 1e18
**/
      function borrowRatePerBlock() public view returns (uint) {
          return interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
      }

/**
@notice Returns the current per-block supply interest rate for this ART
@return The supply interest rate per block, scaled by 1e18
**/
      function supplyRatePerBlock() public view returns (uint) {
          return interestRateModel.getSupplyRate(getCashPrior(), totalBorrows, totalReserves, reserveFactorMantissa);
      }

/**
@notice getSupplyAPY roughly calculates the current APY for supplying using an average of 6500 blocks per day
**/
    function getSupplyAPY() public view returns (uint) {
      //multiply rate per block by blocks per year with an average of 6500 blocks a day per https://ycharts.com/indicators/ethereum_blocks_per_day
      return supplyRatePerBlock().mul(2372500);
    }
/**
@notice getSupplyAPY roughly calculates the current APY for borrowing using an average of 6500 blocks per day
**/
  function getBorrowAPY() public view returns (uint) {
    //multiply rate per block by blocks per year with an average of 6500 blocks a day per https://ycharts.com/indicators/ethereum_blocks_per_day
    return borrowRatePerBlock().mul(2372500);
  }

/**
@notice Returns the current total borrows plus accrued interest
@return The total borrows with interest
**/
      function totalBorrowsCurrent() external  returns (uint) {
          accrueInterest();
          return totalBorrows;
      }

/**
@notice return prior exchange rate for front end viewing
@return Calculated exchange rate scaled by 1e18
**/
    function exchangeRatePrior() public view returns (uint) {
      if (totalSupply() == 0) {
//If there are no tokens minted: exchangeRate = initialExchangeRate
        return initialExchangeRateMantissa;
      } else {
//Otherwise: exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
        uint totalCash = getCashPrior();//get contract asset balance
        uint cashPlusBorrowsMinusReserves;
        Exp memory exchangeRate;
        MathError mathErr;
//calculate total value held by contract plus owed to contract
        (mathErr, cashPlusBorrowsMinusReserves) = addThenSubUInt(totalCash, totalBorrows, totalReserves);
//calculate exchange rate
        (mathErr, exchangeRate) = getExp(cashPlusBorrowsMinusReserves, totalSupply());
        return (exchangeRate.mantissa);
      }
    }


/**
@notice Accrue interest then return the up-to-date exchange rate
@return Calculated exchange rate scaled by 1e18
**/
      function exchangeRateCurrent() public returns (uint) {
            accrueInterest();
            if (totalSupply() == 0) {
      //If there are no tokens minted: exchangeRate = initialExchangeRate
              return initialExchangeRateMantissa;
            } else {
      //Otherwise: exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
              uint totalCash = getCashPrior();//get contract asset balance
              uint cashPlusBorrowsMinusReserves;
              Exp memory exchangeRate;
              MathError mathErr;
      //calculate total value held by contract plus owed to contract
              (mathErr, cashPlusBorrowsMinusReserves) = addThenSubUInt(totalCash, totalBorrows, totalReserves);
      //calculate exchange rate
              (mathErr, exchangeRate) = getExp(cashPlusBorrowsMinusReserves, totalSupply());
              return (exchangeRate.mantissa);
            }
      }



/**
@notice Get cash balance of this cToken in the underlying asset in other contracts
@return The quantity of underlying asset owned by this contract
**/
      function getCash() external view returns (uint) {
          return getCashPrior();
      }

//struct used by mint to avoid stack too deep errors
      struct MintLocalVars {
          MathError mathErr;
          uint exchangeRateMantissa;
          uint mintTokens;
      }

/**
@notice mint is a modified function that only the owner of this contract(its MoneyMarketInstance) can call.
        This function allows an amount of AskoRiskToken token to be minted when called.
@param _account is the account the AHR is being minted to
@param _amount is the amount of AHR being minted
**/
  function mint(address _account, uint256 _amount) public onlyMMInstance {
//declare struct
    MintLocalVars memory vars;
//retrieve exchange rate
    vars.exchangeRateMantissa = exchangeRateCurrent();
//We get the current exchange rate and calculate the number of AHR to be minted:
//mintTokens = _amount / exchangeRate
    (vars.mathErr, vars.mintTokens) = divScalarByExpTruncate(_amount, Exp({mantissa: vars.exchangeRateMantissa}));
    _mint(_account, vars.mintTokens);
    emit Minted(_account, vars.mintTokens);
  }

  struct RedeemLocalVars {
      MathError mathErr;
      uint exchangeRateMantissa;
      uint redeemAmount;
  }

/**
@notice redeem allows a user to redeem their AskoRiskToken for the appropriate amount of underlying asset
@param _amount is the amount of ART being exchanged
**/
  function redeem(uint256 _amount) public {
    accrueInterest();
    require( _amount != 0 );

    RedeemLocalVars memory vars;

//get exchange rate
vars.exchangeRateMantissa = exchangeRateCurrent();

  _burn(msg.sender, _amount);
/**
We calculate the exchange rate and the amount of underlying to be redeemed:
redeemAmount = _amount x exchangeRateCurrent
*/
    (vars.mathErr, vars.redeemAmount) = mulScalarTruncate(Exp({mantissa: vars.exchangeRateMantissa}), _amount);
//Fail if protocol has insufficient cash
    require (getCashPrior() >= vars.redeemAmount);
//transfer the calculated amount of underlying asset to the msg.sender
    asset.transfer(msg.sender, vars.redeemAmount);
    emit Redeemed(msg.sender, _amount, vars.redeemAmount);
  }

/**
@notice burn is a modified function that only the owner of this contract(its MoneyMarketInstance) can call.
        This function allows an amount of AskoRiskToken token to be burned from an address when called.
@param _account is the account the AHR is being burned from
@param _amount is the amount of AHR being burned
**/
  function burn(address _account, uint256 _amount) public onlyMMInstance{
    _burn(_account, _amount);
    emit Burn( _account, _amount);

  }

//struct used by borrow function to avoid stack too deep errors
  struct BorrowLocalVars {
      MathError mathErr;
      uint accountBorrows;
      uint accountBorrowsNew;
      uint totalBorrowsNew;
  }

/**
@notice Sender borrows assets from the protocol to their own address
@param _borrowAmount The amount of the underlying asset to borrow
*/
  function borrow(uint _borrowAmount, address _borrower) external onlyMMInstance {
// _collateral the address of the ALR the user has staked as collateral?
      accrueInterest();
//Fail if protocol has insufficient underlying cash
      require(getCashPrior() > _borrowAmount);
//create local vars storage
      BorrowLocalVars memory vars;
//calculate the new borrower and total borrow balances, failing on overflow:
      vars.accountBorrows = borrowBalanceCurrent(_borrower);
//accountBorrowsNew = accountBorrows + borrowAmount
      (vars.mathErr, vars.accountBorrowsNew) = addUInt(vars.accountBorrows, _borrowAmount);
//totalBorrowsNew = totalBorrows + borrowAmount
      (vars.mathErr, vars.totalBorrowsNew) = addUInt(totalBorrows, _borrowAmount);
//We write the previously calculated values into storage
      accountBorrows[_borrower].principal = vars.accountBorrowsNew;
      accountBorrows[_borrower].interestIndex = borrowIndex;
      totalBorrows = vars.totalBorrowsNew;
//send them their loaned asset
       asset.transfer(_borrower, _borrowAmount);
       emit Borrowed(_borrower, _borrowAmount);
  }

  struct RepayBorrowLocalVars {
      MathError mathErr;
      uint repayAmount;
      uint borrowerIndex;
      uint accountBorrows;
      uint accountBorrowsNew;
      uint totalBorrowsNew;
  }

/**
@notice Sender repays their own borrow
@param repayAmount The amount to repay
*/
  function repayBorrow(uint repayAmount, address borrower) external onlyMMInstance returns(uint){
    accrueInterest();
//create local vars storage
    RepayBorrowLocalVars memory vars;
//We remember the original borrowerIndex for verification purposes
    vars.borrowerIndex = accountBorrows[borrower].interestIndex;
//We fetch the amount the borrower owes, with accumulated interest
    vars.accountBorrows = borrowBalanceCurrent(borrower);
//If repayAmount == 0, repayAmount = accountBorrows
    if (repayAmount == 0) {
        vars.repayAmount = vars.accountBorrows;
    } else {
        vars.repayAmount = repayAmount;
    }


//We calculate the new borrower and total borrow balances

//accountBorrowsNew = accountBorrows - actualRepayAmount
    (vars.mathErr, vars.accountBorrowsNew) = subUInt(vars.accountBorrows, vars.repayAmount);
//totalBorrowsNew = totalBorrows - actualRepayAmount
    (vars.mathErr, vars.totalBorrowsNew) = subUInt(totalBorrows, vars.repayAmount);
    /* We write the previously calculated values into storage */
    accountBorrows[borrower].principal = vars.accountBorrowsNew;
    accountBorrows[borrower].interestIndex = borrowIndex;
    totalBorrows = vars.totalBorrowsNew;
    emit Repayed(borrower, vars.repayAmount);
    return vars.repayAmount;
  }

  /**
  @notice markAccountNonCompliant is used by a potential liquidator to mark an account as non compliant which starts its 30 minute timer
  @param _borrower is the address of the non compliant borrower
  **/
    function markAccountNonCompliant(address _borrower) public {
      //needs to check for account compliance
      require(nonCompliant[_borrower] == 0);
      nonCompliant[_borrower] = now;
      emit NonCompliantTimerStart(_borrower);
    }
  //struct used to avoid stack too deep errors
    struct liquidateLocalVar {
        address assetOwed;
        address assetColat;
        uint borrowedAmount;
        uint collatAmount;
        uint borrowedValue;
        uint borrowedValue150;
        uint collatValue;
        uint halfVal;
        uint exchangeRateMantissa; // Note: reverts on error
        uint seizeTokens;
    }

  /**
  @notice _liquidateFor is called by the liquidateAccount function on a MMI where a user is being liquidated. This function
          is called on a MMI contract where collateral is staked.
  @param repayAmount The amount of the underlying borrowed asset to repay
  **/
  function liquidateAccount(
    address _borrower,
    address _liquidator,
    AskoRiskToken _ARTcollateralized,
    uint repayAmount
  ) public {

    //checks if its been nonCompliant for more than a half hour
        require(now >= nonCompliant[_borrower].add(1800));
        //create local vars storage
            liquidateLocalVar memory vars;
    //get asset addresses of collateral ART
         vars.assetColat = _ARTcollateralized.getAssetAdd();

    //Read oracle prices for borrowed and collateral markets
        uint priceBorrowedMantissa = UOF.getUnderlyingPrice(address(asset));
        uint priceCollateralMantissa = UOF.getUnderlyingPrice( vars.assetColat);
        require(priceBorrowedMantissa != 0 && priceCollateralMantissa != 0);
    //retrieve asset amounts for each
        vars.borrowedAmount = borrowBalanceCurrent(_borrower);
    //calculate USDC value amounts of each
        vars.borrowedValue = vars.borrowedAmount.mul(priceBorrowedMantissa);
        vars.collatValue = MMF.checkAvailibleCollateralValue(_borrower, vars.assetColat);
    //divide borrowedValue value in half
        vars.halfVal = vars.borrowedValue.div(2);
    //add 1/2 the borrowedValue value to the total borrowedValue value for 150% borrowedValue value
        vars.borrowedValue150 = vars.borrowedValue.add(vars.halfVal);
    /**
    need to check if the amount of collateral is less than 150% of the borrowed amount
    if the collateral value is greater than or equal to 150% of the borrowed value than we liquidate
    if not than the non compliance timer is reset
    **/
        if (vars.collatValue <= vars.borrowedValue150){
    //Get the exchange rate and calculate the number of collateral tokens to seize:
         vars.exchangeRateMantissa = exchangeRateCurrent(); // Note: reverts on error

        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;
    //numerator = liquidationIncentive * priceBorrowed
        (mathErr, numerator) = mulExp( liquidationIncentiveMantissa, priceBorrowedMantissa);
    //denominator = priceCollateral * exchangeRate
        (mathErr, denominator) = mulExp(priceCollateralMantissa, vars.exchangeRateMantissa);
    //ratio = (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
        (mathErr, ratio) = divExp(numerator, denominator);
    //seizeTokens = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
        (mathErr, vars.seizeTokens) = mulScalarTruncate(ratio, repayAmount);
    //get balance before swap
        uint pbal = _ARTcollateralized.getCash();
    //swap out collateral for this contracts asset and send it
        UOF.swapERC20(address(asset),  vars.assetColat, address(_ARTcollateralized), vars.seizeTokens, vars.borrowedAmount);
    //let recipeint Money Asko Risk Token know about the incoming liquidation
      _ARTcollateralized.liquidateReceive(vars.borrowedAmount, _borrower, _liquidator, pbal);
    //track collateral
    MMF.trackCollateralDown(_borrower, address(_ARTcollateralized), vars.seizeTokens);
    emit Accountliquidated(_borrower, msg.sender, repayAmount, address(this), address(_ARTcollateralized));
  }
//if account is compliant
//reset accounts compliant timer
nonCompliant[_borrower] = 0;//resets borrowers compliance timer
emit NonCompliantTimerReset(_borrower);
  }

/**

**/
  function liquidateReceive(uint _amount, address _borrower, address _liquidator, uint _pbal) external {
    require(MMI.checkIfALR(msg.sender));
    uint liquidationReward = _amount.mul(liquidationIncentiveMantissa);
    uint nbal = getCashPrior();
    uint remaining = nbal.sub(_pbal).sub(_amount.sub(liquidationReward));
    asset.transfer(_liquidator, liquidationReward);
    asset.transfer(_borrower, remaining);

  }

/**
@notice getAssetAdd allows for easy retrieval of a Money Markets underlying asset's address
**/
    function getAssetAdd() public view returns (address) {
      return address(asset);
    }

}
