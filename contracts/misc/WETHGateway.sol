// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.6.8;
pragma experimental ABIEncoderV2;

import {IWETH} from './interfaces/IWETH.sol';
import {IWETHGateway} from './interfaces/IWETHGateway.sol';
import {ILendingPool} from '../interfaces/ILendingPool.sol';
import {ILendingPoolAddressesProvider} from '../interfaces/ILendingPoolAddressesProvider.sol';
import {IAToken} from '../tokenization/interfaces/IAToken.sol';
import {ReserveLogic} from '../libraries/logic/ReserveLogic.sol';
import {ReserveConfiguration} from '../libraries/configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../libraries/configuration/UserConfiguration.sol';
import {Helpers} from '../libraries/helpers/Helpers.sol';
import '@nomiclabs/buidler/console.sol';

contract WETHGateway is IWETHGateway {
  using ReserveConfiguration for ReserveConfiguration.Map;
  using UserConfiguration for UserConfiguration.Map;

  IWETH public immutable WETH;
  ILendingPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

  /**
   * @dev Sets the WETH address and the LendingPoolAddressesProvider address. Infinite approves lending pool.
   * @param _WETH Address of the Wrapped Ether contract
   * @param _ADDRESSES_PROVIDER Address of the LendingPoolAddressesProvider contract
   **/
  constructor(address _WETH, address _ADDRESSES_PROVIDER) public {
    WETH = IWETH(_WETH);
    ADDRESSES_PROVIDER = ILendingPoolAddressesProvider(_ADDRESSES_PROVIDER);
    IWETH(_WETH).approve(
      address(ILendingPool(ILendingPoolAddressesProvider(_ADDRESSES_PROVIDER).getLendingPool())),
      uint256(-1)
    );
  }

  /**
   * @dev deposits WETH into the reserve, using native ETH. A corresponding amount of the overlying asset (aTokens)
   * is minted.
   * @param onBehalfOf address of the user who will receive the aTokens representing the deposit
   * @param referralCode integrators are assigned a referral code and can potentially receive rewards.
   **/
  function depositETH(address onBehalfOf, uint16 referralCode) external override payable {
    ILendingPool pool = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());
    require(address(pool) != address(0));
    WETH.deposit{value: msg.value}();
    pool.deposit(address(WETH), msg.value, onBehalfOf, referralCode);
  }

  /**
   * @dev withdraws the WETH _reserves of msg.sender.
   * @param amount address of the user who will receive the aTokens representing the deposit
   */
  function withdrawETH(uint256 amount, address onBehalfOf) external override {
    ILendingPool pool = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());
    require(address(pool) != address(0));

    uint256 userBalance = IAToken(pool.getReserveData(address(WETH)).aTokenAddress).balanceOf(
      msg.sender
    );
    uint256 amountToWithdraw = amount;

    // if amount is equal to uint(-1), the user wants to redeem everything
    if (amount == type(uint256).max) {
      amountToWithdraw = userBalance;
    }
    IAToken(pool.getReserveData(address(WETH)).aTokenAddress).transferFrom(
      msg.sender,
      address(this),
      amountToWithdraw
    );
    pool.withdraw(address(WETH), amountToWithdraw, address(this));
    WETH.withdraw(amountToWithdraw);
    safeTransferETH(onBehalfOf, amountToWithdraw);
  }

  /**
   * @dev repays a borrow on the WETH reserve, for the specified amount (or for the whole amount, if uint256(-1) is specified).
   * @param amount the amount to repay, or uint256(-1) if the user wants to repay everything
   * @param rateMode the rate mode to repay
   * @param onBehalfOf the address for which msg.sender is repaying
   */
  function repayETH(
    uint256 amount,
    uint256 rateMode,
    address onBehalfOf
  ) external override payable {
    ILendingPool pool = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());
    require(address(pool) != address(0));
    (uint256 stableDebt, uint256 variableDebt) = Helpers.getUserCurrentDebtMemory(
      onBehalfOf,
      pool.getReserveData(address(WETH))
    );

    uint256 paybackAmount = ReserveLogic.InterestRateMode(rateMode) ==
      ReserveLogic.InterestRateMode.STABLE
      ? stableDebt
      : variableDebt;

    if (amount < paybackAmount) {
      paybackAmount = amount;
    }
    require(msg.value >= paybackAmount, 'msg.value is less than repayment amount');
    WETH.deposit{value: paybackAmount}();
    pool.repay(address(WETH), msg.value, rateMode, onBehalfOf);

    // refund remaining dust eth
    if (msg.value > paybackAmount) safeTransferETH(msg.sender, msg.value - paybackAmount);
  }

  /**
   * @dev transfer ETH to an address, revert if it fails.
   * @param to recipient of the transfer
   * @param value the amount to send
   */
  function safeTransferETH(address to, uint256 value) internal {
    (bool success, ) = to.call{value: value}(new bytes(0));
    require(success, 'ETH_TRANSFER_FAILED');
  }

  /**
   * @dev Only WETH contract is allowed to transfer ETH here. Prevent other addresses to send Ether to this contract.
   */
  receive() external payable {
    assert(msg.sender == address(WETH));
  }
}
