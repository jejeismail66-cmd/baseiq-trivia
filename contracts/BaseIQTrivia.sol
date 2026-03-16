// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BaseIQTrivia {

    uint256 public constant PROTOCOL_FEE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR   = 10000;
    uint256 public constant MAX_PLAYERS       = 50;
    uint256 public constant MIN_PLAYERS       = 2;
    uint256 public constant MAX_QUESTIONS     = 20;
    uint256 public constant PRIZE_SPLIT_1ST = 50;
    uint256 public constant PRIZE_SPLIT_2ND = 30;
    uint256 public constant PRIZE_SPLIT_3RD = 20;

    address public owner;
    address public gameServer;

    enum RoundStatus { Open, InProgress, Ended, Cancelled }
    enum PaymentToken { ETH, USDC }

    struct PlayerResult {
        address player;
        uint256 score;
        uint256 prize;
        bool    claimed;
    }

    struct Round {
        uint256      id;
        string       name;
        RoundStatus  status;
        PaymentToken token;
        address      usdcAddress;
        uint256      entryFee;
        uint256      prizePool;
        uint256      maxPlayers;
        uint256      questionCount;
        uint256      startTime;
        uint256      endTime;
        address[]    players;
        mapping(address => bool)    hasJoined;
        mapping(address => uint256) playerIndex;
        PlayerResult[]              results;
    }

    uint256 public roundCount;
    mapping(uint256 => Round) private rounds;
    bool public paused;

    event RoundCreated(uint256 indexed roundId, string name, uint256 entryFee, uint256 maxPlayers, PaymentToken token);
    event PlayerJoined(uint256 indexed roundId, address indexed player, uint256 entryFee);
    event RoundStarted(uint256 indexed roundId, uint256 timestamp);
    event ScoresSubmitted(uint256 indexed roundId, address[3] winners, uint256[3] prizes);
    event PrizeClaimed(uint256 indexed roundId, address indexed player, uint256 amount);
    event RoundCancelled(uint256 indexed roundId);
    event RefundIssued(uint256 indexed roundId, address indexed player, uint256 amount);
    event OwnershipTransferred(address indexed previous, address indexed next);
    event GameServerUpdated(address indexed previous, address indexed next);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }
    modifier onlyGameServer() { require(msg.sender == gameServer || msg.sender == owner, "Not game server"); _; }
    modifier notPaused() { require(!paused, "Contract paused"); _; }
    modifier validRound(uint256 roundId) { require(roundId > 0 && roundId <= roundCount, "Invalid round"); _; }

    constructor(address _gameServer) {
        owner      = msg.sender;
        gameServer = _gameServer;
    }

    function createRoundETH(
        string  calldata name,
        uint256 entryFee,
        uint256 _maxPlayers,
        uint256 questionCount
    ) external onlyOwner notPaused returns (uint256 roundId) {
        _validateRoundParams(entryFee, _maxPlayers, questionCount);
        roundId = ++roundCount;
        Round storage r = rounds[roundId];
        r.id            = roundId;
        r.name          = name;
        r.status        = RoundStatus.Open;
        r.token         = PaymentToken.ETH;
        r.entryFee      = entryFee;
        r.maxPlayers    = _maxPlayers;
        r.questionCount = questionCount;
        emit RoundCreated(roundId, name, entryFee, _maxPlayers, PaymentToken.ETH);
    }

    function createRoundUSDC(
        string  calldata name,
        uint256 entryFee,
        uint256 _maxPlayers,
        uint256 questionCount,
        address usdcAddress
    ) external onlyOwner notPaused returns (uint256 roundId) {
        _validateRoundParams(entryFee, _maxPlayers, questionCount);
        require(usdcAddress != address(0), "Invalid USDC address");
        roundId = ++roundCount;
        Round storage r = rounds[roundId];
        r.id            = roundId;
        r.name          = name;
        r.status        = RoundStatus.Open;
        r.token         = PaymentToken.USDC;
        r.usdcAddress   = usdcAddress;
        r.entryFee      = entryFee;
        r.maxPlayers    = _maxPlayers;
        r.questionCount = questionCount;
        emit RoundCreated(roundId, name, entryFee, _maxPlayers, PaymentToken.USDC);
    }

    function startRound(uint256 roundId) external onlyGameServer validRound(roundId) {
        Round storage r = rounds[roundId];
        require(r.status == RoundStatus.Open, "Round not open");
        require(r.players.length >= MIN_PLAYERS, "Not enough players");
        r.status    = RoundStatus.InProgress;
        r.startTime = block.timestamp;
        emit RoundStarted(roundId, block.timestamp);
    }

    function joinRoundETH(uint256 roundId) external payable validRound(roundId) notPaused {
        Round storage r = rounds[roundId];
        require(r.token   == PaymentToken.ETH,  "Use joinRoundUSDC");
        require(r.status  == RoundStatus.Open,  "Round not open");
        require(!r.hasJoined[msg.sender],        "Already joined");
        require(r.players.length < r.maxPlayers, "Round full");
        require(msg.value == r.entryFee,         "Wrong entry fee");
        _addPlayer(r, msg.sender);
        r.prizePool += msg.value;
        emit PlayerJoined(roundId, msg.sender, msg.value);
    }

    function joinRoundUSDC(uint256 roundId) external validRound(roundId) notPaused {
        Round storage r = rounds[roundId];
        require(r.token   == PaymentToken.USDC, "Use joinRoundETH");
        require(r.status  == RoundStatus.Open,  "Round not open");
        require(!r.hasJoined[msg.sender],        "Already joined");
        require(r.players.length < r.maxPlayers, "Round full");
        bool ok = IERC20(r.usdcAddress).transferFrom(msg.sender, address(this), r.entryFee);
        require(ok, "USDC transfer failed");
        _addPlayer(r, msg.sender);
        r.prizePool += r.entryFee;
        emit PlayerJoined(roundId, msg.sender, r.entryFee);
    }

    function submitScores(
        uint256           roundId,
        address[] calldata players,
        uint256[] calldata scores
    ) external onlyGameServer validRound(roundId) {
        Round storage r = rounds[roundId];
        require(r.status == RoundStatus.InProgress, "Round not in progress");
        require(players.length == r.players.length,  "Player count mismatch");
        require(players.length == scores.length,     "Array length mismatch");

        for (uint256 i = 0; i < players.length; i++) {
            require(r.hasJoined[players[i]], "Unknown player");
            uint256 idx = r.playerIndex[players[i]];
            r.results[idx].score = scores[i];
        }

        (uint256 idx1, uint256 idx2, uint256 idx3) = _top3Indices(r.results);

        uint256 pool          = r.prizePool;
        uint256 protocolFee   = (pool * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 distributable = pool - protocolFee;

        uint256 prize1 = (distributable * PRIZE_SPLIT_1ST) / 100;
        uint256 prize2 = (distributable * PRIZE_SPLIT_2ND) / 100;
        uint256 prize3 = distributable - prize1 - prize2;

        uint256 playerCount = r.results.length;
        if (playerCount >= 1) r.results[idx1].prize = prize1;
        if (playerCount >= 2) r.results[idx2].prize = prize2;
        if (playerCount >= 3) r.results[idx3].prize = prize3;

        r.status  = RoundStatus.Ended;
        r.endTime = block.timestamp;

        _transferOut(r.token, r.usdcAddress, owner, protocolFee);

        address[3] memory winners;
        uint256[3] memory prizes;
        if (playerCount >= 1) { winners[0] = r.results[idx1].player; prizes[0] = prize1; }
        if (playerCount >= 2) { winners[1] = r.results[idx2].player; prizes[1] = prize2; }
        if (playerCount >= 3) { winners[2] = r.results[idx3].player; prizes[2] = prize3; }
        emit ScoresSubmitted(roundId, winners, prizes);
    }

    function claimPrize(uint256 roundId) external validRound(roundId) {
        Round storage r = rounds[roundId];
        require(r.status == RoundStatus.Ended, "Round not ended");
        require(r.hasJoined[msg.sender],        "Not a player");
        uint256 idx = r.playerIndex[msg.sender];
        PlayerResult storage result = r.results[idx];
        require(result.prize > 0,   "No prize to claim");
        require(!result.claimed,    "Already claimed");
        result.claimed = true;
        _transferOut(r.token, r.usdcAddress, msg.sender, result.prize);
        emit PrizeClaimed(roundId, msg.sender, result.prize);
    }

    function cancelRound(uint256 roundId) external onlyOwner validRound(roundId) {
        Round storage r = rounds[roundId];
        require(r.status == RoundStatus.Open || r.status == RoundStatus.InProgress, "Cannot cancel ended round");
        r.status = RoundStatus.Cancelled;
        emit RoundCancelled(roundId);
        for (uint256 i = 0; i < r.results.length; i++) {
            PlayerResult storage pr = r.results[i];
            if (!pr.claimed) {
                pr.claimed = true;
                _transferOut(r.token, r.usdcAddress, pr.player, r.entryFee);
                emit RefundIssued(roundId, pr.player, r.entryFee);
            }
        }
    }

    function getRoundInfo(uint256 roundId) external view validRound(roundId) returns (
        string memory name, RoundStatus status, PaymentToken token,
        uint256 entryFee, uint256 prizePool, uint256 playerCount,
        uint256 maxPlayers, uint256 questionCount, uint256 startTime, uint256 endTime
    ) {
        Round storage r = rounds[roundId];
        return (r.name, r.status, r.token, r.entryFee, r.prizePool,
                r.players.length, r.maxPlayers, r.questionCount, r.startTime, r.endTime);
    }

    function getPlayers(uint256 roundId) external view validRound(roundId) returns (address[] memory) {
        return rounds[roundId].players;
    }

    function getPlayerResult(uint256 roundId, address player) external view validRound(roundId)
        returns (uint256 score, uint256 prize, bool claimed) {
        Round storage r = rounds[roundId];
        require(r.hasJoined[player], "Player not in round");
        uint256 idx = r.playerIndex[player];
        PlayerResult storage pr = r.results[idx];
        return (pr.score, pr.prize, pr.claimed);
    }

    function getLeaderboard(uint256 roundId) external view validRound(roundId) returns (
        address[] memory playerAddrs, uint256[] memory playerScores, uint256[] memory playerPrizes
    ) {
        Round storage r = rounds[roundId];
        uint256 len = r.results.length;
        playerAddrs  = new address[](len);
        playerScores = new uint256[](len);
        playerPrizes = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            playerAddrs[i]  = r.results[i].player;
            playerScores[i] = r.results[i].score;
            playerPrizes[i] = r.results[i].prize;
        }
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = 0; j < len - i - 1; j++) {
                if (playerScores[j] < playerScores[j + 1]) {
                    (playerScores[j], playerScores[j+1]) = (playerScores[j+1], playerScores[j]);
                    (playerAddrs[j],  playerAddrs[j+1])  = (playerAddrs[j+1],  playerAddrs[j]);
                    (playerPrizes[j], playerPrizes[j+1]) = (playerPrizes[j+1], playerPrizes[j]);
                }
            }
        }
    }

    function hasJoined(uint256 roundId, address player) external view validRound(roundId) returns (bool) {
        return rounds[roundId].hasJoined[player];
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setGameServer(address newServer) external onlyOwner {
        require(newServer != address(0), "Zero address");
        emit GameServerUpdated(gameServer, newServer);
        gameServer = newServer;
    }

    function setPaused(bool _paused) external onlyOwner { paused = _paused; }

    function emergencyWithdrawETH() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    function emergencyWithdrawERC20(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(owner, bal);
    }

    function _addPlayer(Round storage r, address player) internal {
        r.hasJoined[player]   = true;
        r.playerIndex[player] = r.results.length;
        r.players.push(player);
        r.results.push(PlayerResult({ player: player, score: 0, prize: 0, claimed: false }));
    }

    function _validateRoundParams(uint256 entryFee, uint256 _maxPlayers, uint256 questionCount) internal pure {
        require(entryFee      > 0,             "Entry fee must be > 0");
        require(_maxPlayers  >= MIN_PLAYERS,   "Too few max players");
        require(_maxPlayers  <= MAX_PLAYERS,   "Too many max players");
        require(questionCount >= 1,            "Need at least 1 question");
        require(questionCount <= MAX_QUESTIONS,"Too many questions");
    }

    function _top3Indices(PlayerResult[] storage results) internal view
        returns (uint256 idx1, uint256 idx2, uint256 idx3) {
        uint256 len = results.length;
        idx1 = 0; idx2 = 0; idx3 = 0;
        if (len == 0) return (0, 0, 0);
        uint256 score1 = 0; uint256 score2 = 0; uint256 score3 = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 s = results[i].score;
            if (s > score1) {
                score3 = score2; idx3 = idx2;
                score2 = score1; idx2 = idx1;
                score1 = s;      idx1 = i;
            } else if (s > score2) {
                score3 = score2; idx3 = idx2;
                score2 = s;      idx2 = i;
            } else if (s > score3) {
                score3 = s; idx3 = i;
            }
        }
    }

    function _transferOut(PaymentToken token, address usdcAddress, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == PaymentToken.ETH) {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            bool ok = IERC20(usdcAddress).transfer(to, amount);
            require(ok, "USDC transfer failed");
        }
    }

    receive() external payable {}
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
