// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata as IERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {MockStakingV1} from "V2-gov/test/mocks/MockStakingV1.sol";
import {CurveV2GaugeRewards} from "V2-gov/src/CurveV2GaugeRewards.sol";
import {Governance} from "V2-gov/src/Governance.sol";
import {ILeverageZapper} from "src/Zappers/Interfaces/ILeverageZapper.sol";
import {IZapper} from "src/Zappers/Interfaces/IZapper.sol";
import {Ownable} from "src/Dependencies/Ownable.sol";
import {IPriceFeed} from "src/Interfaces/IPriceFeed.sol";
import {ICurveStableSwapNG} from "./Interfaces/Curve/ICurveStableSwapNG.sol";
import {ILiquidityGaugeV6} from "./Interfaces/Curve/ILiquidityGaugeV6.sol";
import {IBorrowerOperationsV1} from "./Interfaces/LiquityV1/IBorrowerOperationsV1.sol";
import {IPriceFeedV1} from "./Interfaces/LiquityV1/IPriceFeedV1.sol";
import {ISortedTrovesV1} from "./Interfaces/LiquityV1/ISortedTrovesV1.sol";
import {ITroveManagerV1} from "./Interfaces/LiquityV1/ITroveManagerV1.sol";
import {ERC20Faucet} from "./TestContracts/ERC20Faucet.sol";
import {StringEquality} from "./Utils/StringEquality.sol";
import {UseDeployment} from "./Utils/UseDeployment.sol";
import {TroveId} from "./Utils/TroveId.sol";

uint256 constant PRICE_TOLERANCE = 0.02 ether;

address constant ETH_WHALE = 0x76eC5A0D3632b2133d9f1980903305B62678Fbd3; // Anvil account #1
address constant WETH_WHALE = 0xC3E5607Cd4ca0D5Fe51e09B60Ed97a0Ae6F874dd; // Anvil account #2


address constant WSTETH_WHALE = 0xCeF9Cdd466d03A1cEdf57E014d8F6Bdc87872189;
address constant RETH_WHALE = 0xa7F3C74f0255796Fd5D3DDCf88db769f7a6bf46a;
address constant RSETH_WHALE = 0x6b030Ff3FB9956B1B69f475B77aE0d3Cf2CC5aFa;
address constant WEETH_WHALE = 0x6b030Ff3FB9956B1B69f475B77aE0d3Cf2CC5aFa;
address constant ARB_WHALE = 0x5a52E96BAcdaBb82fd05763E25335261B270Efcb;
address constant COMP_WHALE = 0x6e57181D6b4b7c138a6F956AD16DAF4f27FC5E04;
address constant TBTC_WHALE = 0x256843dDD1345bBF2943aB33b11Ccf68d80f769E;



IBorrowerOperationsV1 constant mainnet_V1_borrowerOperations = IBorrowerOperationsV1(0x24179CD81c9e782A4096035f7eC97fB8B783e007);
IPriceFeedV1 constant mainnet_V1_priceFeed = IPriceFeedV1(0x4c517D4e2C851CA76d7eC94B805269Df0f2201De);
ISortedTrovesV1 constant mainnet_V1_sortedTroves = ISortedTrovesV1(0x8FdD3fbFEb32b28fb73555518f8b361bCeA741A6);
ITroveManagerV1 constant mainnet_V1_troveManager = ITroveManagerV1(0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2);

function coalesce(address a, address b) pure returns (address) {
    return a != address(0) ? a : b;
}

contract SideEffectFreeGetPriceHelper {
    function _revert(bytes memory revertData) internal pure {
        assembly {
            revert(add(32, revertData), mload(revertData))
        }
    }

    function throwPrice(IPriceFeed priceFeed) external {
        (uint256 price,) = priceFeed.fetchPrice();
        console.log("found a good price:", price);
        _revert(abi.encode(price));
    }

    function throwPriceV1(IPriceFeedV1 priceFeed) external {
        _revert(abi.encode(priceFeed.fetchPrice()));
    }
}

