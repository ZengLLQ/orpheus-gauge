module orpheus_gauge::voting_escrow {
    use std::signer;
    use std::vector;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use orpheus_gauge::math;

    // Error codes
    const ERR_NOT_INITIALIZED: u64 = 2001;
    const ERR_ALREADY_INITIALIZED: u64 = 2002;
    const ERR_UNAUTHORIZED: u64 = 2003;
    const ERR_ZERO_AMOUNT: u64 = 2004;
    const ERR_INVALID_LOCK_DURATION: u64 = 2005;
    const ERR_LOCK_EXCEEDS_MAX: u64 = 2006;
    const ERR_LOCK_ALREADY_EXISTS: u64 = 2007;
    const ERR_LOCK_NOT_FOUND: u64 = 2008;
    const ERR_LOCK_EXPIRED: u64 = 2009;
    const ERR_LOCK_NOT_EXPIRED: u64 = 2010;
    const ERR_NEW_DURATION_MUST_EXCEED_CURRENT: u64 = 2011;

    struct Point has copy, drop, store {
        bias: u128,
        slope: u128,
        timestamp: u64,
        epoch: u64,
    }

    struct LockedBalance has copy, drop, store {
        amount: u64,
        end: u64,
        start_epoch: u64,
    }

    struct LockCreatedEvent has drop, store {
        user: address,
        amount: u64,
        unlock_time: u64,
        bias: u128,
        slope: u128,
    }

    struct WithdrawEvent has drop, store {
        user: address,
        amount: u64,
        timestamp: u64,
    }

    struct LockExtendedEvent has drop, store {
        user: address,
        new_unlock_time: u64,
        new_bias: u128,
        timestamp: u64,
    }

    struct LockIncreasedEvent has drop, store {
        user: address,
        additional_amount: u64,
        new_total_amount: u64,
        timestamp: u64,
    }

    struct EscrowState has key {
        admin: address,
        epoch: u64,
        point_history: vector<Point>,
        user_points: Table<address, vector<Point>>,
        locks: Table<address, LockedBalance>,
        slope_changes: Table<u64, u128>,
        total_locked: u64,
        lock_created_events: EventHandle<LockCreatedEvent>,
        withdraw_events: EventHandle<WithdrawEvent>,
        lock_extended_events: EventHandle<LockExtendedEvent>,
        lock_increased_events: EventHandle<LockIncreasedEvent>,
    }

    public fun new_point(bias: u128, slope: u128, timestamp: u64, epoch: u64): Point {
        Point { bias, slope, timestamp, epoch }
    }

    public fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<EscrowState>(admin_addr), ERR_ALREADY_INITIALIZED);

        let initial_point = Point {
            bias: 0,
            slope: 0,
            timestamp: 0,
            epoch: 0,
        };

        let history = vector::empty<Point>();
        vector::push_back(&mut history, initial_point);

        move_to(admin, EscrowState {
            admin: admin_addr,
            epoch: 0,
            point_history: history,
            user_points: table::new(),
            locks: table::new(),
            slope_changes: table::new(),
            total_locked: 0,
            lock_created_events: account::new_event_handle<LockCreatedEvent>(admin),
            withdraw_events: account::new_event_handle<WithdrawEvent>(admin),
            lock_extended_events: account::new_event_handle<LockExtendedEvent>(admin),
            lock_increased_events: account::new_event_handle<LockIncreasedEvent>(admin),
        });
    }

    /// Roll forward global checkpoints to current_time
    public fun checkpoint(escrow_addr: address, current_time: u64) acquires EscrowState {
        assert!(exists<EscrowState>(escrow_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<EscrowState>(escrow_addr);
        checkpoint_internal(state, current_time);
    }

    fun checkpoint_internal(state: &mut EscrowState, current_time: u64) {
        let len = vector::length(&state.point_history);
        let last_pt = *vector::borrow(&state.point_history, len - 1);

        if (current_time <= last_pt.timestamp) {
            return
        };

        let last_epoch_time = math::round_to_week(last_pt.timestamp);
        let mut_bias = last_pt.bias;
        let mut_slope = last_pt.slope;
        let t_step = last_epoch_time;

        // Iterate through weekly intervals to accurately subtract expired slopes
        while (t_step + math::week() <= current_time) {
            t_step = t_step + math::week();
            let elapsed = math::week();
            let decay = (mut_slope * (elapsed as u128)) / math::scale_wad();
            if (decay >= mut_bias) {
                mut_bias = 0;
            } else {
                mut_bias = mut_bias - decay;
            };

            // Apply slope change if any locks expire at this week boundary
            if (table::contains(&state.slope_changes, t_step)) {
                let d_slope = *table::borrow(&state.slope_changes, t_step);
                if (d_slope >= mut_slope) {
                    mut_slope = 0;
                } else {
                    mut_slope = mut_slope - d_slope;
                };
            };

            state.epoch = state.epoch + 1;
            vector::push_back(&mut state.point_history, Point {
                bias: mut_bias,
                slope: mut_slope,
                timestamp: t_step,
                epoch: state.epoch,
            });
        };

        // Advance from last stepped boundary to current_time
        if (t_step < current_time) {
            let elapsed = current_time - t_step;
            let decay = (mut_slope * (elapsed as u128)) / math::scale_wad();
            if (decay >= mut_bias) {
                mut_bias = 0;
            } else {
                mut_bias = mut_bias - decay;
            };

            state.epoch = state.epoch + 1;
            vector::push_back(&mut state.point_history, Point {
                bias: mut_bias,
                slope: mut_slope,
                timestamp: current_time,
                epoch: state.epoch,
            });
        };
    }

    /// Create a new vote-escrow lock
    public fun create_lock(
        user: &signer,
        escrow_addr: address,
        amount: u64,
        lock_duration: u64,
        current_time: u64
    ) acquires EscrowState {
        let user_addr = signer::address_of(user);
        assert!(exists<EscrowState>(escrow_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<EscrowState>(escrow_addr);

        assert!(amount > 0, ERR_ZERO_AMOUNT);
        assert!(!table::contains(&state.locks, user_addr), ERR_LOCK_ALREADY_EXISTS);
        assert!(lock_duration >= math::min_lock_time(), ERR_INVALID_LOCK_DURATION);
        assert!(lock_duration <= math::max_lock_time(), ERR_LOCK_EXCEEDS_MAX);

        let unlock_time = math::round_to_week(current_time + lock_duration);
        assert!(unlock_time > current_time, ERR_INVALID_LOCK_DURATION);
        assert!(unlock_time <= current_time + math::max_lock_time(), ERR_LOCK_EXCEEDS_MAX);

        // Advance global checkpoints to current_time
        checkpoint_internal(state, current_time);

        let slope = math::calculate_slope(amount);
        let bias = math::calculate_bias(slope, unlock_time, current_time);

        // Record scheduled slope decrement at unlock week
        if (!table::contains(&state.slope_changes, unlock_time)) {
            table::add(&mut state.slope_changes, unlock_time, slope);
        } else {
            let existing = table::borrow_mut(&mut state.slope_changes, unlock_time);
            *existing = *existing + slope;
        };

        // Update latest global point
        let hist_len = vector::length(&state.point_history);
        let last_pt = vector::borrow_mut(&mut state.point_history, hist_len - 1);
        last_pt.bias = last_pt.bias + bias;
        last_pt.slope = last_pt.slope + slope;

        // Record user lock
        table::add(&mut state.locks, user_addr, LockedBalance {
            amount,
            end: unlock_time,
            start_epoch: current_time,
        });

        // Record user point
        if (!table::contains(&state.user_points, user_addr)) {
            let user_hist = vector::empty<Point>();
            vector::push_back(&mut user_hist, Point {
                bias,
                slope,
                timestamp: current_time,
                epoch: 1,
            });
            table::add(&mut state.user_points, user_addr, user_hist);
        } else {
            let user_hist = table::borrow_mut(&mut state.user_points, user_addr);
            let user_epoch = vector::length(user_hist) + 1;
            vector::push_back(user_hist, Point {
                bias,
                slope,
                timestamp: current_time,
                epoch: user_epoch,
            });
        };

        state.total_locked = state.total_locked + amount;

        event::emit_event(&mut state.lock_created_events, LockCreatedEvent {
            user: user_addr,
            amount,
            unlock_time,
            bias,
            slope,
        });
    }

    /// Increase locked amount without altering expiration
    public fun increase_amount(
        user: &signer,
        escrow_addr: address,
        additional_amount: u64,
        current_time: u64
    ) acquires EscrowState {
        let user_addr = signer::address_of(user);
        assert!(exists<EscrowState>(escrow_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<EscrowState>(escrow_addr);

        assert!(additional_amount > 0, ERR_ZERO_AMOUNT);
        assert!(table::contains(&state.locks, user_addr), ERR_LOCK_NOT_FOUND);

        let lock = *table::borrow(&state.locks, user_addr);
        assert!(current_time < lock.end, ERR_LOCK_EXPIRED);

        checkpoint_internal(state, current_time);

        let delta_slope = math::calculate_slope(additional_amount);
        let delta_bias = math::calculate_bias(delta_slope, lock.end, current_time);

        // Update slope changes
        let scheduled = table::borrow_mut(&mut state.slope_changes, lock.end);
        *scheduled = *scheduled + delta_slope;

        // Update global point
        let hist_len = vector::length(&state.point_history);
        let last_pt = vector::borrow_mut(&mut state.point_history, hist_len - 1);
        last_pt.bias = last_pt.bias + delta_bias;
        last_pt.slope = last_pt.slope + delta_slope;

        // Update user lock
        let lock_mut = table::borrow_mut(&mut state.locks, user_addr);
        lock_mut.amount = lock_mut.amount + additional_amount;
        let new_total = lock_mut.amount;

        // Calculate user current voting power + new addition
        let user_hist = table::borrow_mut(&mut state.user_points, user_addr);
        let u_len = vector::length(user_hist);
        let last_u_pt = vector::borrow(user_hist, u_len - 1);
        let cur_user_bias = math::calculate_weight_at(last_u_pt.bias, last_u_pt.slope, last_u_pt.timestamp, current_time);
        let new_user_bias = cur_user_bias + delta_bias;
        let new_user_slope = last_u_pt.slope + delta_slope;

        vector::push_back(user_hist, Point {
            bias: new_user_bias,
            slope: new_user_slope,
            timestamp: current_time,
            epoch: u_len + 1,
        });

        state.total_locked = state.total_locked + additional_amount;

        event::emit_event(&mut state.lock_increased_events, LockIncreasedEvent {
            user: user_addr,
            additional_amount,
            new_total_amount: new_total,
            timestamp: current_time,
        });
    }

    /// Extend the duration of an active lock
    public fun extend_lock_duration(
        user: &signer,
        escrow_addr: address,
        new_duration: u64,
        current_time: u64
    ) acquires EscrowState {
        let user_addr = signer::address_of(user);
        assert!(exists<EscrowState>(escrow_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<EscrowState>(escrow_addr);

        assert!(table::contains(&state.locks, user_addr), ERR_LOCK_NOT_FOUND);
        let lock = *table::borrow(&state.locks, user_addr);
        assert!(current_time < lock.end, ERR_LOCK_EXPIRED);

        let new_unlock_time = math::round_to_week(current_time + new_duration);
        assert!(new_unlock_time > lock.end, ERR_NEW_DURATION_MUST_EXCEED_CURRENT);
        assert!(new_unlock_time <= current_time + math::max_lock_time(), ERR_LOCK_EXCEEDS_MAX);

        checkpoint_internal(state, current_time);

        let slope = math::calculate_slope(lock.amount);
        let old_bias = math::calculate_bias(slope, lock.end, current_time);
        let new_bias = math::calculate_bias(slope, new_unlock_time, current_time);

        // Adjust old slope changes table
        let old_sched = table::borrow_mut(&mut state.slope_changes, lock.end);
        if (*old_sched >= slope) {
            *old_sched = *old_sched - slope;
        } else {
            *old_sched = 0;
        };

        // Add to new unlock time slope changes
        if (!table::contains(&state.slope_changes, new_unlock_time)) {
            table::add(&mut state.slope_changes, new_unlock_time, slope);
        } else {
            let new_sched = table::borrow_mut(&mut state.slope_changes, new_unlock_time);
            *new_sched = *new_sched + slope;
        };

        // Adjust global point
        let delta_bias = new_bias - old_bias;
        let hist_len = vector::length(&state.point_history);
        let last_pt = vector::borrow_mut(&mut state.point_history, hist_len - 1);
        last_pt.bias = last_pt.bias + delta_bias;

        // Update user lock
        let lock_mut = table::borrow_mut(&mut state.locks, user_addr);
        lock_mut.end = new_unlock_time;

        // Update user point
        let user_hist = table::borrow_mut(&mut state.user_points, user_addr);
        let u_len = vector::length(user_hist);
        vector::push_back(user_hist, Point {
            bias: new_bias,
            slope,
            timestamp: current_time,
            epoch: u_len + 1,
        });

        event::emit_event(&mut state.lock_extended_events, LockExtendedEvent {
            user: user_addr,
            new_unlock_time,
            new_bias,
            timestamp: current_time,
        });
    }

    /// Withdraw full locked balance once expiration has passed
    public fun withdraw(
        user: &signer,
        escrow_addr: address,
        current_time: u64
    ): u64 acquires EscrowState {
        let user_addr = signer::address_of(user);
        assert!(exists<EscrowState>(escrow_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<EscrowState>(escrow_addr);

        assert!(table::contains(&state.locks, user_addr), ERR_LOCK_NOT_FOUND);
        let lock = table::remove(&mut state.locks, user_addr);
        assert!(current_time >= lock.end, ERR_LOCK_NOT_EXPIRED);
        assert!(lock.amount > 0, ERR_ZERO_AMOUNT);

        checkpoint_internal(state, current_time);

        // Add user point with 0 bias and 0 slope
        let user_hist = table::borrow_mut(&mut state.user_points, user_addr);
        let u_len = vector::length(user_hist);
        vector::push_back(user_hist, Point {
            bias: 0,
            slope: 0,
            timestamp: current_time,
            epoch: u_len + 1,
        });

        state.total_locked = state.total_locked - lock.amount;

        event::emit_event(&mut state.withdraw_events, WithdrawEvent {
            user: user_addr,
            amount: lock.amount,
            timestamp: current_time,
        });

        lock.amount
    }

    // ==========================================
    // View Functions
    // ==========================================

    public fun get_voting_power(escrow_addr: address, user_addr: address, timestamp: u64): u128 acquires EscrowState {
        if (!exists<EscrowState>(escrow_addr)) return 0;
        let state = borrow_global<EscrowState>(escrow_addr);

        if (!table::contains(&state.locks, user_addr)) return 0;
        let lock = table::borrow(&state.locks, user_addr);
        if (timestamp >= lock.end) return 0;

        if (!table::contains(&state.user_points, user_addr)) return 0;
        let user_hist = table::borrow(&state.user_points, user_addr);
        let u_len = vector::length(user_hist);
        if (u_len == 0) return 0;

        let last_pt = vector::borrow(user_hist, u_len - 1);
        math::calculate_weight_at(last_pt.bias, last_pt.slope, last_pt.timestamp, timestamp)
    }

    public fun get_total_voting_power(escrow_addr: address, timestamp: u64): u128 acquires EscrowState {
        if (!exists<EscrowState>(escrow_addr)) return 0;
        let state = borrow_global<EscrowState>(escrow_addr);

        let h_len = vector::length(&state.point_history);
        if (h_len == 0) return 0;

        let last_pt = vector::borrow(&state.point_history, h_len - 1);
        math::calculate_weight_at(last_pt.bias, last_pt.slope, last_pt.timestamp, timestamp)
    }

    public fun get_lock(escrow_addr: address, user_addr: address): (u64, u64) acquires EscrowState {
        assert!(exists<EscrowState>(escrow_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<EscrowState>(escrow_addr);
        if (table::contains(&state.locks, user_addr)) {
            let lock = table::borrow(&state.locks, user_addr);
            (lock.amount, lock.end)
        } else {
            (0, 0)
        }
    }

    public fun get_total_locked(escrow_addr: address): u64 acquires EscrowState {
        assert!(exists<EscrowState>(escrow_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<EscrowState>(escrow_addr);
        state.total_locked
    }

    public fun has_lock(escrow_addr: address, user_addr: address): bool acquires EscrowState {
        if (!exists<EscrowState>(escrow_addr)) return false;
        let state = borrow_global<EscrowState>(escrow_addr);
        table::contains(&state.locks, user_addr)
    }

    public fun is_lock_expired(escrow_addr: address, user_addr: address, current_time: u64): bool acquires EscrowState {
        if (!exists<EscrowState>(escrow_addr)) return true;
        let state = borrow_global<EscrowState>(escrow_addr);
        if (!table::contains(&state.locks, user_addr)) return true;
        let lock = table::borrow(&state.locks, user_addr);
        current_time >= lock.end
    }
}
