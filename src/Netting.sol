// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { NetPosition } from "./Types.sol";
import { ISettlement } from "./interfaces/ISettlement.sol";

/// @title NettedX Netting
/// @notice Windowed multilateral netting for one cash token and one bond token.
/// @dev Trades are matched off-chain. This contract aggregates obligations, publishes final
///      net positions, excludes short participants iteratively, and delegates atomic delivery
///      to an immutable Settlement contract.
contract Netting is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant MATCHER_ROLE = keccak256("MATCHER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint64 public constant DEFAULT_WINDOW_LENGTH = 10;
    uint64 public constant PREPARATION_BLOCKS = 2;
    uint64 public constant MIN_WINDOW_LENGTH = 2;
    uint64 public constant MAX_WINDOW_LENGTH = 100_000;

    uint16 public constant MAX_PARTICIPANTS = 50;
    uint16 public constant MAX_EDGES = 256;
    uint8 public constant MAX_EXCLUSION_ROUNDS = 10;

    enum WindowStatus {
        None,
        Open,
        Frozen,
        Settled
    }

    struct Window {
        uint64 startBlock;
        uint64 closeEligibleBlock;
        uint64 settleEligibleBlock;
        uint64 windowLength;
        uint32 tradeCount;
        uint16 participantCount;
        uint16 edgeCount;
        WindowStatus status;
    }

    /// @dev Positive amount means party0 pays party1; negative means party1 pays party0.
    struct BilateralEdge {
        address party0;
        address party1;
        address asset;
        int256 amount;
    }

    error ZeroAddress();
    error IdenticalParticipants();
    error IdenticalAssets();
    error InvalidAmount();
    error InvalidWindowLength(uint64 supplied);
    error WrongWindowStatus(uint256 windowId, WindowStatus expected, WindowStatus actual);
    error WindowStillOpen(uint256 currentBlock, uint256 closeEligibleBlock);
    error WindowExpired(uint256 currentBlock, uint256 closeEligibleBlock);
    error PreparationPeriodActive(uint256 currentBlock, uint256 settleEligibleBlock);
    error ParticipantLimitExceeded(uint256 windowId);
    error EdgeLimitExceeded(uint256 windowId);
    error ExclusionRoundLimitExceeded(uint256 windowId);
    error NettingInvariantBroken(uint256 windowId, address asset, int256 sum);

    event TradeSubmitted(
        uint256 indexed windowId,
        uint256 indexed tradeId,
        address indexed buyer,
        address seller,
        uint256 cashAmount,
        uint256 bondAmount
    );
    event WindowClosed(
        uint256 indexed windowId,
        uint256 tradeCount,
        uint256 startBlock,
        uint256 closeBlock,
        uint256 settleEligibleBlock
    );
    event NetPositionPublished(
        uint256 indexed windowId, address indexed participant, address indexed asset, int256 amount
    );
    event ParticipantExcluded(
        uint256 indexed windowId,
        address indexed participant,
        uint256 cashRequired,
        uint256 bondRequired,
        uint8 round
    );
    event WindowSettled(
        uint256 indexed windowId,
        uint256 positionCount,
        uint256 excludedCount,
        uint8 exclusionRounds,
        uint256 indexed nextWindowId
    );
    event SettlementFailed(uint256 indexed windowId, bytes reason);
    event NextWindowLengthScheduled(uint64 previousLength, uint64 nextLength);

    IERC20 public immutable cashToken;
    IERC20 public immutable bondToken;
    ISettlement public immutable settlement;

    uint256 public currentWindowId;
    uint64 public scheduledWindowLength;

    mapping(uint256 windowId => Window) public windows;
    mapping(uint256 windowId => address[]) private _participants;
    mapping(uint256 windowId => mapping(address participant => uint256 indexPlusOne)) private
        _participantIndexPlusOne;
    mapping(uint256 windowId => BilateralEdge[]) private _edges;
    mapping(uint256 windowId => mapping(bytes32 edgeKey => uint256 indexPlusOne)) private
        _edgeIndexPlusOne;
    mapping(
        uint256 windowId => mapping(address participant => mapping(address asset => int256 amount))
    ) private _previewNet;

    constructor(
        address admin,
        address matcher,
        address operator,
        address cashToken_,
        address bondToken_,
        address settlement_
    ) {
        if (
            admin == address(0) || matcher == address(0) || operator == address(0)
                || cashToken_ == address(0) || bondToken_ == address(0) || settlement_ == address(0)
        ) revert ZeroAddress();
        if (cashToken_ == bondToken_) revert IdenticalAssets();

        cashToken = IERC20(cashToken_);
        bondToken = IERC20(bondToken_);
        settlement = ISettlement(settlement_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MATCHER_ROLE, matcher);
        _grantRole(OPERATOR_ROLE, operator);

        currentWindowId = 1;
        _initializeWindow(1, DEFAULT_WINDOW_LENGTH);
    }

    /// @notice Records a previously matched cash-versus-bond trade without moving assets.
    function submitTrade(address buyer, address seller, uint256 cashAmount, uint256 bondAmount)
        external
        onlyRole(MATCHER_ROLE)
        whenNotPaused
    {
        uint256 windowId = currentWindowId;
        Window storage window = windows[windowId];
        if (window.status != WindowStatus.Open) {
            revert WrongWindowStatus(windowId, WindowStatus.Open, window.status);
        }
        if (block.number >= window.closeEligibleBlock) {
            revert WindowExpired(block.number, window.closeEligibleBlock);
        }
        if (buyer == address(0) || seller == address(0)) revert ZeroAddress();
        if (buyer == seller) revert IdenticalParticipants();
        if (
            cashAmount == 0 || bondAmount == 0 || cashAmount > uint256(type(int256).max)
                || bondAmount > uint256(type(int256).max)
        ) revert InvalidAmount();

        _ensureParticipant(windowId, buyer);
        _ensureParticipant(windowId, seller);

        // Buyer pays cash to seller; seller delivers bonds to buyer.
        _addObligation(windowId, buyer, seller, address(cashToken), cashAmount);
        _addObligation(windowId, seller, buyer, address(bondToken), bondAmount);

        uint256 tradeId = ++window.tradeCount;
        emit TradeSubmitted(windowId, tradeId, buyer, seller, cashAmount, bondAmount);
    }

    /// @notice Freezes the current window and publishes its deterministic final net positions.
    function closeWindow() external onlyRole(OPERATOR_ROLE) whenNotPaused {
        uint256 windowId = currentWindowId;
        Window storage window = windows[windowId];
        if (window.status != WindowStatus.Open) {
            revert WrongWindowStatus(windowId, WindowStatus.Open, window.status);
        }
        if (block.number < window.closeEligibleBlock) {
            revert WindowStillOpen(block.number, window.closeEligibleBlock);
        }

        window.status = WindowStatus.Frozen;
        window.settleEligibleBlock = _toUint64(block.number + PREPARATION_BLOCKS);

        address[] storage participants = _participants[windowId];
        for (uint256 i; i < participants.length; ++i) {
            address participant = participants[i];
            int256 cash = _previewNet[windowId][participant][address(cashToken)];
            int256 bond = _previewNet[windowId][participant][address(bondToken)];
            if (cash != 0) {
                emit NetPositionPublished(windowId, participant, address(cashToken), cash);
            }
            if (bond != 0) {
                emit NetPositionPublished(windowId, participant, address(bondToken), bond);
            }
        }

        emit WindowClosed(
            windowId, window.tradeCount, window.startBlock, block.number, window.settleEligibleBlock
        );
    }

    /// @notice Excludes short participants until the surviving set is feasible, then settles it.
    /// @return success False only when the external Settlement contract reverts; the frozen window
    ///         remains retryable and SettlementFailed records the revert payload.
    function settleWindow()
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (bool success)
    {
        uint256 windowId = currentWindowId;
        Window storage window = windows[windowId];
        if (window.status != WindowStatus.Frozen) {
            revert WrongWindowStatus(windowId, WindowStatus.Frozen, window.status);
        }
        if (block.number < window.settleEligibleBlock) {
            revert PreparationPeriodActive(block.number, window.settleEligibleBlock);
        }

        uint256 participantCount = _participants[windowId].length;
        bool[] memory active = new bool[](participantCount);
        uint8[] memory excludedAtRound = new uint8[](participantCount);
        uint256[] memory cashRequiredAtExclusion = new uint256[](participantCount);
        uint256[] memory bondRequiredAtExclusion = new uint256[](participantCount);
        for (uint256 i; i < participantCount; ++i) {
            active[i] = true;
        }

        uint8 rounds;
        int256[] memory cashNet;
        int256[] memory bondNet;

        while (true) {
            (cashNet, bondNet) = _computeNet(windowId, active);
            bool[] memory shouldExclude = new bool[](participantCount);
            uint256 shortParticipantCount;

            for (uint256 i; i < participantCount; ++i) {
                if (!active[i]) continue;
                address participant = _participants[windowId][i];
                bool cashShort = _isShort(participant, cashToken, cashNet[i]);
                bool bondShort = _isShort(participant, bondToken, bondNet[i]);
                if (cashShort || bondShort) {
                    shouldExclude[i] = true;
                    ++shortParticipantCount;
                }
            }

            if (shortParticipantCount == 0) break;
            if (rounds >= MAX_EXCLUSION_ROUNDS) {
                revert ExclusionRoundLimitExceeded(windowId);
            }

            ++rounds;
            for (uint256 i; i < participantCount; ++i) {
                if (!shouldExclude[i]) continue;
                active[i] = false;
                excludedAtRound[i] = rounds;
                if (cashNet[i] < 0) cashRequiredAtExclusion[i] = _absolute(cashNet[i]);
                if (bondNet[i] < 0) bondRequiredAtExclusion[i] = _absolute(bondNet[i]);
            }
        }

        NetPosition[] memory positions = _buildPositions(windowId, active, cashNet, bondNet);

        if (positions.length == 0) {
            _completeWindow(
                windowId,
                active,
                excludedAtRound,
                cashRequiredAtExclusion,
                bondRequiredAtExclusion,
                rounds,
                0
            );
            return true;
        }

        try settlement.settle(windowId, positions) {
            _completeWindow(
                windowId,
                active,
                excludedAtRound,
                cashRequiredAtExclusion,
                bondRequiredAtExclusion,
                rounds,
                positions.length
            );
            return true;
        } catch (bytes memory reason) {
            emit SettlementFailed(windowId, reason);
            return false;
        }
    }

    /// @notice Schedules a length that is applied only when the next window is created.
    function setNextWindowLength(uint64 nextLength) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nextLength < MIN_WINDOW_LENGTH || nextLength > MAX_WINDOW_LENGTH) {
            revert InvalidWindowLength(nextLength);
        }
        uint64 previous = scheduledWindowLength;
        scheduledWindowLength = nextLength;
        emit NextWindowLengthScheduled(previous, nextLength);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function currentWindowStartBlock() external view returns (uint256) {
        return windows[currentWindowId].startBlock;
    }

    function closeEligibleBlock() external view returns (uint256) {
        return windows[currentWindowId].closeEligibleBlock;
    }

    function settleEligibleBlock(uint256 windowId) external view returns (uint256) {
        return windows[windowId].settleEligibleBlock;
    }

    function blocksRemaining() external view returns (uint256) {
        Window storage window = windows[currentWindowId];
        if (window.status != WindowStatus.Open || block.number >= window.closeEligibleBlock) {
            return 0;
        }
        return window.closeEligibleBlock - block.number;
    }

    function windowStatus(uint256 windowId) external view returns (WindowStatus) {
        return windows[windowId].status;
    }

    function getParticipants(uint256 windowId) external view returns (address[] memory) {
        return _participants[windowId];
    }

    function getEdges(uint256 windowId) external view returns (BilateralEdge[] memory) {
        return _edges[windowId];
    }

    function getNetPosition(uint256 windowId, address participant, address asset)
        external
        view
        returns (int256)
    {
        return _previewNet[windowId][participant][asset];
    }

    function previewNetPositions(uint256 windowId)
        public
        view
        returns (NetPosition[] memory positions)
    {
        address[] storage participants = _participants[windowId];
        uint256 count;
        for (uint256 i; i < participants.length; ++i) {
            if (_previewNet[windowId][participants[i]][address(cashToken)] != 0) ++count;
            if (_previewNet[windowId][participants[i]][address(bondToken)] != 0) ++count;
        }

        positions = new NetPosition[](count);
        uint256 cursor;
        for (uint256 i; i < participants.length; ++i) {
            address participant = participants[i];
            int256 cash = _previewNet[windowId][participant][address(cashToken)];
            int256 bond = _previewNet[windowId][participant][address(bondToken)];
            if (cash != 0) {
                positions[cursor++] = NetPosition(participant, address(cashToken), cash);
            }
            if (bond != 0) {
                positions[cursor++] = NetPosition(participant, address(bondToken), bond);
            }
        }
    }

    /// @notice Returns payable positions whose current balance or allowance is insufficient.
    function checkShortfalls(uint256 windowId)
        external
        view
        returns (NetPosition[] memory shortfalls)
    {
        address[] storage participants = _participants[windowId];
        uint256 count;
        for (uint256 i; i < participants.length; ++i) {
            address participant = participants[i];
            int256 cash = _previewNet[windowId][participant][address(cashToken)];
            int256 bond = _previewNet[windowId][participant][address(bondToken)];
            if (_isShort(participant, cashToken, cash)) ++count;
            if (_isShort(participant, bondToken, bond)) ++count;
        }

        shortfalls = new NetPosition[](count);
        uint256 cursor;
        for (uint256 i; i < participants.length; ++i) {
            address participant = participants[i];
            int256 cash = _previewNet[windowId][participant][address(cashToken)];
            int256 bond = _previewNet[windowId][participant][address(bondToken)];
            if (_isShort(participant, cashToken, cash)) {
                shortfalls[cursor++] = NetPosition(participant, address(cashToken), cash);
            }
            if (_isShort(participant, bondToken, bond)) {
                shortfalls[cursor++] = NetPosition(participant, address(bondToken), bond);
            }
        }
    }

    function _initializeWindow(uint256 windowId, uint64 length) private {
        uint64 start = _toUint64(block.number);
        windows[windowId] = Window({
            startBlock: start,
            closeEligibleBlock: _toUint64(block.number + length),
            settleEligibleBlock: 0,
            windowLength: length,
            tradeCount: 0,
            participantCount: 0,
            edgeCount: 0,
            status: WindowStatus.Open
        });
    }

    function _ensureParticipant(uint256 windowId, address participant) private {
        if (_participantIndexPlusOne[windowId][participant] != 0) return;
        if (_participants[windowId].length >= MAX_PARTICIPANTS) {
            revert ParticipantLimitExceeded(windowId);
        }
        _participants[windowId].push(participant);
        _participantIndexPlusOne[windowId][participant] = _participants[windowId].length;
        windows[windowId].participantCount = uint16(_participants[windowId].length);
    }

    function _addObligation(
        uint256 windowId,
        address payer,
        address receiver,
        address asset,
        uint256 amount
    ) private {
        (address party0, address party1) = payer < receiver ? (payer, receiver) : (receiver, payer);
        bytes32 key = keccak256(abi.encode(asset, party0, party1));
        uint256 indexPlusOne = _edgeIndexPlusOne[windowId][key];
        // submitTrade bounds every amount to type(int256).max before this conversion.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountAsInt = int256(amount);
        int256 signedAmount = payer == party0 ? amountAsInt : -amountAsInt;

        if (indexPlusOne == 0) {
            if (_edges[windowId].length >= MAX_EDGES) revert EdgeLimitExceeded(windowId);
            _edges[windowId].push(BilateralEdge(party0, party1, asset, signedAmount));
            _edgeIndexPlusOne[windowId][key] = _edges[windowId].length;
            windows[windowId].edgeCount = uint16(_edges[windowId].length);
        } else {
            BilateralEdge storage edge = _edges[windowId][indexPlusOne - 1];
            int256 updated = edge.amount + signedAmount;
            if (updated == type(int256).min) revert InvalidAmount();
            edge.amount = updated;
        }

        int256 payerNet = _previewNet[windowId][payer][asset] - amountAsInt;
        int256 receiverNet = _previewNet[windowId][receiver][asset] + amountAsInt;
        if (payerNet == type(int256).min || receiverNet == type(int256).min) {
            revert InvalidAmount();
        }
        _previewNet[windowId][payer][asset] = payerNet;
        _previewNet[windowId][receiver][asset] = receiverNet;
    }

    function _computeNet(uint256 windowId, bool[] memory active)
        private
        view
        returns (int256[] memory cashNet, int256[] memory bondNet)
    {
        uint256 participantCount = _participants[windowId].length;
        cashNet = new int256[](participantCount);
        bondNet = new int256[](participantCount);
        BilateralEdge[] storage edges = _edges[windowId];

        for (uint256 i; i < edges.length; ++i) {
            BilateralEdge storage edge = edges[i];
            if (edge.amount == 0) continue;
            uint256 index0 = _participantIndexPlusOne[windowId][edge.party0] - 1;
            uint256 index1 = _participantIndexPlusOne[windowId][edge.party1] - 1;
            if (!active[index0] || !active[index1]) continue;

            int256[] memory target = edge.asset == address(cashToken) ? cashNet : bondNet;
            if (edge.amount > 0) {
                target[index0] -= edge.amount;
                target[index1] += edge.amount;
            } else {
                int256 amount = -edge.amount;
                target[index1] -= amount;
                target[index0] += amount;
            }
        }
    }

    function _buildPositions(
        uint256 windowId,
        bool[] memory active,
        int256[] memory cashNet,
        int256[] memory bondNet
    ) private view returns (NetPosition[] memory positions) {
        uint256 count;
        int256 cashSum;
        int256 bondSum;
        for (uint256 i; i < active.length; ++i) {
            if (!active[i]) continue;
            if (cashNet[i] != 0) {
                ++count;
                cashSum += cashNet[i];
            }
            if (bondNet[i] != 0) {
                ++count;
                bondSum += bondNet[i];
            }
        }
        if (cashSum != 0) {
            revert NettingInvariantBroken(windowId, address(cashToken), cashSum);
        }
        if (bondSum != 0) {
            revert NettingInvariantBroken(windowId, address(bondToken), bondSum);
        }

        positions = new NetPosition[](count);
        uint256 cursor;
        for (uint256 i; i < active.length; ++i) {
            if (!active[i]) continue;
            address participant = _participants[windowId][i];
            if (cashNet[i] != 0) {
                positions[cursor++] = NetPosition(participant, address(cashToken), cashNet[i]);
            }
            if (bondNet[i] != 0) {
                positions[cursor++] = NetPosition(participant, address(bondToken), bondNet[i]);
            }
        }
    }

    function _completeWindow(
        uint256 windowId,
        bool[] memory active,
        uint8[] memory excludedAtRound,
        uint256[] memory cashRequired,
        uint256[] memory bondRequired,
        uint8 rounds,
        uint256 positionCount
    ) private {
        Window storage completed = windows[windowId];
        completed.status = WindowStatus.Settled;

        uint64 nextLength =
            scheduledWindowLength == 0 ? completed.windowLength : scheduledWindowLength;
        scheduledWindowLength = 0;
        uint256 nextWindowId = windowId + 1;
        _initializeWindow(nextWindowId, nextLength);

        uint256 excludedCount =
            _emitExclusions(windowId, active, excludedAtRound, cashRequired, bondRequired);
        _rollExcludedEdges(windowId, nextWindowId, active);

        currentWindowId = nextWindowId;
        emit WindowSettled(windowId, positionCount, excludedCount, rounds, nextWindowId);
    }

    function _emitExclusions(
        uint256 windowId,
        bool[] memory active,
        uint8[] memory excludedAtRound,
        uint256[] memory cashRequired,
        uint256[] memory bondRequired
    ) private returns (uint256 excludedCount) {
        for (uint256 i; i < active.length; ++i) {
            if (active[i]) continue;
            ++excludedCount;
            emit ParticipantExcluded(
                windowId,
                _participants[windowId][i],
                cashRequired[i],
                bondRequired[i],
                excludedAtRound[i]
            );
        }
    }

    function _rollExcludedEdges(uint256 windowId, uint256 nextWindowId, bool[] memory active)
        private
    {
        BilateralEdge[] storage edges = _edges[windowId];
        for (uint256 i; i < edges.length; ++i) {
            BilateralEdge storage edge = edges[i];
            if (edge.amount == 0) continue;
            uint256 index0 = _participantIndexPlusOne[windowId][edge.party0] - 1;
            uint256 index1 = _participantIndexPlusOne[windowId][edge.party1] - 1;
            if (active[index0] && active[index1]) continue;

            _ensureParticipant(nextWindowId, edge.party0);
            _ensureParticipant(nextWindowId, edge.party1);
            if (edge.amount > 0) {
                _addObligation(
                    nextWindowId, edge.party0, edge.party1, edge.asset, uint256(edge.amount)
                );
            } else {
                _addObligation(
                    nextWindowId, edge.party1, edge.party0, edge.asset, _absolute(edge.amount)
                );
            }
        }
    }

    function _isShort(address participant, IERC20 token, int256 netAmount)
        private
        view
        returns (bool)
    {
        if (netAmount >= 0) return false;
        uint256 required = _absolute(netAmount);
        return token.balanceOf(participant) < required
            || token.allowance(participant, address(settlement)) < required;
    }

    function _absolute(int256 value) private pure returns (uint256) {
        // Adding before negation keeps type(int256).min representable.
        return uint256(-(value + 1)) + 1;
    }

    function _toUint64(uint256 value) private pure returns (uint64) {
        if (value > type(uint64).max) revert InvalidAmount();
        // The explicit upper-bound check makes this narrowing conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }
}
