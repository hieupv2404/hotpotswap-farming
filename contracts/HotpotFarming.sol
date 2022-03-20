// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./libs/TransferHelper.sol";
import "./HotpotToken.sol";

interface IMigratorFarm {
    // Take the current LP token addresss and return the new LP token address.
    // Migration should have full access to the caller's LP token.
    function migrate(IERC20 token) external returns (IERC20);
}

contract HotpotFarming is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    // Info of each user stake in farm.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 userRewardPerTokenPaid;
        uint256 rewards;
    }

    // Info of each farm.
    struct FarmInfo {
        address stakingToken; // Address of staking token contract.
        uint256 allocPoint; // How many allocation points assigned to this farm. HOTPOTs to distribute per block.
        uint256 lastRewardBlock; // Last block number that HOTPOTs distribution occurs.
        uint256 accHotpotPerShare; // Accumulated HOTPOTs per share, times 1e12. See below.
        IERC20 gift; // Address of gift token contract.
        uint256 scale;
        uint256 duration;
        address rewardDistribution;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    // The migrator contract. It has a lot of power.
    IMigratorFarm public migrator;

    // The HOTPOT TOKEN!
    HotpotToken public hotpot;
    // Dev address.
    address public devaddr;
    // HOTPOT tokens created per block.
    uint256 public hotpotPerBlock;

    // Info of each farm.
    FarmInfo[] public farmInfo;
    // Address of the staking token for each farm.
    address[] public stakingTokens;
    // Info of each user that stakes tokens in farm.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all farms.
    uint256 public totalAllocPoint;
    // The block number when HOTPOT mining starts.
    uint256 public startBlock;
    // Total staked of farm stake HOTPOT - earn HOTPOT.
    uint256 public totalHotpotStaked;


    /* ========== CONSTRUCTOR ========== */
    function initialize(
        HotpotToken _hotpot,
        address _devAddr,
        uint256 _hotpotPerBlock,
        uint256 _startBlock
    ) public initializer {
        __AccessControl_init_unchained();
        // set admin role
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        hotpot = _hotpot;
        devaddr = _devAddr;
        hotpotPerBlock = _hotpotPerBlock;
        startBlock = _startBlock;
    }

    /* ========== EVENTS ========== */
    event Staked(
        address indexed user,
        uint256 indexed fid,
        uint256 amount,
        uint256 hotpotAmount,
        uint256 rewardAmount
    );
    event Withdrawn(
        address indexed user,
        uint256 indexed fid,
        uint256 amount,
        uint256 hotpotAmount,
        uint256 rewardAmount
    );
    event ClaimOldHotpot(
        address indexed user,
        uint256 indexed fid,
        uint256 amount
    );
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed fid,
        uint256 amount
    );
    event LogFarmAddition(
        uint256 indexed fid,
        uint256 allocPoint,
        address indexed stakingToken,
        IERC20 indexed gift,
        uint256 duration,
        address rewardDistribution,
        uint256 scale
    );
    event LogSetFarm(uint256 indexed fid, uint256 allocPoint);
    event LogUpdateFarm(
        uint256 indexed fid,
        uint256 lastRewardBlock,
        uint256 lpSupply,
        uint256 accHotpotPerShare,
        uint256 rewardPerTokenStored,
        uint256 lastUpdateTime
    );
    event DurationUpdated(uint256 indexed fid, uint256 duration);
    event ScaleUpdated(uint256 indexed fid, uint256 scale);
    event GiftAdded(uint256 indexed fid, IERC20 indexed gift, uint256 amount);
    event RewardDistributionChanged(
        uint256 indexed fid,
        address indexed rewardDistribution
    );

    /* ========== MODIFIERS ========== */
    modifier restricted() {
        _restricted();
        _;
    }

    function _restricted() internal view {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not admin");
    }

    modifier onlyRewardDistribution(uint256 fid) {
        require(
            msg.sender == farmInfo[fid].rewardDistribution,
            "HotpotToken Farming: access denied"
        );
        _;
    }

    /* ========== VIEWS ========== */
    // Returns the number of farms.
    function farmLength() public view returns (uint256 farms) {
        farms = farmInfo.length;
    }


    /// @notice Return pending HOTPOT of an user in a farm.
    /// @param fid The index of the farm. See `farmInfo`.
    /// @param account Address of user.
    /// @return pending HOTPOT reward for a given user.
    function pendingHotpot(uint256 fid, address account)
        external
        view
        returns (uint256 pending)
    {
        FarmInfo memory farm = farmInfo[fid];
        UserInfo storage user = userInfo[fid][account];
        uint256 accHotpotPerShare = farm.accHotpotPerShare;
        uint256 stakingSupply = stakingTokens[fid] == address(hotpot)
            ? totalHotpotStaked
            : IERC20(stakingTokens[fid]).balanceOf(address(this));
        if (block.number > farm.lastRewardBlock && stakingSupply != 0) {
            uint256 blocks = block.number.sub(farm.lastRewardBlock);
            uint256 hotpotReward = blocks
                .mul(hotpotPerBlock)
                .mul(farm.allocPoint)
                .div(totalAllocPoint);
            accHotpotPerShare = accHotpotPerShare.add(
                hotpotReward.mul(1e12).div(stakingSupply)
            );
        }
        pending = user.amount.mul(accHotpotPerShare).div(1e12).sub(
            user.rewardDebt
        );
    }

    /// @notice Return pending gift of an user in a farm.
    /// @param fid The index of the farm. See `farmInfo`.
    /// @param account Address of user.
    /// @return pending gift reward for a given user.
    function pendingGift(uint256 fid, address account)
        public
        view
        returns (uint256 pending)
    {
        FarmInfo memory farm = farmInfo[fid];
        UserInfo storage user = userInfo[fid][account];
        pending = user
            .amount
            .mul(rewardPerToken(fid).sub(user.userRewardPerTokenPaid))
            .div(farm.scale)
            .div(1e18)
            .add(user.rewards);
    }

    /// @notice Return the last timestamp the farm has a gift was updated
    function lastTimeRewardApplicable(uint256 fid)
        public
        view
        returns (uint256)
    {
        return Math.min(block.timestamp, farmInfo[fid].periodFinish);
    }

    /// @notice Return rewardPerToken for farm has a gift. Else return 0
    function rewardPerToken(uint256 fid) public view returns (uint256) {
        FarmInfo storage farm = farmInfo[fid];
        uint256 stakingSupply = IERC20(stakingTokens[fid]).balanceOf(
            address(this)
        );
        if (stakingSupply == 0) {
            return farm.rewardPerTokenStored;
        }
        return
            farm.rewardPerTokenStored.add(
                lastTimeRewardApplicable(fid)
                    .sub(farm.lastUpdateTime)
                    .mul(farm.rewardRate)
                    .mul(1e18)
                    .div(stakingSupply)
            );
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    // Deposit ERC20 LP token/HOTPOT to HotpotToken Farming for HOTPOT (and Gift) allocation
    function stake(uint256 fid, uint256 amount) external nonReentrant {
        FarmInfo storage farm = farmInfo[fid];
        UserInfo storage user = userInfo[fid][msg.sender];

        updateFarm(fid, msg.sender);

        uint256 hotpotReward = 0;
        uint256 giftReward = 0;

        if (user.amount > 0) {
            hotpotReward = user.amount.mul(farm.accHotpotPerShare).div(1e12).sub(
                user.rewardDebt
            );
            giftReward = user.rewards;
            if (hotpotReward > 0) {
                safeHotpotTransfer(msg.sender, hotpotReward);
            }
            if (giftReward > 0) {
                user.rewards = 0;
                TransferHelper.safeTransfer(
                    address(farm.gift),
                    msg.sender,
                    giftReward
                );
            }
        }
        if (amount > 0) {
            TransferHelper.safeTransferFrom(
                stakingTokens[fid],
                address(msg.sender),
                address(this),
                amount
            );

            if (stakingTokens[fid] == address(hotpot)) {
                totalHotpotStaked = totalHotpotStaked.add(amount);
            }
            user.amount = user.amount.add(amount);
        }

        user.rewardDebt = user.amount.mul(farm.accHotpotPerShare).div(1e12);
        emit Staked(msg.sender, fid, amount, hotpotReward, giftReward);
    }

    // Withdraw ERC20 LP token/HOTPOT staked from MasterChef
    function withdraw(uint256 fid, uint256 amount) external nonReentrant {
        FarmInfo storage farm = farmInfo[fid];
        UserInfo storage user = userInfo[fid][msg.sender];
        require(
            user.amount >= amount,
            "HotpotToken Farming: amount not enough to withdraw"
        );

        updateFarm(fid, msg.sender);

        uint256 hotpotReward = user
            .amount
            .mul(farm.accHotpotPerShare)
            .div(1e12)
            .sub(user.rewardDebt);
        uint256 giftReward = user.rewards;
        if (hotpotReward > 0) {
            safeHotpotTransfer(msg.sender, hotpotReward);
        }
        if (giftReward > 0) {
            user.rewards = 0;
            TransferHelper.safeTransfer(
                address(farm.gift),
                msg.sender,
                giftReward
            );
        }

        if (amount > 0) {
            user.amount = user.amount.sub(amount);
            if (stakingTokens[fid] == address(hotpot)) {
                totalHotpotStaked = totalHotpotStaked.sub(amount);
            }
            TransferHelper.safeTransfer(
                stakingTokens[fid],
                address(msg.sender),
                amount
            );
        }
        user.rewardDebt = user.amount.mul(farm.accHotpotPerShare).div(1e12);
        emit Withdrawn(msg.sender, fid, amount, hotpotReward, giftReward);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    /// @notice Set the `migrator` contract. Can only be called by the owner.
    /// @param _migrator The contract address to set.
    function setMigrator(IMigratorFarm _migrator) public restricted {
        migrator = _migrator;
    }

    /// @notice Migrate LP token to another LP contract through the `migrator` contract.
    /// @notice ONLY FOR ERC20 LP Token!
    /// @param _fid The index of the farm. See `farmInfo`.
    function migrate(uint256 _fid) public {
        require(
            address(migrator) != address(0),
            "HotpotToken Farming: no migrator set"
        );
        IERC20 _lpToken = IERC20(stakingTokens[_fid]);
        uint256 bal = _lpToken.balanceOf(address(this));
        _lpToken.approve(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(_lpToken);
        require(
            bal == newLpToken.balanceOf(address(this)),
            "HotpotToken Farming: migrated balance must match"
        );
        stakingTokens[_fid] = address(newLpToken);
    }

    /// @notice Add a new Farm. Can only be called by the owner.
    /// DO NOT add the same Staking token more than once. Rewards will be messed up if you do.
    function addFarm(
        uint256 _allocPoint,
        address _stakingToken,
        IERC20 _gift,
        uint256 _duration,
        address _rewardDistribution,
        uint256 _scale,
        bool _withUpdate
    ) public restricted {
        if (_withUpdate) {
            massUpdateFarms();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        stakingTokens.push(_stakingToken);

        if (address(_gift) != address(0)) {
            require(_scale > 0, "HotpotToken Farming: scale is too low");
            require(_scale <= 1e36, "HotpotToken Farming: scale is too high");
            uint256 len = farmLength();
            for (uint256 i = 0; i < len; i++) {
                require(
                    address(_gift) != stakingTokens[i],
                    "HotpotToken Farming: gift is already added"
                );
            }
        }

        farmInfo.push(
            FarmInfo({
                stakingToken: _stakingToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accHotpotPerShare: 0,
                gift: _gift,
                scale: _scale,
                duration: _duration,
                rewardDistribution: _rewardDistribution,
                periodFinish: 0,
                rewardRate: 0,
                lastUpdateTime: 0,
                rewardPerTokenStored: 0
            })
        );

        emit LogFarmAddition(
            stakingTokens.length.sub(1),
            _allocPoint,
            _stakingToken,
            _gift,
            _duration,
            _rewardDistribution,
            _scale
        );
    }

    /// @notice Update the given farm's HOTPOT allocation point. Can only be called by the owner.
    /// @param fids The array of index of the farm. See `farmInfo`.
    /// @param allocPoints Array of New APs of the farm.
    function setFarmAllocations(
        uint256[] memory fids,
        uint256[] memory allocPoints,
        bool withUpdate
    ) public restricted {
        require(
            fids.length == allocPoints.length,
            "invalid fids/allocPoints length"
        );

        if (withUpdate) {
            massUpdateFarms();
        }

        for (uint256 i = 0; i < fids.length; i++) {
            uint256 prevAllocPoint = farmInfo[fids[i]].allocPoint;
            farmInfo[fids[i]].allocPoint = allocPoints[i];
            if (prevAllocPoint != allocPoints[i]) {
                totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(
                    allocPoints[i]
                );
            }
            emit LogSetFarm(fids[i], allocPoints[i]);
        }
    }

    /// @notice Update reward variables for all farms. Be careful of gas spending!
    function massUpdateFarms() public {
        uint256 len = farmInfo.length;
        for (uint256 fid = 0; fid < len; ++fid) {
            updateFarm(fid, address(0));
        }
    }

    /// @notice Update reward variables of the given farm.
    /// @param fid The index of the farm. See `farmInfo`.
    /// @param account The address is updating farm infor.
    function updateFarm(uint256 fid, address account) public {
        FarmInfo storage farm = farmInfo[fid];

        if (address(farm.gift) != address(0)) {
            uint256 newRewardPerToken = rewardPerToken(fid);
            farm.rewardPerTokenStored = newRewardPerToken;
            farm.lastUpdateTime = lastTimeRewardApplicable(fid);

            if (account != address(0)) {
                UserInfo storage user = userInfo[fid][msg.sender];

                user.rewards = pendingGift(fid, account);
                user.userRewardPerTokenPaid = newRewardPerToken;
            }
        }

        uint256 stakingSupply = stakingTokens[fid] == address(hotpot)
            ? totalHotpotStaked
            : IERC20(stakingTokens[fid]).balanceOf(address(this));
        if (block.number > farm.lastRewardBlock) {
            if (stakingSupply > 0) {
                uint256 blocks = block.number.sub(farm.lastRewardBlock);
                uint256 hotpotReward = blocks
                    .mul(hotpotPerBlock)
                    .mul(farm.allocPoint)
                    .div(totalAllocPoint);
                if (hotpotReward > 0) {
                    hotpot.mint(devaddr, hotpotReward.mul(15).div(100));
                    hotpot.mint(address(this), hotpotReward);
                }
                farm.accHotpotPerShare = farm.accHotpotPerShare.add(
                    hotpotReward.mul(1e12).div(stakingSupply)
                );
            }
            farm.lastRewardBlock = block.number;
        }
        emit LogUpdateFarm(
            fid,
            farm.lastRewardBlock,
            stakingSupply,
            farm.accHotpotPerShare,
            farm.rewardPerTokenStored,
            farm.lastUpdateTime
        );
    }

    function notifyRewardAmount(uint256 fid, uint256 reward)
        public
        onlyRewardDistribution(fid)
    {
        FarmInfo storage farm = farmInfo[fid];

        require(
            address(farm.gift) != address(0),
            "HotpotToken Farming: it is single farm!"
        );

        updateFarm(fid, address(0));

        uint256 scale = farm.scale;
        require(
            reward < uint256(-1).div(scale),
            "HotpotToken Farming: reward overflow"
        );
        uint256 duration = farm.duration;
        uint256 rewardRate;

        if (block.timestamp >= farm.periodFinish) {
            require(
                reward >= duration,
                "HotpotToken Farming: reward is too small"
            );
            rewardRate = reward.mul(scale).div(duration);
        } else {
            uint256 remaining = farm.periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(farm.rewardRate).div(scale);
            require(
                reward.add(leftover) >= duration,
                "HotpotToken Farming: reward is too small"
            );
            rewardRate = reward.add(leftover).mul(scale).div(duration);
        }

        uint256 balance = farm.gift.balanceOf(address(this));
        require(
            rewardRate <= balance.mul(scale).div(duration),
            "HotpotToken Farming: reward is too big"
        );

        farm.rewardRate = rewardRate;
        farm.lastUpdateTime = block.timestamp;
        farm.periodFinish = block.timestamp.add(duration);
        emit GiftAdded(fid, farm.gift, reward);
    }

    function setRewardDistribution(uint256 fid, address rewardDistribution)
        external
        restricted
    {
        FarmInfo storage farm = farmInfo[fid];
        farm.rewardDistribution = rewardDistribution;
        emit RewardDistributionChanged(fid, rewardDistribution);
    }

    function setDuration(uint256 fid, uint256 duration)
        external
        onlyRewardDistribution(fid)
    {
        FarmInfo storage farm = farmInfo[fid];
        require(
            block.timestamp >= farm.periodFinish,
            "HotpotToken Farming: not finished yet"
        );
        farm.duration = duration;
        emit DurationUpdated(fid, duration);
    }

    function setScale(uint256 fid, uint256 scale) external restricted {
        require(scale > 0, "HotpotToken Farming: scale is too low");
        require(scale <= 1e36, "HotpotToken Farming: scale is too high");
        FarmInfo storage farm = farmInfo[fid];
        require(
            farm.periodFinish == 0,
            "HotpotToken Farming: can't change scale after start"
        );
        farm.scale = scale;
        emit ScaleUpdated(fid, scale);
    }

    /// @notice Withdraw LP token/HOTPOT staked without caring about HOTPOT and rewards. EMERGENCY ONLY.
    /// @param fid The index of the farm. See `farmInfo`.
    function emergencyWithdraw(uint256 fid) external {
        UserInfo storage user = userInfo[fid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewards = 0;

        // Note: transfer can fail or succeed if `amount` is zero.
        TransferHelper.safeTransfer(
            stakingTokens[fid],
            address(msg.sender),
            amount
        );

        emit EmergencyWithdraw(msg.sender, fid, amount);
    }

    // Safe hotpot transfer function, just in case if rounding error causes farm to not have enough HOTPOTs.
    function safeHotpotTransfer(address _to, uint256 _amount) internal {
        uint256 hotpotBal = hotpot.balanceOf(address(this));
        if (_amount > hotpotBal) {
            hotpot.transfer(_to, hotpotBal);
        } else {
            hotpot.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
