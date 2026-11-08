module orpheus_gauge::liquidity_gauge {
    use std::signer;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::voting_escrow;

    // Error codes
    const ERR_NOT_INITIALIZED: u64 = 5001;
    const ERR_ALREADY_INITIALIZED: u64 = 5002;
    const ERR_UNAUTHORIZED: u64 = 5003;
    const ERR_ZERO_AMOUNT: u64 = 5004;
    const ERR_INSUFFICIENT_LP_BALANCE: u64 = 5005;
    const ERR_POSITION_NOT_FOUND: u64 = 5006;
    const ERR_CANNOT_KICK_VALID_BOOST: u64 = 5007;

    struct UserLPPosition has copy, drop, store {
        staked_lp: u64,
        boosted_lp: u128,
        reward_integral: u128,
        unclaimed_rewards: u64,
    }

    struct LPDepositEvent has drop, store {
        user: address,
        gauge_id: u64,
        amount: u64,
        new_staked: u64,
        new_boosted: u128,
        timestamp: u64,
    }

    struct LPWithdrawEvent has drop, store {
        user: address,
        gauge_id: u64,
        amount: u64,
        remaining_staked: u64,
        remaining_boosted: u128,
        timestamp: u64,
    }

    struct RewardClaimedEvent has drop, store {
        user: address,
        gauge_id: u64,
        reward_amount: u64,
        timestamp: u64,
    }

    struct KickedEvent has drop, store {
        kicker: address,
        target_user: address,
        gauge_id: u64,
        old_boost: u128,
        new_boost: u128,
        timestamp: u64,
    }

    struct EmissionNotifiedEvent has drop, store {
        gauge_id: u64,
        amount: u64,
        new_integral: u128,
        timestamp: u64,
    }

    struct GaugePool has key {
        admin: address,
        gauge_id: u64,
        total_staked_lp: u64,
        total_boosted_lp: u128,
        reward_integral: u128, // 18-decimal master index accumulator
        last_update_time: u64,
        positions: Table<address, UserLPPosition>,
        deposit_events: EventHandle<LPDepositEvent>,
        withdraw_events: EventHandle<LPWithdrawEvent>,
        reward_claimed_events: EventHandle<RewardClaimedEvent>,
        kicked_events: EventHandle<KickedEvent>,
        emission_events: EventHandle<EmissionNotifiedEvent>,
    }

    public fun initialize_gauge(
        admin: &signer,
        gauge_id: u64,
        current_time: u64
    ) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<GaugePool>(admin_addr), ERR_ALREADY_INITIALIZED);

        move_to(admin, GaugePool {
            admin: admin_addr,
            gauge_id,
            total_staked_lp: 0,
            total_boosted_lp: 0,
            reward_integral: 0,
            last_update_time: current_time,
            positions: table::new(),
            deposit_events: account::new_event_handle<LPDepositEvent>(admin),
            withdraw_events: account::new_event_handle<LPWithdrawEvent>(admin),
            reward_claimed_events: account::new_event_handle<RewardClaimedEvent>(admin),
            kicked_events: account::new_event_handle<KickedEvent>(admin),
            emission_events: account::new_event_handle<EmissionNotifiedEvent>(admin),
        });
    }

    /// Notify gauge of newly arrived emissions, updating the master reward index
    public fun notify_emission_reward(
        gauge_addr: address,
        amount: u64,
        current_time: u64
    ) acquires GaugePool {
        assert!(exists<GaugePool>(gauge_addr), ERR_NOT_INITIALIZED);
        let pool = borrow_global_mut<GaugePool>(gauge_addr);

        if (pool.total_boosted_lp > 0 && amount > 0) {
            let delta_integral = math::wad_div((amount as u128), pool.total_boosted_lp);
            pool.reward_integral = pool.reward_integral + delta_integral;
        };

        pool.last_update_time = current_time;

        event::emit_event(&mut pool.emission_events, EmissionNotifiedEvent {
            gauge_id: pool.gauge_id,
            amount,
            new_integral: pool.reward_integral,
            timestamp: current_time,
        });
    }

    /// Update user's accrued rewards based on reward_integral delta
    fun update_user_reward(pool_reward_integral: u128, pos: &mut UserLPPosition) {
        if (pos.boosted_lp > 0 && pool_reward_integral > pos.reward_integral) {
            let delta_i = pool_reward_integral - pos.reward_integral;
            let pending = math::wad_mul(pos.boosted_lp, delta_i);
            pos.unclaimed_rewards = pos.unclaimed_rewards + (pending as u64);
        };
        pos.reward_integral = pool_reward_integral;
    }

    /// Deposit LP tokens and calculate boosted balance from veToken power
    public fun deposit_lp(
        user: &signer,
        gauge_addr: address,
        escrow_addr: address,
        amount: u64,
        current_time: u64
    ) acquires GaugePool {
        let user_addr = signer::address_of(user);
        assert!(exists<GaugePool>(gauge_addr), ERR_NOT_INITIALIZED);
        let pool = borrow_global_mut<GaugePool>(gauge_addr);
        assert!(amount > 0, ERR_ZERO_AMOUNT);

        let user_ve = voting_escrow::get_voting_power(escrow_addr, user_addr, current_time);
        let total_ve = voting_escrow::get_total_voting_power(escrow_addr, current_time);

        if (!table::contains(&pool.positions, user_addr)) {
            let new_staked = amount;
            let new_total_staked = pool.total_staked_lp + amount;
            let boosted = math::calculate_boost(new_staked, new_total_staked, user_ve, total_ve);

            let pos = UserLPPosition {
                staked_lp: new_staked,
                boosted_lp: boosted,
                reward_integral: pool.reward_integral,
                unclaimed_rewards: 0,
            };

            pool.total_staked_lp = new_total_staked;
            pool.total_boosted_lp = pool.total_boosted_lp + boosted;
            table::add(&mut pool.positions, user_addr, pos);

            event::emit_event(&mut pool.deposit_events, LPDepositEvent {
                user: user_addr,
                gauge_id: pool.gauge_id,
                amount,
                new_staked,
                new_boosted: boosted,
                timestamp: current_time,
            });
        } else {
            let pool_integral = pool.reward_integral;
            let pos = table::borrow_mut(&mut pool.positions, user_addr);
            update_user_reward(pool_integral, pos);

            pool.total_boosted_lp = pool.total_boosted_lp - pos.boosted_lp;
            let new_staked = pos.staked_lp + amount;
            let new_total_staked = pool.total_staked_lp + amount;
            let new_boosted = math::calculate_boost(new_staked, new_total_staked, user_ve, total_ve);

            pos.staked_lp = new_staked;
            pos.boosted_lp = new_boosted;

            pool.total_staked_lp = new_total_staked;
            pool.total_boosted_lp = pool.total_boosted_lp + new_boosted;

            event::emit_event(&mut pool.deposit_events, LPDepositEvent {
                user: user_addr,
                gauge_id: pool.gauge_id,
                amount,
                new_staked,
                new_boosted,
                timestamp: current_time,
            });
        };
    }

    /// Withdraw LP tokens, updating rewards and recalculating boost
    public fun withdraw_lp(
        user: &signer,
        gauge_addr: address,
        escrow_addr: address,
        amount: u64,
        current_time: u64
    ): u64 acquires GaugePool {
        let user_addr = signer::address_of(user);
        assert!(exists<GaugePool>(gauge_addr), ERR_NOT_INITIALIZED);
        let pool = borrow_global_mut<GaugePool>(gauge_addr);
        assert!(amount > 0, ERR_ZERO_AMOUNT);
        assert!(table::contains(&pool.positions, user_addr), ERR_POSITION_NOT_FOUND);

        let pool_integral = pool.reward_integral;
        let pos = table::borrow_mut(&mut pool.positions, user_addr);
        assert!(pos.staked_lp >= amount, ERR_INSUFFICIENT_LP_BALANCE);

        update_user_reward(pool_integral, pos);

        let user_ve = voting_escrow::get_voting_power(escrow_addr, user_addr, current_time);
        let total_ve = voting_escrow::get_total_voting_power(escrow_addr, current_time);

        pool.total_boosted_lp = pool.total_boosted_lp - pos.boosted_lp;
        let remaining_staked = pos.staked_lp - amount;
        let new_total_staked = pool.total_staked_lp - amount;

        let new_boosted = if (remaining_staked > 0) {
            math::calculate_boost(remaining_staked, new_total_staked, user_ve, total_ve)
        } else {
            0
        };

        pos.staked_lp = remaining_staked;
        pos.boosted_lp = new_boosted;

        pool.total_staked_lp = new_total_staked;
        pool.total_boosted_lp = pool.total_boosted_lp + new_boosted;

        event::emit_event(&mut pool.withdraw_events, LPWithdrawEvent {
            user: user_addr,
            gauge_id: pool.gauge_id,
            amount,
            remaining_staked,
            remaining_boosted: new_boosted,
            timestamp: current_time,
        });

        amount
    }

    /// Claim accrued emissions
    public fun claim_rewards(
        user: &signer,
        gauge_addr: address
    ): u64 acquires GaugePool {
        let user_addr = signer::address_of(user);
        assert!(exists<GaugePool>(gauge_addr), ERR_NOT_INITIALIZED);
        let pool = borrow_global_mut<GaugePool>(gauge_addr);
        assert!(table::contains(&pool.positions, user_addr), ERR_POSITION_NOT_FOUND);

        let pool_integral = pool.reward_integral;
        let pos = table::borrow_mut(&mut pool.positions, user_addr);
        update_user_reward(pool_integral, pos);

        let reward = pos.unclaimed_rewards;
        pos.unclaimed_rewards = 0;

        event::emit_event(&mut pool.reward_claimed_events, RewardClaimedEvent {
            user: user_addr,
            gauge_id: pool.gauge_id,
            reward_amount: reward,
            timestamp: pool.last_update_time,
        });

        reward
    }

    /// Recalculate boost for a user whose veToken lock has decayed or expired
    public fun kick(
        caller: &signer,
        gauge_addr: address,
        escrow_addr: address,
        target_user: address,
        current_time: u64
    ) acquires GaugePool {
        let caller_addr = signer::address_of(caller);
        assert!(exists<GaugePool>(gauge_addr), ERR_NOT_INITIALIZED);
        let pool = borrow_global_mut<GaugePool>(gauge_addr);
        assert!(table::contains(&pool.positions, target_user), ERR_POSITION_NOT_FOUND);

        let pool_integral = pool.reward_integral;
        let pos = table::borrow_mut(&mut pool.positions, target_user);
        update_user_reward(pool_integral, pos);

        let target_ve = voting_escrow::get_voting_power(escrow_addr, target_user, current_time);
        let total_ve = voting_escrow::get_total_voting_power(escrow_addr, current_time);

        let new_boost = math::calculate_boost(pos.staked_lp, pool.total_staked_lp, target_ve, total_ve);
        // Only kick if their boost has genuinely decreased
        assert!(new_boost < pos.boosted_lp, ERR_CANNOT_KICK_VALID_BOOST);

        let old_boost = pos.boosted_lp;
        let delta = old_boost - new_boost;

        pos.boosted_lp = new_boost;
        pool.total_boosted_lp = pool.total_boosted_lp - delta;

        event::emit_event(&mut pool.kicked_events, KickedEvent {
            kicker: caller_addr,
            target_user,
            gauge_id: pool.gauge_id,
            old_boost,
            new_boost,
            timestamp: current_time,
        });
    }

    // ==========================================
    // View Functions
    // ==========================================

    public fun get_user_position(
        gauge_addr: address,
        user_addr: address
    ): (u64, u128, u64) acquires GaugePool {
        assert!(exists<GaugePool>(gauge_addr), ERR_NOT_INITIALIZED);
        let pool = borrow_global<GaugePool>(gauge_addr);
        if (table::contains(&pool.positions, user_addr)) {
            let pos = table::borrow(&pool.positions, user_addr);
            (pos.staked_lp, pos.boosted_lp, pos.unclaimed_rewards)
        } else {
            (0, 0, 0)
        }
    }

    public fun get_pending_rewards(
        gauge_addr: address,
        user_addr: address
    ): u64 acquires GaugePool {
        assert!(exists<GaugePool>(gauge_addr), ERR_NOT_INITIALIZED);
        let pool = borrow_global<GaugePool>(gauge_addr);
        if (!table::contains(&pool.positions, user_addr)) return 0;

        let pos = table::borrow(&pool.positions, user_addr);
        let current_unclaimed = pos.unclaimed_rewards;

        if (pos.boosted_lp > 0 && pool.reward_integral > pos.reward_integral) {
            let delta_i = pool.reward_integral - pos.reward_integral;
            let pending = math::wad_mul(pos.boosted_lp, delta_i);
            current_unclaimed = current_unclaimed + (pending as u64);
        };

        current_unclaimed
    }

    public fun get_pool_stats(gauge_addr: address): (u64, u128, u128) acquires GaugePool {
        assert!(exists<GaugePool>(gauge_addr), ERR_NOT_INITIALIZED);
        let pool = borrow_global<GaugePool>(gauge_addr);
        (pool.total_staked_lp, pool.total_boosted_lp, pool.reward_integral)
    }
}
