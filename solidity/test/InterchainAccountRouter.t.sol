// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {StandardHookMetadata} from "../contracts/hooks/libs/StandardHookMetadata.sol";
import {MockMailbox} from "../contracts/mock/MockMailbox.sol";
import {MockHyperlaneEnvironment} from "../contracts/mock/MockHyperlaneEnvironment.sol";
import {TypeCasts} from "../contracts/libs/TypeCasts.sol";
import {IInterchainSecurityModule} from "../contracts/interfaces/IInterchainSecurityModule.sol";
import {TestInterchainGasPaymaster} from "../contracts/test/TestInterchainGasPaymaster.sol";
import {IPostDispatchHook} from "../contracts/interfaces/hooks/IPostDispatchHook.sol";
import {CallLib, OwnableMulticall, InterchainAccountRouter} from "../contracts/middleware/InterchainAccountRouter.sol";
import {InterchainAccountIsm} from "../contracts/isms/routing/InterchainAccountIsm.sol";

contract Callable {
    mapping(address => bytes32) public data;

    function set(bytes32 _data) external {
        data[msg.sender] = _data;
    }
}

contract FailingIsm is IInterchainSecurityModule {
    string public failureMessage;
    uint8 public moduleType;

    constructor(string memory _failureMessage) {
        failureMessage = _failureMessage;
    }

    function verify(
        bytes calldata,
        bytes calldata
    ) external view returns (bool) {
        revert(failureMessage);
    }
}

