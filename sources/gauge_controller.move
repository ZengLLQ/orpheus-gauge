module orpheus_gauge::gauge_controller {
    use std::signer;
    use std::vector;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::voting_escrow;

    // Error codes
    const ERR_NOT_INITIALIZED: u64 = 3001;
    const ERR_ALREADY_INITIALIZED: u64 = 3002;
    const ERR_UNAUTHORIZED: u64 = 3003;
    const ERR_GAUGE_ALREADY_EXISTS: u64 = 3004;
    const ERR_GAUGE_NOT_FOUND: u64 = 3005;
    const ERR_GAUGE_INACTIVE: u64 = 3006;
    const ERR_VECTOR_LENGTH_MISMATCH: u64 = 3007;
    const ERR_VOTE_WEIGHTS_EXCEED_100_PERCENT: u64 = 3008;
    const ERR_NO_VOTING_POWER: u64 = 3009;
    const ERR_VOTE_COOLDOWN_ACTIVE: u64 = 3010;
    const ERR_ZERO_WEIGHT: u64 = 3011;

    struct GaugeInfo has copy, drop, store {
        gauge_id: u64,
        pool_address: address,
        gauge_type: u8,
        is_active: bool,
        bias: u128,
        slope: u128,
        last_checkpoint: u64,
    }

    struct UserVote has copy, drop, store {
        gauge_id: u64,
        power_bps: u64,
        allocated_bias: u128,
        allocated_slope: u128,
        lock_end: u64,
    }

    struct VoteEvent has drop, store {
        user: address,
        gauge_ids: vector<u64>,
        weights_bps: vector<u64>,
        timestamp: u64,
    }

    struct GaugeAddedEvent has drop, store {
        gauge_id: u64,
        pool_address: address,
        gauge_type: u8,
        timestamp: u64,
    }

    struct ControllerState has key {
        admin: address,
        gauges: Table<u64, GaugeInfo>,
        gauge_ids: vector<u64>,
        total_bias: u128,
        total_slope: u128,
        last_total_checkpoint: u64,
        gauge_slope_changes: Table<u64, Table<u64, u128>>, // gauge_id -> (unlock_time -> slope)
        total_slope_changes: Table<u64, u128>, // unlock_time -> slope
        user_votes: Table<address, vector<UserVote>>,
        user_last_vote_time: Table<address, u64>,
        vote_events: EventHandle<VoteEvent>,
        gauge_added_events: EventHandle<GaugeAddedEvent>,
    }

    public fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<ControllerState>(admin_addr), ERR_ALREADY_INITIALIZED);

        move_to(admin, ControllerState {
            admin: admin_addr,
            gauges: table::new(),
            gauge_ids: vector::empty<u64>(),
            total_bias: 0,
            total_slope: 0,
            last_total_checkpoint: 0,
            gauge_slope_changes: table::new(),
            total_slope_changes: table::new(),
            user_votes: table::new(),
            user_last_vote_time: table::new(),
            vote_events: account::new_event_handle<VoteEvent>(admin),
            gauge_added_events: account::new_event_handle<GaugeAddedEvent>(admin),
        });
    }

    public fun add_gauge(
        admin: &signer,
        controller_addr: address,
        gauge_id: u64,
        pool_address: address,
        gauge_type: u8,
        current_time: u64
    ) acquires ControllerState {
        let admin_addr = signer::address_of(admin);
        assert!(exists<ControllerState>(controller_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<ControllerState>(controller_addr);
        assert!(state.admin == admin_addr, ERR_UNAUTHORIZED);
        assert!(!table::contains(&state.gauges, gauge_id), ERR_GAUGE_ALREADY_EXISTS);

        table::add(&mut state.gauges, gauge_id, GaugeInfo {
            gauge_id,
            pool_address,
            gauge_type,
            is_active: true,
            bias: 0,
            slope: 0,
            last_checkpoint: current_time,
        });

        table::add(&mut state.gauge_slope_changes, gauge_id, table::new());
        vector::push_back(&mut state.gauge_ids, gauge_id);

        event::emit_event(&mut state.gauge_added_events, GaugeAddedEvent {
            gauge_id,
            pool_address,
            gauge_type,
            timestamp: current_time,
        });
    }

    public fun set_gauge_active(
        admin: &signer,
        controller_addr: address,
        gauge_id: u64,
        is_active: bool
    ) acquires ControllerState {
        let admin_addr = signer::address_of(admin);
        assert!(exists<ControllerState>(controller_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<ControllerState>(controller_addr);
        assert!(state.admin == admin_addr, ERR_UNAUTHORIZED);
        assert!(table::contains(&state.gauges, gauge_id), ERR_GAUGE_NOT_FOUND);

        let g = table::borrow_mut(&mut state.gauges, gauge_id);
        g.is_active = is_active;
    }

    /// Roll forward total weight checkpoint
    public fun checkpoint_total(controller_addr: address, current_time: u64) acquires ControllerState {
        assert!(exists<ControllerState>(controller_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<ControllerState>(controller_addr);
        checkpoint_total_internal(state, current_time);
    }

    fun checkpoint_total_internal(state: &mut ControllerState, current_time: u64) {
        if (current_time <= state.last_total_checkpoint) return;

        let t_step = math::round_to_week(state.last_total_checkpoint);
        while (t_step + math::week() <= current_time) {
            t_step = t_step + math::week();
            let elapsed = math::week();
            let decay = (state.total_slope * (elapsed as u128)) / math::scale_wad();
            if (decay >= state.total_bias) {
                state.total_bias = 0;
            } else {
                state.total_bias = state.total_bias - decay;
            };

            if (table::contains(&state.total_slope_changes, t_step)) {
                let d_slope = *table::borrow(&state.total_slope_changes, t_step);
                if (d_slope >= state.total_slope) {
                    state.total_slope = 0;
                } else {
                    state.total_slope = state.total_slope - d_slope;
                };
            };
        };

        if (t_step < current_time) {
            let elapsed = current_time - t_step;
            let decay = (state.total_slope * (elapsed as u128)) / math::scale_wad();
            if (decay >= state.total_bias) {
                state.total_bias = 0;
            } else {
                state.total_bias = state.total_bias - decay;
            };
        };

        state.last_total_checkpoint = current_time;
    }

    /// Roll forward single gauge weight checkpoint
    public fun checkpoint_gauge(controller_addr: address, gauge_id: u64, current_time: u64) acquires ControllerState {
        assert!(exists<ControllerState>(controller_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<ControllerState>(controller_addr);
        assert!(table::contains(&state.gauges, gauge_id), ERR_GAUGE_NOT_FOUND);
        checkpoint_gauge_internal(state, gauge_id, current_time);
    }

    fun checkpoint_gauge_internal(state: &mut ControllerState, gauge_id: u64, current_time: u64) {
        let g = table::borrow_mut(&mut state.gauges, gauge_id);
        if (current_time <= g.last_checkpoint) return;

        let g_slope_tbl = table::borrow(&state.gauge_slope_changes, gauge_id);
        let t_step = math::round_to_week(g.last_checkpoint);

        while (t_step + math::week() <= current_time) {
            t_step = t_step + math::week();
            let elapsed = math::week();
            let decay = (g.slope * (elapsed as u128)) / math::scale_wad();
            if (decay >= g.bias) {
                g.bias = 0;
            } else {
                g.bias = g.bias - decay;
            };

            if (table::contains(g_slope_tbl, t_step)) {
                let d_slope = *table::borrow(g_slope_tbl, t_step);
                if (d_slope >= g.slope) {
                    g.slope = 0;
                } else {
                    g.slope = g.slope - d_slope;
                };
            };
        };

        if (t_step < current_time) {
            let elapsed = current_time - t_step;
            let decay = (g.slope * (elapsed as u128)) / math::scale_wad();
            if (decay >= g.bias) {
                g.bias = 0;
            } else {
                g.bias = g.bias - decay;
            };
        };

        g.last_checkpoint = current_time;
    }

    /// Cast user's veToken voting weight across gauges
    public fun vote_for_gauge_weights(
        user: &signer,
        controller_addr: address,
        escrow_addr: address,
        gauge_ids: vector<u64>,
        weights_bps: vector<u64>,
        current_time: u64
    ) acquires ControllerState {
        let user_addr = signer::address_of(user);
        assert!(exists<ControllerState>(controller_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<ControllerState>(controller_addr);

        let num_gauges = vector::length(&gauge_ids);
        assert!(num_gauges == vector::length(&weights_bps), ERR_VECTOR_LENGTH_MISMATCH);

        // Check voting cooldown (once per 1 week epoch)
        if (table::contains(&state.user_last_vote_time, user_addr)) {
            let last_voted = *table::borrow(&state.user_last_vote_time, user_addr);
            assert!(current_time >= last_voted + math::week(), ERR_VOTE_COOLDOWN_ACTIVE);
        };

        // Validate user lock
        let (lock_amount, lock_end) = voting_escrow::get_lock(escrow_addr, user_addr);
        assert!(lock_amount > 0, ERR_NO_VOTING_POWER);
        assert!(current_time < lock_end, ERR_NO_VOTING_POWER);

        let user_ve_power = voting_escrow::get_voting_power(escrow_addr, user_addr, current_time);
        assert!(user_ve_power > 0, ERR_NO_VOTING_POWER);

        let user_slope = math::calculate_slope(lock_amount);

        // Validate weights sum
        let total_bps: u64 = 0;
        let i = 0;
        while (i < num_gauges) {
            let w = *vector::borrow(&weights_bps, i);
            let g_id = *vector::borrow(&gauge_ids, i);
            assert!(table::contains(&state.gauges, g_id), ERR_GAUGE_NOT_FOUND);
            let g_info = table::borrow(&state.gauges, g_id);
            assert!(g_info.is_active, ERR_GAUGE_INACTIVE);

            total_bps = total_bps + w;
            i = i + 1;
        };
        assert!(total_bps <= math::bps_base(), ERR_VOTE_WEIGHTS_EXCEED_100_PERCENT);

        // First roll forward all affected gauge checkpoints and total checkpoint
        checkpoint_total_internal(state, current_time);
        i = 0;
        while (i < num_gauges) {
            let g_id = *vector::borrow(&gauge_ids, i);
            checkpoint_gauge_internal(state, g_id, current_time);
            i = i + 1;
        };

        // Remove previous vote allocations if user had prior votes
        if (table::contains(&state.user_votes, user_addr)) {
            let old_votes = *table::borrow(&state.user_votes, user_addr);
            let old_len = vector::length(&old_votes);
            let j = 0;
            while (j < old_len) {
                let old_v = vector::borrow(&old_votes, j);
                checkpoint_gauge_internal(state, old_v.gauge_id, current_time);

                // Subtract from total
                if (old_v.allocated_bias <= state.total_bias) {
                    state.total_bias = state.total_bias - old_v.allocated_bias;
                } else {
                    state.total_bias = 0;
                };
                if (old_v.allocated_slope <= state.total_slope) {
                    state.total_slope = state.total_slope - old_v.allocated_slope;
                } else {
                    state.total_slope = 0;
                };

                // Adjust total slope changes
                if (table::contains(&state.total_slope_changes, old_v.lock_end)) {
                    let sc = table::borrow_mut(&mut state.total_slope_changes, old_v.lock_end);
                    if (old_v.allocated_slope <= *sc) {
                        *sc = *sc - old_v.allocated_slope;
                    } else {
                        *sc = 0;
                    };
                };

                // Adjust gauge bias and slope
                let g = table::borrow_mut(&mut state.gauges, old_v.gauge_id);
                if (old_v.allocated_bias <= g.bias) {
                    g.bias = g.bias - old_v.allocated_bias;
                } else {
                    g.bias = 0;
                };
                if (old_v.allocated_slope <= g.slope) {
                    g.slope = g.slope - old_v.allocated_slope;
                } else {
                    g.slope = 0;
                };

                // Adjust gauge slope changes
                let g_sc_tbl = table::borrow_mut(&mut state.gauge_slope_changes, old_v.gauge_id);
                if (table::contains(g_sc_tbl, old_v.lock_end)) {
                    let g_sc = table::borrow_mut(g_sc_tbl, old_v.lock_end);
                    if (old_v.allocated_slope <= *g_sc) {
                        *g_sc = *g_sc - old_v.allocated_slope;
                    } else {
                        *g_sc = 0;
                    };
                };

                j = j + 1;
            };
        };

        // Allocate new votes
        let new_votes = vector::empty<UserVote>();
        i = 0;
        while (i < num_gauges) {
            let g_id = *vector::borrow(&gauge_ids, i);
            let w_bps = *vector::borrow(&weights_bps, i);

            if (w_bps > 0) {
                let allocated_bias = (user_ve_power * (w_bps as u128)) / (math::bps_base() as u128);
                let allocated_slope = (user_slope * (w_bps as u128)) / (math::bps_base() as u128);

                // Add to gauge
                let g = table::borrow_mut(&mut state.gauges, g_id);
                g.bias = g.bias + allocated_bias;
                g.slope = g.slope + allocated_slope;

                // Add to gauge scheduled slope changes
                let g_sc_tbl = table::borrow_mut(&mut state.gauge_slope_changes, g_id);
                if (!table::contains(g_sc_tbl, lock_end)) {
                    table::add(g_sc_tbl, lock_end, allocated_slope);
                } else {
                    let sc = table::borrow_mut(g_sc_tbl, lock_end);
                    *sc = *sc + allocated_slope;
                };

                // Add to total
                state.total_bias = state.total_bias + allocated_bias;
                state.total_slope = state.total_slope + allocated_slope;

                // Add to total scheduled slope changes
                if (!table::contains(&state.total_slope_changes, lock_end)) {
                    table::add(&mut state.total_slope_changes, lock_end, allocated_slope);
                } else {
                    let sc = table::borrow_mut(&mut state.total_slope_changes, lock_end);
                    *sc = *sc + allocated_slope;
                };

                vector::push_back(&mut new_votes, UserVote {
                    gauge_id: g_id,
                    power_bps: w_bps,
                    allocated_bias,
                    allocated_slope,
                    lock_end,
                });
            };

            i = i + 1;
        };

        // Record user votes
        if (!table::contains(&state.user_votes, user_addr)) {
            table::add(&mut state.user_votes, user_addr, new_votes);
        } else {
            let u_v_ref = table::borrow_mut(&mut state.user_votes, user_addr);
            *u_v_ref = new_votes;
        };

        // Record cooldown
        if (!table::contains(&state.user_last_vote_time, user_addr)) {
            table::add(&mut state.user_last_vote_time, user_addr, current_time);
        } else {
            let t_ref = table::borrow_mut(&mut state.user_last_vote_time, user_addr);
            *t_ref = current_time;
        };

        event::emit_event(&mut state.vote_events, VoteEvent {
            user: user_addr,
            gauge_ids,
            weights_bps,
            timestamp: current_time,
        });
    }

    // ==========================================
    // View Functions
    // ==========================================

    public fun get_gauge_weight(controller_addr: address, gauge_id: u64, current_time: u64): u128 acquires ControllerState {
        if (!exists<ControllerState>(controller_addr)) return 0;
        let state = borrow_global<ControllerState>(controller_addr);
        if (!table::contains(&state.gauges, gauge_id)) return 0;
        let g = table::borrow(&state.gauges, gauge_id);
        math::calculate_weight_at(g.bias, g.slope, g.last_checkpoint, current_time)
    }

    public fun get_total_weight(controller_addr: address, current_time: u64): u128 acquires ControllerState {
        if (!exists<ControllerState>(controller_addr)) return 0;
        let state = borrow_global<ControllerState>(controller_addr);
        math::calculate_weight_at(state.total_bias, state.total_slope, state.last_total_checkpoint, current_time)
    }

    /// Returns gauge relative weight in 18-decimal fixed-point (WAD)
    public fun get_gauge_relative_weight(
        controller_addr: address,
        gauge_id: u64,
        current_time: u64
    ): u128 acquires ControllerState {
        let g_w = get_gauge_weight(controller_addr, gauge_id, current_time);
        let total_w = get_total_weight(controller_addr, current_time);
        if (total_w == 0 || g_w == 0) {
            0
        } else {
            math::wad_div(g_w, total_w)
        }
    }

    public fun get_gauge_count(controller_addr: address): u64 acquires ControllerState {
        assert!(exists<ControllerState>(controller_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<ControllerState>(controller_addr);
        vector::length(&state.gauge_ids)
    }

    public fun get_gauge_id_at(controller_addr: address, index: u64): u64 acquires ControllerState {
        assert!(exists<ControllerState>(controller_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<ControllerState>(controller_addr);
        *vector::borrow(&state.gauge_ids, index)
    }

    public fun get_user_allocated_weight(
        controller_addr: address,
        user_addr: address,
        gauge_id: u64,
        current_time: u64
    ): u128 acquires ControllerState {
        if (!exists<ControllerState>(controller_addr)) return 0;
        let state = borrow_global<ControllerState>(controller_addr);
        if (!table::contains(&state.user_votes, user_addr)) return 0;

        let votes = table::borrow(&state.user_votes, user_addr);
        let len = vector::length(votes);
        let i = 0;
        while (i < len) {
            let v = vector::borrow(votes, i);
            if (v.gauge_id == gauge_id) {
                if (current_time >= v.lock_end) return 0;
                return math::calculate_weight_at(v.allocated_bias, v.allocated_slope, *table::borrow(&state.user_last_vote_time, user_addr), current_time)
            };
            i = i + 1;
        };
        0
    }
}