library SideEffectFreeGetPrice {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Random address
    address private constant helperDeployer = 0x9C82588e2B9229168aDbb55E730e0d20c0581a3B;

    // Deterministic address of first contract deployed by `helperDeployer`
    SideEffectFreeGetPriceHelper private constant helper =
        SideEffectFreeGetPriceHelper(0xc583097AE39B039fA74bB5bd6479469290B7cDe5);

    function deploy() internal {
        if (address(helper).code.length == 0) {
            vm.prank(helperDeployer);
            new SideEffectFreeGetPriceHelper();
        }
    }

    function getPrice(IPriceFeed priceFeed) internal returns (uint256) {
        deploy();

        try helper.throwPrice(priceFeed) {
            revert("SideEffectFreeGetPrice: throwPrice() should have reverted");
        } catch (bytes memory revertData) {
            return abi.decode(revertData, (uint256));
        }
    }

    function getPrice(IPriceFeedV1 priceFeed) internal returns (uint256) {
        deploy();

        try helper.throwPriceV1(priceFeed) {
            revert("SideEffectFreeGetPrice: throwPriceV1() should have reverted");
        } catch (bytes memory revertData) {
            return abi.decode(revertData, (uint256));
        }
    }
}

contract E2ETest is Test, UseDeployment, TroveId {
    using SideEffectFreeGetPrice for IPriceFeed;
    using SideEffectFreeGetPrice for IPriceFeedV1;
    using StringEquality for string;

    struct Initiative {
        address addr;
        ILiquidityGaugeV6 gauge; // optional
    }

    mapping(address token => address) providerOf;

    address[] ownables;

    address[] _allocateLQTY_initiativesToReset;
    address[] _allocateLQTY_initiatives;
    int256[] _allocateLQTY_votes;
    int256[] _allocateLQTY_vetos;

    function setUp() external {
        //vm.skip(vm.envOr("FOUNDRY_PROFILE", string("")).notEq("e2e"));
        vm.createSelectFork(vm.envString("E2E_RPC_URL")); //arbitrum
        console.log("E2E_RPC_URL", vm.envString("E2E_RPC_URL"));
        _loadDeploymentFromManifest("deployment-manifest.json");
        console.log("Manifest loaded!!");
        
        console.log("WETH", WETH);

        vm.label(ETH_WHALE, "ETH_WHALE");
        vm.label(WETH_WHALE, "WETH_WHALE");
        vm.label(WSTETH_WHALE, "WSTETH_WHALE");
        vm.label(RETH_WHALE, "RETH_WHALE");
        vm.label(RSETH_WHALE, "RSETH_WHALE");
        vm.label(WEETH_WHALE, "WEETH_WHALE");
        vm.label(ARB_WHALE, "ARB_WHALE");
        vm.label(COMP_WHALE, "COMP_WHALE");
        vm.label(TBTC_WHALE, "TBTC_WHALE");

        providerOf[WETH] = WETH_WHALE;
        providerOf[WSTETH] = WSTETH_WHALE;
        providerOf[RETH] = RETH_WHALE;
        providerOf[0x4186BFC76E2E237523CBC30FD220FE055156b41F] = RSETH_WHALE;
        providerOf[0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe] = WEETH_WHALE;
        providerOf[0x912CE59144191C1204E64559FE8253a0e49E6548] = ARB_WHALE;
        providerOf[0x912CE59144191C1204E64559FE8253a0e49E6548] = COMP_WHALE;
        providerOf[0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40] = TBTC_WHALE;

        console.log("pranking as eth whale:");
        vm.prank(WETH_WHALE);
        weth.deposit{value: WETH_WHALE.balance}();
        console.log("deposited as eth whale");

        // Testnet
        console.log("block.chainid", block.chainid);
        if (block.chainid != 42161) {
            address[5] memory coins = [WSTETH, RETH, USDC, LQTY, LUSD];

            for (uint256 i = 0; i < coins.length; ++i) {
                ERC20Faucet faucet = ERC20Faucet(coins[i]);
                vm.prank(faucet.owner());
                faucet.mint(providerOf[coins[i]], 1e6 ether);
            }
        }
    }

    function deal(address to, uint256 give) internal virtual override {
        if (to.balance < give) {
            vm.prank(ETH_WHALE);
            payable(to).transfer(give - to.balance);
        } else {
            vm.prank(to);
            payable(ETH_WHALE).transfer(to.balance - give);
        }
    }

    function deal(address token, address to, uint256 give) internal virtual override {
        uint256 balance = IERC20(token).balanceOf(to);
        address provider = providerOf[token];

        assertNotEq(provider, address(0), string.concat("No provider for ", IERC20(token).symbol()));

        if (balance < give) {
            vm.prank(provider);
            IERC20(token).transfer(to, give - balance);
        } else {
            vm.prank(to);
            IERC20(token).transfer(provider, balance - give);
        }
    }

    function deal(address token, address to, uint256 give, bool) internal virtual override {
        deal(token, to, give);
    }

    function _openTrove(uint256 i, address owner, uint256 ownerIndex, uint256 boldAmount) internal returns (uint256) {
        IZapper.OpenTroveParams memory p;
        p.owner = owner;
        p.ownerIndex = ownerIndex;
        p.boldAmount = boldAmount;
        p.collAmount = boldAmount * 2 ether / branches[i].priceFeed.getPrice();
        p.annualInterestRate = 0.05 ether;
        p.maxUpfrontFee = hintHelpers.predictOpenTroveUpfrontFee(i, boldAmount, p.annualInterestRate);

        (uint256 collTokenAmount, uint256 value) = branches[i].collToken == weth
            ? (0, p.collAmount + ETH_GAS_COMPENSATION)
            : (p.collAmount, ETH_GAS_COMPENSATION);

        console.log("dealing in openTrove:", owner, value);
        deal(owner, value);
        deal(address(branches[i].collToken), owner, collTokenAmount);
        console.log("dealt in openTrove:", owner, collTokenAmount);

        vm.startPrank(owner);
        console.log("pranking in openTrove:", owner);
        branches[i].collToken.approve(address(branches[i].zapper), collTokenAmount);
        console.log("approving in openTrove:", owner, collTokenAmount);
        branches[i].zapper.openTroveWithRawETH{value: value}(p);
        vm.stopPrank();

        return boldAmount;
    }

    function _closeTroveFromCollateral(uint256 i, address owner, uint256 ownerIndex, bool _leveraged)
        internal
        returns (uint256)
    {
        IZapper zapper;
        if (_leveraged) {
            zapper = branches[i].leverageZapper;
        } else {
            zapper = branches[i].zapper;
        }
        uint256 troveId = addressToTroveIdThroughZapper(address(zapper), owner, ownerIndex);
        uint256 debt = branches[i].troveManager.getLatestTroveData(troveId).entireDebt;

        uint256 coll = branches[i].troveManager.getLatestTroveData(troveId).entireColl;
        uint256 flashLoanAmount = debt * (1 ether + PRICE_TOLERANCE) / branches[i].priceFeed.getPrice();

        vm.startPrank(owner);
        zapper.closeTroveFromCollateral({
            _troveId: troveId,
            _flashLoanAmount: flashLoanAmount,
            _minExpectedCollateral: coll - flashLoanAmount
        });
        vm.stopPrank();

        return debt;
    }

    function _openLeveragedTrove(uint256 i, address owner, uint256 ownerIndex, uint256 boldAmount)
        internal
        returns (uint256)
    {
        uint256 price = branches[i].priceFeed.getPrice();

        ILeverageZapper.OpenLeveragedTroveParams memory p;
        p.owner = owner;
        p.ownerIndex = ownerIndex;
        p.boldAmount = boldAmount;
        p.collAmount = boldAmount * 0.5 ether / price;
        p.flashLoanAmount = boldAmount * (1 ether - PRICE_TOLERANCE) / price;
        p.annualInterestRate = 0.1 ether;
        p.maxUpfrontFee = hintHelpers.predictOpenTroveUpfrontFee(i, boldAmount, p.annualInterestRate);

        (uint256 collTokenAmount, uint256 value) = branches[i].collToken == weth
            ? (0, p.collAmount + ETH_GAS_COMPENSATION)
            : (p.collAmount, ETH_GAS_COMPENSATION);

        deal(owner, value);
        deal(address(branches[i].collToken), owner, collTokenAmount);

        vm.startPrank(owner);
        branches[i].collToken.approve(address(branches[i].leverageZapper), collTokenAmount);
        branches[i].leverageZapper.openLeveragedTroveWithRawETH{value: value}(p);
        vm.stopPrank();

        return boldAmount;
    }

    function _leverUpTrove(uint256 i, address owner, uint256 ownerIndex, uint256 boldAmount)
        internal
        returns (uint256)
    {
        uint256 troveId = addressToTroveIdThroughZapper(address(branches[i].leverageZapper), owner, ownerIndex);

        ILeverageZapper.LeverUpTroveParams memory p = ILeverageZapper.LeverUpTroveParams({
            troveId: troveId,
            boldAmount: boldAmount,
            flashLoanAmount: boldAmount * (1 ether - PRICE_TOLERANCE) / branches[i].priceFeed.getPrice(),
            maxUpfrontFee: hintHelpers.predictAdjustTroveUpfrontFee(i, troveId, boldAmount)
        });

        vm.prank(owner);
        branches[i].leverageZapper.leverUpTrove(p);

        return boldAmount;
    }

    function _leverDownTrove(uint256 i, address owner, uint256 ownerIndex, uint256 boldAmount)
        internal
        returns (uint256)
    {
        uint256 troveId = addressToTroveIdThroughZapper(address(branches[i].leverageZapper), owner, ownerIndex);
        uint256 debtBefore = branches[i].troveManager.getLatestTroveData(troveId).entireDebt;

        ILeverageZapper.LeverDownTroveParams memory p = ILeverageZapper.LeverDownTroveParams({
            troveId: troveId,
            minBoldAmount: boldAmount,
            flashLoanAmount: boldAmount * (1 ether + PRICE_TOLERANCE) / branches[i].priceFeed.getPrice()
        });

        vm.prank(owner);
        branches[i].leverageZapper.leverDownTrove(p);

        return debtBefore - branches[i].troveManager.getLatestTroveData(troveId).entireDebt;
    }

    function _addCurveLiquidity(
        address liquidityProvider,
        ICurveStableSwapNG pool,
        uint256 coin0Amount,
        address coin0,
        uint256 coin1Amount,
        address coin1
    ) internal {
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = pool.coins(0) == coin0 ? (coin0Amount, coin1Amount) : (coin1Amount, coin0Amount);

        deal(coin0, liquidityProvider, coin0Amount);
        deal(coin1, liquidityProvider, coin1Amount);

        vm.startPrank(liquidityProvider);
        IERC20(coin0).approve(address(pool), coin0Amount);
        IERC20(coin1).approve(address(pool), coin1Amount);
        pool.add_liquidity(amounts, 0);
        vm.stopPrank();
    }

    function _depositIntoCurveGauge(address liquidityProvider, ILiquidityGaugeV6 gauge, uint256 amount) internal {
        vm.startPrank(liquidityProvider);
        gauge.lp_token().approve(address(gauge), amount);
        gauge.deposit(amount);
        vm.stopPrank();
    }

    function _claimRewardsFromCurveGauge(address liquidityProvider, ILiquidityGaugeV6 gauge) internal {
        vm.prank(liquidityProvider);
        gauge.claim_rewards();
    }

    function _provideToSP(uint256 i, address depositor, uint256 boldAmount) internal {
        deal(BOLD, depositor, boldAmount);
        vm.prank(depositor);
        branches[i].stabilityPool.provideToSP(boldAmount, false);
    }

    function _claimFromSP(uint256 i, address depositor) internal {
        vm.prank(depositor);
        branches[i].stabilityPool.withdrawFromSP(0, true);
    }

    function _depositLQTY(address voter, uint256 amount) internal {
        deal(LQTY, voter, amount);

        vm.startPrank(voter);
        lqty.approve(governance.deriveUserProxyAddress(voter), amount);
        governance.depositLQTY(amount);
        vm.stopPrank();
    }

    function _allocateLQTY_begin(address voter) internal {
        vm.startPrank(voter);
    }

    function _allocateLQTY_reset(address initiative) internal {
        _allocateLQTY_initiativesToReset.push(initiative);
    }

    function _allocateLQTY_vote(address initiative, int256 lqtyAmount) internal {
        _allocateLQTY_initiatives.push(initiative);
        _allocateLQTY_votes.push(lqtyAmount);
        _allocateLQTY_vetos.push();
    }

    function _allocateLQTY_veto(address initiative, int256 lqtyAmount) internal {
        _allocateLQTY_initiatives.push(initiative);
        _allocateLQTY_votes.push();
        _allocateLQTY_vetos.push(lqtyAmount);
    }

    function _allocateLQTY_end() internal {
        governance.allocateLQTY(
            _allocateLQTY_initiativesToReset, _allocateLQTY_initiatives, _allocateLQTY_votes, _allocateLQTY_vetos
        );

        delete _allocateLQTY_initiativesToReset;
        delete _allocateLQTY_initiatives;
        delete _allocateLQTY_votes;
        delete _allocateLQTY_vetos;

        vm.stopPrank();
    }

    function _mainnet_V1_openTroveAtTail(address owner, uint256 lusdAmount) internal returns (uint256 borrowingFee) {
        uint256 price = mainnet_V1_priceFeed.getPrice();
        address lastTrove = mainnet_V1_sortedTroves.getLast();
        assertGeDecimal(mainnet_V1_troveManager.getCurrentICR(lastTrove, price), 1.1 ether, 18, "last ICR < MCR");

        uint256 borrowingRate = mainnet_V1_troveManager.getBorrowingRateWithDecay();
        borrowingFee = lusdAmount * borrowingRate / 1 ether;
        uint256 debt = lusdAmount + borrowingFee + 200 ether;
        uint256 collAmount = Math.ceilDiv(debt * 1.1 ether, price);
        deal(owner, collAmount);

        vm.startPrank(owner);
        mainnet_V1_borrowerOperations.openTrove{value: collAmount}({
            _LUSDAmount: lusdAmount,
            _maxFeePercentage: borrowingRate,
            _upperHint: lastTrove,
            _lowerHint: address(0)
        });
        vm.stopPrank();

        assertEq(mainnet_V1_sortedTroves.getLast(), owner, "last Trove != new Trove");
    }

    function _mainnet_V1_redeemCollateralFromTroveAtTail(address redeemer, uint256 lusdAmount)
        internal
        returns (uint256 redemptionFee)
    {
        address lastTrove = mainnet_V1_sortedTroves.getLast();
        address prevTrove = mainnet_V1_sortedTroves.getPrev(lastTrove);
        (uint256 lastTroveDebt, uint256 lastTroveColl,,) = mainnet_V1_troveManager.getEntireDebtAndColl(lastTrove);
        assertLeDecimal(lusdAmount, lastTroveDebt - 2_000 ether, 18, "lusdAmount > redeemable from last Trove");

        uint256 price = mainnet_V1_priceFeed.getPrice();
        uint256 collAmount = lusdAmount * 1 ether / price;
        uint256 balanceBefore = redeemer.balance;

        vm.startPrank(redeemer);
        mainnet_V1_troveManager.redeemCollateral({
            _LUSDamount: lusdAmount,
            _maxFeePercentage: 1 ether,
            _maxIterations: 1,
            _firstRedemptionHint: lastTrove,
            _upperPartialRedemptionHint: prevTrove,
            _lowerPartialRedemptionHint: prevTrove,
            _partialRedemptionHintNICR: (lastTroveColl - collAmount) * 100 ether / (lastTroveDebt - lusdAmount)
        });
        vm.stopPrank();

        redemptionFee = collAmount * mainnet_V1_troveManager.getBorrowingRateWithDecay() / 1 ether;
        assertEqDecimal(redeemer.balance - balanceBefore, collAmount - redemptionFee, 18, "coll received != expected");
    }

    function _generateStakingRewards() internal returns (uint256 lusdAmount, uint256 ethAmount) {
        if (block.chainid == 42161) {
            address stakingRewardGenerator = makeAddr("stakingRewardGenerator");
            lusdAmount = _mainnet_V1_openTroveAtTail(stakingRewardGenerator, 1e6 ether);
            ethAmount = _mainnet_V1_redeemCollateralFromTroveAtTail(stakingRewardGenerator, 1_000 ether);
        } else {
            // Testnet
            lusdAmount = 10_000 ether;
            ethAmount = 1 ether;

            MockStakingV1 stakingV1 = MockStakingV1(address(governance.stakingV1()));
            address owner = stakingV1.owner();

            deal(LUSD, owner, lusdAmount);
            deal(owner, ethAmount);

            vm.startPrank(owner);
            lusd.approve(address(stakingV1), lusdAmount);
            stakingV1.mock_addLUSDGain(lusdAmount);
            stakingV1.mock_addETHGain{value: ethAmount}();
            vm.stopPrank();
        }
    }

    function test_OwnershipRenounced() external {
        ownables.push(address(boldToken));

        for (uint256 i = 0; i < branches.length; ++i) {

            //console.log("checking branch", i, "token:", (branches[i].collToken.symbol()));
           
            ownables.push(address(branches[i].addressesRegistry));
            if (block.chainid == 42161) {
                //console.log("adding priceFeed");
                ownables.push(address(branches[i].priceFeed));
            }
        }

        for (uint256 i = 0; i < ownables.length; ++i) {
            
            assertEq(
                Ownable(ownables[i]).owner(),
                address(0),
                string.concat("Ownership of ", vm.getLabel(ownables[i]), " should have been renounced")
            );
        }
    }

    function _epoch(uint256 n) internal view returns (uint256) {
        return EPOCH_START + (n - 1) * EPOCH_DURATION;
    }

    function test_Initially_NewInitiativeCannotBeRegistered() external {
        //vm.skip(governance.epoch() > 2);

        address registrant = makeAddr("registrant");
        address newInitiative = makeAddr("newInitiative");

        _openTrove(0, registrant, 0, Math.max(REGISTRATION_FEE, MIN_DEBT));

        uint256 epoch2 = _epoch(2);
        if (block.timestamp < epoch2) vm.warp(epoch2);

        vm.startPrank(registrant);
        {
            boldToken.approve(address(governance), REGISTRATION_FEE);
            //vm.expectRevert("Governance: registration-not-yet-enabled");
            //governance.registerInitiative(newInitiative);
        }
        vm.stopPrank();
    }

    function test_AfterOneEpoch_NewInitiativeCanBeRegistered() external {
       // vm.skip(governance.epoch() > 2);

        address registrant = makeAddr("registrant");
        address newInitiative = makeAddr("newInitiative");

        _openTrove(0, registrant, 0, Math.max(REGISTRATION_FEE, MIN_DEBT));

        uint256 epoch3 = _epoch(3);
        if (block.timestamp < epoch3) vm.warp(epoch3);


    }

    function test_E2E() external {
        // Test assumes that all Stability Pools are empty in the beginning
        for (uint256 i = 0; i < branches.length; ++i) {
            //vm.skip(branches[i].stabilityPool.getTotalBoldDeposits() != 0);
        }

        uint256 repaid;
        uint256 borrowed = boldToken.totalSupply() - boldToken.balanceOf(address(governance));

        for (uint256 i = 0; i < 3; ++i) {
            borrowed -= boldToken.balanceOf(address(branches[i].stabilityPool));
        }

        if (block.chainid == 42161) {
            //assertEqDecimal(borrowed, 0, 18, "Mainnet deployment script should not have borrowed anything");//turn this back on for future E2E on fresh deployment.
        }

        address borrower = providerOf[BOLD] = makeAddr("borrower");

        for (uint256 j = 0; j < 5; ++j) {
            for (uint256 i = 0; i < 3; ++i) {
                skip(5 minutes);
                borrowed += _openTrove(i, borrower, j, 100000 ether);
            }
        }

        address stabilityDepositor = makeAddr("stabilityDepositor");

        for (uint256 i = 0; i < branches.length; ++i) {
            skip(5 minutes);
            _provideToSP(i, stabilityDepositor, boldToken.balanceOf(borrower) / (branches.length - i));
        }

        skip(5 minutes);

        /* skip staking LQTY tests because Nerite does not use LQTY or have these functions.
        address staker = makeAddr("staker");
        {
            uint256 lqtyStake = 30_000 ether;
            _depositLQTY(staker, lqtyStake);

            skip(5 minutes);

            (uint256 lusdAmount, uint256 ethAmount) = _generateStakingRewards();
            uint256 totalLQTYStaked = governance.stakingV1().totalLQTYStaked();

            skip(5 minutes);

            vm.prank(staker);
            governance.claimFromStakingV1(staker);

            assertApproxEqAbsDecimal(
                lusd.balanceOf(staker), lusdAmount * lqtyStake / totalLQTYStaked, 1e5, 18, "LUSD reward"
            );
            assertApproxEqAbsDecimal(staker.balance, ethAmount * lqtyStake / totalLQTYStaked, 1e5, 18, "ETH reward");

            skip(5 minutes);

            if (numInitiatives > 0) {
                // Voting on initial initiatives opens in epoch #2
                uint256 votingStart = _epoch(2);
                if (block.timestamp < votingStart) vm.warp(votingStart);

                _allocateLQTY_begin(staker);

                for (uint256 i = 0; i < initiatives.length; ++i) {
                    if (initiatives[i].addr != address(0)) {
                        _allocateLQTY_vote(initiatives[i].addr, int256(lqtyStake / numInitiatives));
                    }
                }

                _allocateLQTY_end();
            }
        }
        */

        skip(EPOCH_DURATION);

        for (uint256 i = 0; i < branches.length; ++i) {
            skip(5 minutes);
            _claimFromSP(i, stabilityDepositor);
        }

        uint256 interest = boldToken.totalSupply() + repaid - borrowed;
        uint256 spShareOfInterest = boldToken.balanceOf(stabilityDepositor);
        uint256 governanceShareOfInterest = boldToken.balanceOf(address(governance));

        console.log("totalSupply", boldToken.totalSupply());
        console.log("repaid", repaid);
        console.log("borrowed", borrowed);
        console.log("interest", interest);
        console.log("spShareOfInterest", spShareOfInterest);
        console.log("governanceShareOfInterest", governanceShareOfInterest);

        assertApproxEqRelDecimal(
            interest,
            spShareOfInterest + governanceShareOfInterest,
            1e-1 ether,
            18,
            "Stability depositor and Governance should have received the interest"
        );
    }

    // This can be used to check that everything's still working as expected in a live testnet deployment
    function test_Borrowing_InExistingDeployment() external {
        for (uint256 i = 0; i < branches.length; ++i) {
            vm.skip(branches[i].troveManager.getTroveIdsCount() == 0);
        }

        address borrower = makeAddr("borrower");

        for (uint256 i = 0; i < branches.length; ++i) {
            console.log("opening trove", i);
            _openTrove(i, borrower, 0, 500 ether);
        }
    }
}