contract InterchainAccountRouterTest is Test {
    using TypeCasts for address;

    event InterchainAccountCreated(
        uint32 indexed origin,
        bytes32 indexed owner,
        address ism,
        address account
    );

    MockHyperlaneEnvironment internal environment;

    uint32 internal origin = 1;
    uint32 internal destination = 2;

    TestInterchainGasPaymaster internal igp;
    InterchainAccountIsm internal icaIsm;
    InterchainAccountRouter internal originRouter;
    InterchainAccountRouter internal destinationRouter;
    bytes32 internal ismOverride;
    bytes32 internal routerOverride;
    uint256 gasPaymentQuote;

    OwnableMulticall internal ica;

    Callable internal target;

    function deployProxiedIcaRouter(
        MockMailbox _mailbox,
        IPostDispatchHook _customHook,
        IInterchainSecurityModule _ism,
        address _owner
    ) public returns (InterchainAccountRouter) {
        InterchainAccountRouter implementation = new InterchainAccountRouter(
            address(_mailbox)
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(1), // no proxy owner necessary for testing
            abi.encodeWithSelector(
                InterchainAccountRouter.initialize.selector,
                address(_customHook),
                address(_ism),
                _owner
            )
        );

        return InterchainAccountRouter(address(proxy));
    }

    function setUp() public {
        environment = new MockHyperlaneEnvironment(origin, destination);

        igp = new TestInterchainGasPaymaster();
        gasPaymentQuote = igp.quoteGasPayment(
            destination,
            igp.getDefaultGasUsage()
        );

        icaIsm = new InterchainAccountIsm(
            address(environment.mailboxes(destination))
        );

        address owner = address(this);
        originRouter = deployProxiedIcaRouter(
            environment.mailboxes(origin),
            environment.igps(destination),
            icaIsm,
            owner
        );
        destinationRouter = deployProxiedIcaRouter(
            environment.mailboxes(destination),
            environment.igps(destination),
            icaIsm,
            owner
        );

        environment.mailboxes(origin).setDefaultHook(address(igp));

        routerOverride = TypeCasts.addressToBytes32(address(destinationRouter));
        ismOverride = TypeCasts.addressToBytes32(
            address(environment.isms(destination))
        );
        ica = destinationRouter.getLocalInterchainAccount(
            origin,
            address(this),
            address(originRouter),
            address(environment.isms(destination))
        );

        target = new Callable();
    }

    function testFuzz_constructor(address _localOwner) public {
        OwnableMulticall _account = destinationRouter
            .getDeployedInterchainAccount(
                origin,
                _localOwner,
                address(originRouter),
                address(environment.isms(destination))
            );
        assertEq(_account.owner(), address(destinationRouter));
    }

    function testFuzz_getRemoteInterchainAccount(
        address _localOwner,
        address _ism
    ) public {
        address _account = originRouter.getRemoteInterchainAccount(
            address(_localOwner),
            address(destinationRouter),
            _ism
        );
        originRouter.enrollRemoteRouterAndIsm(
            destination,
            routerOverride,
            TypeCasts.addressToBytes32(_ism)
        );
        assertEq(
            originRouter.getRemoteInterchainAccount(
                destination,
                address(_localOwner)
            ),
            _account
        );
    }

    function testFuzz_enrollRemoteRouters(
        uint8 count,
        uint32 domain,
        bytes32 router
    ) public {
        vm.assume(count > 0 && count < uint256(router) && count < domain);

        // arrange
        // count - # of domains and routers
        uint32[] memory domains = new uint32[](count);
        bytes32[] memory routers = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            domains[i] = domain - uint32(i);
            routers[i] = bytes32(uint256(router) - i);
        }

        // act
        originRouter.enrollRemoteRouters(domains, routers);

        // assert
        uint32[] memory actualDomains = originRouter.domains();
        assertEq(actualDomains.length, domains.length);
        assertEq(abi.encode(originRouter.domains()), abi.encode(domains));

        for (uint256 i = 0; i < count; i++) {
            bytes32 actualRouter = originRouter.routers(domains[i]);
            bytes32 actualIsm = originRouter.isms(domains[i]);

            assertEq(actualRouter, routers[i]);
            assertEq(actualIsm, bytes32(0));
            assertEq(actualDomains[i], domains[i]);
        }
    }

    function testFuzz_enrollRemoteRouterAndIsm(
        bytes32 router,
        bytes32 ism
    ) public {
        vm.assume(router != bytes32(0));

        // arrange pre-condition
        bytes32 actualRouter = originRouter.routers(destination);
        bytes32 actualIsm = originRouter.isms(destination);
        assertEq(actualRouter, bytes32(0));
        assertEq(actualIsm, bytes32(0));

        // act
        originRouter.enrollRemoteRouterAndIsm(destination, router, ism);

        // assert
        actualRouter = originRouter.routers(destination);
        actualIsm = originRouter.isms(destination);
        assertEq(actualRouter, router);
        assertEq(actualIsm, ism);
    }

    function testFuzz_enrollRemoteRouterAndIsms(
        uint32[] calldata destinations,
        bytes32[] calldata routers,
        bytes32[] calldata isms
    ) public {
        // check reverts
        if (
            destinations.length != routers.length ||
            destinations.length != isms.length
        ) {
            vm.expectRevert(bytes("length mismatch"));
            originRouter.enrollRemoteRouterAndIsms(destinations, routers, isms);
            return;
        }

        // act
        originRouter.enrollRemoteRouterAndIsms(destinations, routers, isms);

        // assert
        for (uint256 i = 0; i < destinations.length; i++) {
            bytes32 actualRouter = originRouter.routers(destinations[i]);
            bytes32 actualIsm = originRouter.isms(destinations[i]);
            assertEq(actualRouter, routers[i]);
            assertEq(actualIsm, isms[i]);
        }
    }

    function testFuzz_enrollRemoteRouterAndIsmImmutable(
        bytes32 routerA,
        bytes32 ismA,
        bytes32 routerB,
        bytes32 ismB
    ) public {
        vm.assume(routerA != bytes32(0) && routerB != bytes32(0));

        // act
        originRouter.enrollRemoteRouterAndIsm(destination, routerA, ismA);

        // assert
        vm.expectRevert(
            bytes("router and ISM defaults are immutable once set")
        );
        originRouter.enrollRemoteRouterAndIsm(destination, routerB, ismB);
    }

    function testFuzz_enrollRemoteRouterAndIsmNonOwner(
        address newOwner,
        bytes32 router,
        bytes32 ism
    ) public {
        vm.assume(newOwner != address(0) && newOwner != originRouter.owner());

        // act
        originRouter.transferOwnership(newOwner);

        // assert
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        originRouter.enrollRemoteRouterAndIsm(destination, router, ism);
    }

    function getCalls(
        bytes32 data
    ) private view returns (CallLib.Call[] memory) {
        vm.assume(data != bytes32(0));

        CallLib.Call memory call = CallLib.Call(
            TypeCasts.addressToBytes32(address(target)),
            0,
            abi.encodeCall(target.set, (data))
        );
        CallLib.Call[] memory calls = new CallLib.Call[](1);
        calls[0] = call;
        return calls;
    }

    function assertRemoteCallReceived(bytes32 data) private {
        assertEq(target.data(address(this)), bytes32(0));
        vm.expectEmit(true, true, false, true, address(destinationRouter));
        emit InterchainAccountCreated(
            origin,
            address(this).addressToBytes32(),
            TypeCasts.bytes32ToAddress(ismOverride),
            address(ica)
        );
        environment.processNextPendingMessage();
        assertEq(target.data(address(ica)), data);
    }

    function assertIgpPayment(
        uint256 balanceBefore,
        uint256 balanceAfter,
        uint256 gasLimit
    ) private {
        uint256 expectedGasPayment = gasLimit * igp.gasPrice();
        assertEq(balanceBefore - balanceAfter, expectedGasPayment);
        assertEq(address(igp).balance, expectedGasPayment);
    }

    function testFuzz_getDeployedInterchainAccount_checkAccountOwners(
        address owner
    ) public {
        // act
        ica = destinationRouter.getDeployedInterchainAccount(
            origin,
            owner,
            address(originRouter),
            address(environment.isms(destination))
        );

        (uint32 domain, bytes32 ownerBytes) = destinationRouter.accountOwners(
            address(ica)
        );
        // assert
        assertEq(domain, origin);
        assertEq(ownerBytes, owner.addressToBytes32());
    }

    function testFuzz_singleCallRemoteWithDefault(bytes32 data) public {
        // arrange
        originRouter.enrollRemoteRouterAndIsm(
            destination,
            routerOverride,
            ismOverride
        );
        uint256 balanceBefore = address(this).balance;

        // act
        CallLib.Call[] memory calls = getCalls(data);
        originRouter.callRemote{value: gasPaymentQuote}(
            destination,
            TypeCasts.bytes32ToAddress(calls[0].to),
            calls[0].value,
            calls[0].data
        );

        // assert
        uint256 balanceAfter = address(this).balance;
        assertRemoteCallReceived(data);
        assertIgpPayment(balanceBefore, balanceAfter, igp.getDefaultGasUsage());
    }

    function testFuzz_callRemoteWithDefault(bytes32 data) public {
        // arrange
        originRouter.enrollRemoteRouterAndIsm(
            destination,
            routerOverride,
            ismOverride
        );
        uint256 balanceBefore = address(this).balance;

        // act
        originRouter.callRemote{value: gasPaymentQuote}(
            destination,
            getCalls(data)
        );

        // assert
        uint256 balanceAfter = address(this).balance;
        assertRemoteCallReceived(data);
        assertIgpPayment(balanceBefore, balanceAfter, igp.getDefaultGasUsage());
    }

    function testFuzz_overrideAndCallRemote(bytes32 data) public {
        // arrange
        originRouter.enrollRemoteRouterAndIsm(
            destination,
            routerOverride,
            ismOverride
        );
        uint256 balanceBefore = address(this).balance;

        // act
        originRouter.callRemote{value: gasPaymentQuote}(
            destination,
            getCalls(data)
        );

        // assert
        uint256 balanceAfter = address(this).balance;
        assertRemoteCallReceived(data);
        assertIgpPayment(balanceBefore, balanceAfter, igp.getDefaultGasUsage());
    }

    function testFuzz_callRemoteWithoutDefaults_revert_noRouter(
        bytes32 data
    ) public {
        // assert error
        CallLib.Call[] memory calls = getCalls(data);
        vm.expectRevert(bytes("no router specified for destination"));
        originRouter.callRemote(destination, calls);
    }

    function testFuzz_customMetadata_forIgp(
        uint64 gasLimit,
        uint64 overpayment,
        bytes32 data
    ) public {
        // arrange
        bytes memory metadata = StandardHookMetadata.formatMetadata(
            0,
            gasLimit,
            address(this),
            ""
        );
        originRouter.enrollRemoteRouterAndIsm(
            destination,
            routerOverride,
            ismOverride
        );
        uint256 balanceBefore = address(this).balance;

        // act
        originRouter.callRemote{value: gasLimit * igp.gasPrice() + overpayment}(
            destination,
            getCalls(data),
            metadata
        );

        // assert
        uint256 balanceAfter = address(this).balance;
        assertRemoteCallReceived(data);
        assertIgpPayment(balanceBefore, balanceAfter, gasLimit);
    }

    function testFuzz_customMetadata_reverts_underpayment(
        uint64 gasLimit,
        uint64 payment,
        bytes32 data
    ) public {
        vm.assume(payment < gasLimit * igp.gasPrice());
        // arrange
        bytes memory metadata = StandardHookMetadata.formatMetadata(
            0,
            gasLimit,
            address(this),
            ""
        );
        originRouter.enrollRemoteRouterAndIsm(
            destination,
            routerOverride,
            ismOverride
        );

        // act
        vm.expectRevert("IGP: insufficient interchain gas payment");
        originRouter.callRemote{value: payment}(
            destination,
            getCalls(data),
            metadata
        );
    }

    function testFuzz_callRemoteWithOverrides_default(bytes32 data) public {
        // arrange
        uint256 balanceBefore = address(this).balance;

        // act
        originRouter.callRemoteWithOverrides{value: gasPaymentQuote}(
            destination,
            routerOverride,
            ismOverride,
            getCalls(data)
        );

        // assert
        uint256 balanceAfter = address(this).balance;
        assertRemoteCallReceived(data);
        assertIgpPayment(balanceBefore, balanceAfter, igp.getDefaultGasUsage());
    }

    function testFuzz_callRemoteWithOverrides_metadata(
        uint64 gasLimit,
        bytes32 data
    ) public {
        // arrange
        bytes memory metadata = StandardHookMetadata.formatMetadata(
            0,
            gasLimit,
            address(this),
            ""
        );
        uint256 balanceBefore = address(this).balance;

        // act
        originRouter.callRemoteWithOverrides{value: gasLimit * igp.gasPrice()}(
            destination,
            routerOverride,
            ismOverride,
            getCalls(data),
            metadata
        );

        // assert
        uint256 balanceAfter = address(this).balance;
        assertRemoteCallReceived(data);
        assertIgpPayment(balanceBefore, balanceAfter, gasLimit);
    }

    function testFuzz_callRemoteWithFailingIsmOverride(bytes32 data) public {
        // arrange
        string memory failureMessage = "failing ism";
        bytes32 failingIsm = TypeCasts.addressToBytes32(
            address(new FailingIsm(failureMessage))
        );

        // act
        originRouter.callRemoteWithOverrides{value: gasPaymentQuote}(
            destination,
            routerOverride,
            failingIsm,
            getCalls(data),
            ""
        );

        // assert
        vm.expectRevert(bytes(failureMessage));
        environment.processNextPendingMessage();
    }

    function testFuzz_callRemoteWithFailingDefaultIsm(bytes32 data) public {
        // arrange
        string memory failureMessage = "failing ism";
        FailingIsm failingIsm = new FailingIsm(failureMessage);

        // act
        environment.mailboxes(destination).setDefaultIsm(address(failingIsm));
        originRouter.callRemoteWithOverrides{value: gasPaymentQuote}(
            destination,
            routerOverride,
            bytes32(0),
            getCalls(data),
            ""
        );

        // assert
        vm.expectRevert(bytes(failureMessage));
        environment.processNextPendingMessage();
    }

    function testFuzz_getLocalInterchainAccount(bytes32 data) public {
        // check
        OwnableMulticall destinationIca = destinationRouter
            .getLocalInterchainAccount(
                origin,
                address(this),
                address(originRouter),
                address(environment.isms(destination))
            );
        assertEq(
            address(destinationIca),
            address(
                destinationRouter.getLocalInterchainAccount(
                    origin,
                    TypeCasts.addressToBytes32(address(this)),
                    TypeCasts.addressToBytes32(address(originRouter)),
                    address(environment.isms(destination))
                )
            )
        );
        assertEq(address(destinationIca).code.length, 0);

        // act
        originRouter.callRemoteWithOverrides{value: gasPaymentQuote}(
            destination,
            routerOverride,
            ismOverride,
            getCalls(data),
            ""
        );

        // recheck
        assertRemoteCallReceived(data);
        assert(address(destinationIca).code.length != 0);
    }

    function testFuzz_receiveValue(uint256 value) public {
        vm.assume(value > 1 && value <= address(this).balance);
        // receive value before deployed
        assert(address(ica).code.length == 0);
        bool success;
        (success, ) = address(ica).call{value: value / 2}("");
        require(success, "transfer before deploy failed");

        // receive value after deployed
        destinationRouter.getDeployedInterchainAccount(
            origin,
            address(this),
            address(originRouter),
            address(environment.isms(destination))
        );
        assert(address(ica).code.length > 0);

        (success, ) = address(ica).call{value: value / 2}("");
        require(success, "transfer after deploy failed");
    }

    function receiveValue(uint256 value) external payable {
        assertEq(value, msg.value);
    }

    function testFuzz_sendValue(uint256 value) public {
        vm.assume(
            value > 0 && value <= address(this).balance - gasPaymentQuote
        );
        payable(address(ica)).transfer(value);

        bytes memory data = abi.encodeCall(this.receiveValue, (value));
        CallLib.Call memory call = CallLib.build(address(this), value, data);
        CallLib.Call[] memory calls = new CallLib.Call[](1);
        calls[0] = call;

        originRouter.callRemoteWithOverrides{value: gasPaymentQuote}(
            destination,
            routerOverride,
            ismOverride,
            calls,
            ""
        );
        vm.expectCall(address(this), value, data);
        environment.processNextPendingMessage();
    }

    receive() external payable {}
}
