module orpheus_gauge::emission_distributor {
    use std::signer;
    use std::vector;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::gauge_controller;

    // Error codes
    const ERR_NOT_INITIALIZED: u64 = 4001;
    const ERR_ALREADY_INITIALIZED: u64 = 4002;
    const ERR_UNAUTHORIZED: u64 = 4003;
    const ERR_EPOCH_ALREADY_DISTRIBUTED: u64 = 4004;
    const ERR_INVALID_DECAY_RATE: u64 = 4005;

    struct EmissionDistributedEvent has drop, store {
        epoch: u64,
        total_emission: u64,
        gauge_ids: vector<u64>,
        allocated_amounts: vector<u64>,
        timestamp: u64,
    }

    struct DistributorState has key {
        admin: address,
        base_emission_per_epoch: u64,
        decay_rate_bps: u64, // e.g. 100 bps = 1.00% decay per epoch
        min_emission_floor: u64,
        start_epoch: u64,
        last_distribution_epoch: u64,
        total_emitted: u128,
        epoch_emissions: Table<u64, u64>,
        gauge_allocations: Table<u64, Table<u64, u64>>, // epoch -> (gauge_id -> emission)
        distribution_events: EventHandle<EmissionDistributedEvent>,
    }

    public fun initialize(
        admin: &signer,
        base_emission: u64,
        decay_bps: u64,
        min_floor: u64,
        start_time: u64
    ) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<DistributorState>(admin_addr), ERR_ALREADY_INITIALIZED);
        assert!(decay_bps <= math::bps_base(), ERR_INVALID_DECAY_RATE);

        let start_epoch = math::round_to_week(start_time);

        move_to(admin, DistributorState {
            admin: admin_addr,
            base_emission_per_epoch: base_emission,
            decay_rate_bps: decay_bps,
            min_emission_floor: min_floor,
            start_epoch,
            last_distribution_epoch: 0,
            total_emitted: 0,
            epoch_emissions: table::new(),
            gauge_allocations: table::new(),
            distribution_events: account::new_event_handle<EmissionDistributedEvent>(admin),
        });
    }

    /// Calculate emission budget for a given epoch index
    public fun calculate_emission_for_epoch(
        base: u64,
        decay_bps: u64,
        floor: u64,
        epoch_index: u64
    ): u64 {
        let current_emission = (base as u128);
        let decay_mult = ((math::bps_base() - decay_bps) as u128);
        let base_bps = (math::bps_base() as u128);

        let i = 0;
        while (i < epoch_index) {
            current_emission = (current_emission * decay_mult) / base_bps;
            if (current_emission <= (floor as u128)) {
                return floor
            };
            i = i + 1;
        };

        let result = (current_emission as u64);
        if (result < floor) {
            floor
        } else {
            result
        }
    }

    /// Distribute emissions for the current weekly epoch across all active gauges based on veToken weights
    public fun distribute_epoch_emissions(
        distributor_addr: address,
        controller_addr: address,
        current_time: u64
    ): (u64, vector<u64>, vector<u64>) acquires DistributorState {
        assert!(exists<DistributorState>(distributor_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global_mut<DistributorState>(distributor_addr);

        let current_epoch_time = math::round_to_week(current_time);
        assert!(current_epoch_time > state.last_distribution_epoch, ERR_EPOCH_ALREADY_DISTRIBUTED);

        let epoch_index = if (current_epoch_time > state.start_epoch) {
            (current_epoch_time - state.start_epoch) / math::week()
        } else {
            0
        };

        let total_epoch_budget = calculate_emission_for_epoch(
            state.base_emission_per_epoch,
            state.decay_rate_bps,
            state.min_emission_floor,
            epoch_index
        );

        let num_gauges = gauge_controller::get_gauge_count(controller_addr);
        let allocated_g_ids = vector::empty<u64>();
        let allocated_amounts = vector::empty<u64>();

        let epoch_alloc_tbl = table::new<u64, u64>();
        let sum_allocated: u64 = 0;

        let i = 0;
        while (i < num_gauges) {
            let g_id = gauge_controller::get_gauge_id_at(controller_addr, i);
            let rel_weight = gauge_controller::get_gauge_relative_weight(controller_addr, g_id, current_time);

            let amount: u64 = if (rel_weight > 0) {
                let amt_u128 = math::wad_mul((total_epoch_budget as u128), rel_weight);
                (amt_u128 as u64)
            } else {
                0
            };

            vector::push_back(&mut allocated_g_ids, g_id);
            vector::push_back(&mut allocated_amounts, amount);
            table::add(&mut epoch_alloc_tbl, g_id, amount);
            sum_allocated = sum_allocated + amount;

            i = i + 1;
        };

        if (sum_allocated < total_epoch_budget && vector::length(&allocated_amounts) > 0) {
            let remainder = total_epoch_budget - sum_allocated;
            let first_amt = vector::borrow_mut(&mut allocated_amounts, 0);
            *first_amt = *first_amt + remainder;
            let first_g_id = *vector::borrow(&allocated_g_ids, 0);
            let g_alloc_ref = table::borrow_mut(&mut epoch_alloc_tbl, first_g_id);
            *g_alloc_ref = *g_alloc_ref + remainder;
            sum_allocated = total_epoch_budget;
        };

        table::add(&mut state.epoch_emissions, current_epoch_time, total_epoch_budget);
        table::add(&mut state.gauge_allocations, current_epoch_time, epoch_alloc_tbl);
        state.last_distribution_epoch = current_epoch_time;
        state.total_emitted = state.total_emitted + (sum_allocated as u128);

        event::emit_event(&mut state.distribution_events, EmissionDistributedEvent {
            epoch: current_epoch_time,
            total_emission: total_epoch_budget,
            gauge_ids: allocated_g_ids,
            allocated_amounts,
            timestamp: current_time,
        });

        (total_epoch_budget, allocated_g_ids, allocated_amounts)
    }

    // ==========================================
    // View Functions
    // ==========================================

    public fun get_epoch_emission(distributor_addr: address, epoch_time: u64): u64 acquires DistributorState {
        assert!(exists<DistributorState>(distributor_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<DistributorState>(distributor_addr);
        if (table::contains(&state.epoch_emissions, epoch_time)) {
            *table::borrow(&state.epoch_emissions, epoch_time)
        } else {
            0
        }
    }

    public fun get_gauge_allocation(
        distributor_addr: address,
        epoch_time: u64,
        gauge_id: u64
    ): u64 acquires DistributorState {
        assert!(exists<DistributorState>(distributor_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<DistributorState>(distributor_addr);
        if (table::contains(&state.gauge_allocations, epoch_time)) {
            let tbl = table::borrow(&state.gauge_allocations, epoch_time);
            if (table::contains(tbl, gauge_id)) {
                *table::borrow(tbl, gauge_id)
            } else {
                0
            }
        } else {
            0
        }
    }

    public fun get_last_distribution_epoch(distributor_addr: address): u64 acquires DistributorState {
        assert!(exists<DistributorState>(distributor_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<DistributorState>(distributor_addr);
        state.last_distribution_epoch
    }

    public fun get_total_emitted(distributor_addr: address): u128 acquires DistributorState {
        assert!(exists<DistributorState>(distributor_addr), ERR_NOT_INITIALIZED);
        let state = borrow_global<DistributorState>(distributor_addr);
        state.total_emitted
    }
}
