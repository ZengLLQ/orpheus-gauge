module orpheus_gauge::bribe_marketplace {
    use std::signer;
    use std::vector;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::gauge_controller;

    // Error codes
    const ERR_NOT_INITIALIZED: u64 = 6001;
    const ERR_ALREADY_INITIALIZED: u64 = 6002;
    const ERR_UNAUTHORIZED: u64 = 6003;
    const ERR_ZERO_AMOUNT: u64 = 6004;
    const ERR_TARGET_EPOCH_MUST_BE_FUTURE: u64 = 6005;
    const ERR_EPOCH_NOT_ARRIVED_YET: u64 = 6006;
    const ERR_ALREADY_CLAIMED: u64 = 6007;
    const ERR_BRIBE_POOL_NOT_FOUND: u64 = 6008;
    const ERR_NO_VOTED_WEIGHT: u64 = 6009;
    const ERR_ZERO_GAUGE_WEIGHT: u64 = 6010;

    struct BribePool has copy, drop, store {
        gauge_id: u64,
        target_epoch: u64,
        token_id: u64,
        total_amount: u64,
        claimed_amount: u64,
    }

    struct BribeDepositedEvent has drop, store {
        depositor: address,
        gauge_id: u64,
        target_epoch: u64,
        token_id: u64,
        amount: u64,
    }

    struct BribeClaimedEvent has drop, store {
        user: address,
        gauge_id: u64,
        target_epoch: u64,
        token_id: u64,
        reward_amount: u64,
        timestamp: u64,
    }

    struct MarketplaceState has key {
        admin: address,
        // target_epoch -> (gauge_id -> vector<BribePool>)
        bribes: Table<u64, Table<u64, vector<BribePool>>>,
        // user -> (target_epoch -> (gauge_id -> (token_id -> bool)))
        claims: Table<address, Table<u64, Table<u64, Table<u64, bool>>>>,
        bribe_deposited_events: EventHandle<BribeDepositedEvent>,
        bribe_claimed_events: EventHandle<BribeClaimedEvent>,
    }

    public fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<MarketplaceState>(admin_addr), ERR_ALREADY_INITIALIZED);

        move_to(admin, MarketplaceState {
            admin: admin_addr,
            bribes: table::new(),
            claims: table::new(),
            bribe_deposited_events: account::new_event_handle<BribeDepositedEvent>(admin),
            bribe_claimed_events: account::new_event_handle<BribeClaimedEvent>(admin),
        });
    }

    /// Deposit bribe incentives for voters of gauge_id in target_epoch
    public fun deposit_bribe(
        depositor: &signer,
        market_addr: address,
        gauge_id: u64,
        target_epoch: u64,
        token_id: u64,
        amount: u64,
        current_time: u64
    ) acquires MarketplaceState {
        let depositor_addr = signer::address_of(depositor);
        assert!(exists<MarketplaceState>(market_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<MarketplaceState>(market_addr);

        assert!(amount > 0, ERR_ZERO_AMOUNT);
        let current_week = math::round_to_week(current_time);
        assert!(target_epoch >= current_week, ERR_TARGET_EPOCH_MUST_BE_FUTURE);

        if (!table::contains(&state.bribes, target_epoch)) {
            table::add(&mut state.bribes, target_epoch, table::new());
        };

        let epoch_tbl = table::borrow_mut(&mut state.bribes, target_epoch);
        if (!table::contains(epoch_tbl, gauge_id)) {
            let pool_vec = vector::empty<BribePool>();
            vector::push_back(&mut pool_vec, BribePool {
                gauge_id,
                target_epoch,
                token_id,
                total_amount: amount,
                claimed_amount: 0,
            });
            table::add(epoch_tbl, gauge_id, pool_vec);
        } else {
            let pool_vec = table::borrow_mut(epoch_tbl, gauge_id);
            let len = vector::length(pool_vec);
            let found = false;
            let i = 0;
            while (i < len) {
                let p = vector::borrow_mut(pool_vec, i);
                if (p.token_id == token_id) {
                    p.total_amount = p.total_amount + amount;
                    found = true;
                    break
                };
                i = i + 1;
            };

            if (!found) {
                vector::push_back(pool_vec, BribePool {
                    gauge_id,
                    target_epoch,
                    token_id,
                    total_amount: amount,
                    claimed_amount: 0,
                });
            };
        };

        event::emit_event(&mut state.bribe_deposited_events, BribeDepositedEvent {
            depositor: depositor_addr,
            gauge_id,
            target_epoch,
            token_id,
            amount,
        });
    }

    /// Claim bribe reward for voting in target_epoch
    public fun claim_bribe(
        user: &signer,
        market_addr: address,
        controller_addr: address,
        gauge_id: u64,
        target_epoch: u64,
        token_id: u64,
        current_time: u64
    ): u64 acquires MarketplaceState {
        let user_addr = signer::address_of(user);
        assert!(exists<MarketplaceState>(market_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<MarketplaceState>(market_addr);

        assert!(current_time >= target_epoch, ERR_EPOCH_NOT_ARRIVED_YET);

        // Check if already claimed
        if (has_user_claimed_internal(state, user_addr, target_epoch, gauge_id, token_id)) {
            abort ERR_ALREADY_CLAIMED
        };

        assert!(table::contains(&state.bribes, target_epoch), ERR_BRIBE_POOL_NOT_FOUND);
        let epoch_tbl = table::borrow_mut(&mut state.bribes, target_epoch);
        assert!(table::contains(epoch_tbl, gauge_id), ERR_BRIBE_POOL_NOT_FOUND);
        let pool_vec = table::borrow_mut(epoch_tbl, gauge_id);

        let len = vector::length(pool_vec);
        let pool_idx = 0;
        let found = false;
        while (pool_idx < len) {
            let p = vector::borrow(pool_vec, pool_idx);
            if (p.token_id == token_id) {
                found = true;
                break
            };
            pool_idx = pool_idx + 1;
        };
        assert!(found, ERR_BRIBE_POOL_NOT_FOUND);

        // Get user's allocated weight to this gauge at target_epoch
        let user_w = gauge_controller::get_user_allocated_weight(controller_addr, user_addr, gauge_id, target_epoch);
        assert!(user_w > 0, ERR_NO_VOTED_WEIGHT);

        let gauge_w = gauge_controller::get_gauge_weight(controller_addr, gauge_id, target_epoch);
        assert!(gauge_w > 0, ERR_ZERO_GAUGE_WEIGHT);

        let pool_ref = vector::borrow_mut(pool_vec, pool_idx);
        let user_reward_u128 = math::mul_div_u128((pool_ref.total_amount as u128), user_w, gauge_w);
        let user_reward = (user_reward_u128 as u64);

        // Cap user_reward at remaining unclaimed bribe in pool to prevent rounding overflow
        if (pool_ref.claimed_amount < pool_ref.total_amount) {
            let remaining = pool_ref.total_amount - pool_ref.claimed_amount;
            if (user_reward > remaining) {
                user_reward = remaining;
            };
        } else {
            user_reward = 0;
        };

        pool_ref.claimed_amount = pool_ref.claimed_amount + user_reward;

        // Record claimed state
        record_user_claim(state, user_addr, target_epoch, gauge_id, token_id);

        event::emit_event(&mut state.bribe_claimed_events, BribeClaimedEvent {
            user: user_addr,
            gauge_id,
            target_epoch,
            token_id,
            reward_amount: user_reward,
            timestamp: current_time,
        });

        user_reward
    }

    fun has_user_claimed_internal(
        state: &MarketplaceState,
        user_addr: address,
        target_epoch: u64,
        gauge_id: u64,
        token_id: u64
    ): bool {
        if (!table::contains(&state.claims, user_addr)) return false;
        let u_tbl = table::borrow(&state.claims, user_addr);

        if (!table::contains(u_tbl, target_epoch)) return false;
        let e_tbl = table::borrow(u_tbl, target_epoch);

        if (!table::contains(e_tbl, gauge_id)) return false;
        let g_tbl = table::borrow(e_tbl, gauge_id);

        if (!table::contains(g_tbl, token_id)) return false;
        *table::borrow(g_tbl, token_id)
    }

    fun record_user_claim(
        state: &mut MarketplaceState,
        user_addr: address,
        target_epoch: u64,
        gauge_id: u64,
        token_id: u64
    ) {
        if (!table::contains(&state.claims, user_addr)) {
            table::add(&mut state.claims, user_addr, table::new());
        };
        let u_tbl = table::borrow_mut(&mut state.claims, user_addr);

        if (!table::contains(u_tbl, target_epoch)) {
            table::add(u_tbl, target_epoch, table::new());
        };
        let e_tbl = table::borrow_mut(u_tbl, target_epoch);

        if (!table::contains(e_tbl, gauge_id)) {
            table::add(e_tbl, gauge_id, table::new());
        };
        let g_tbl = table::borrow_mut(e_tbl, gauge_id);

        table::add(g_tbl, token_id, true);
    }

    // ==========================================
    // View Functions
    // ==========================================

    public fun get_bribe_pool_info(
        market_addr: address,
        target_epoch: u64,
        gauge_id: u64,
        token_id: u64
    ): (u64, u64) acquires MarketplaceState {
        assert!(exists<MarketplaceState>(market_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<MarketplaceState>(market_addr);

        if (!table::contains(&state.bribes, target_epoch)) return (0, 0);
        let epoch_tbl = table::borrow(&state.bribes, target_epoch);

        if (!table::contains(epoch_tbl, gauge_id)) return (0, 0);
        let pool_vec = table::borrow(epoch_tbl, gauge_id);

        let len = vector::length(pool_vec);
        let i = 0;
        while (i < len) {
            let p = vector::borrow(pool_vec, i);
            if (p.token_id == token_id) {
                return (p.total_amount, p.claimed_amount)
            };
            i = i + 1;
        };

        (0, 0)
    }

    public fun has_claimed(
        market_addr: address,
        user_addr: address,
        target_epoch: u64,
        gauge_id: u64,
        token_id: u64
    ): bool acquires MarketplaceState {
        if (!exists<MarketplaceState>(market_addr)) return false;
        let state = borrow_global<MarketplaceState>(market_addr);
        has_user_claimed_internal(state, user_addr, target_epoch, gauge_id, token_id)
    }
}
