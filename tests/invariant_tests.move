#[test_only]
module orpheus_gauge::invariant_tests {
    use std::signer;
    use std::vector;
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::voting_escrow;
    use orpheus_gauge::gauge_controller;
    use orpheus_gauge::emission_distributor;

    #[test]
    fun test_boost_boundary_invariants() {
        // Invariant: Boosted balance must strictly reside within [40%, 100%] of staked LP
        let staked_lp: u64 = 50000;
        let total_staked_lp: u64 = 200000;

        let ve_fractions = vector::empty<u128>();
        vector::push_back(&mut ve_fractions, 0);       // 0% ve
        vector::push_back(&mut ve_fractions, 1000);    // 1% ve
        vector::push_back(&mut ve_fractions, 10000);   // 10% ve
        vector::push_back(&mut ve_fractions, 25000);   // 25% ve
        vector::push_back(&mut ve_fractions, 50000);   // 50% ve
        vector::push_back(&mut ve_fractions, 100000);  // 100% ve
        vector::push_back(&mut ve_fractions, 500000);  // 500% ve (oversized ve share)

        let total_ve: u128 = 100000;
        let min_bound = ((staked_lp as u128) * 40) / 100;
        let max_bound = (staked_lp as u128);

        let len = vector::length(&ve_fractions);
        let i = 0;
        let prev_boost: u128 = 0;

        while (i < len) {
            let u_ve = *vector::borrow(&ve_fractions, i);
            let boost = math::calculate_boost(staked_lp, total_staked_lp, u_ve, total_ve);

            // Invariant 1: Greater or equal to 40% floor
            assert!(boost >= min_bound, 101);

            // Invariant 2: Less than or equal to 100% cap
            assert!(boost <= max_bound, 102);

            // Invariant 3: Monotonically non-decreasing with increasing ve share
            if (i > 0) {
                assert!(boost >= prev_boost, 103);
            };

            prev_boost = boost;
            i = i + 1;
        };
    }

    #[test]
    fun test_decay_monotonicity_invariant() {
        // Invariant: Voting power at any time t2 >= t1 is strictly non-increasing: w(t2) <= w(t1)
        let amount: u64 = 100000;
        let slope = math::calculate_slope(amount);
        let t_start: u64 = 1000000;
        let t_unlock: u64 = t_start + math::max_lock_time();
        let bias = math::calculate_bias(slope, t_unlock, t_start);

        let t_step = t_start;
        let prev_w = bias;

        let week = math::week();
        let i = 0;
        while (i < 50) {
            t_step = t_step + week;
            let cur_w = math::calculate_weight_at(bias, slope, t_start, t_step);

            // Non-negative
            assert!(cur_w >= 0, 201);
            // Monotonically non-increasing
            assert!(cur_w <= prev_w, 202);

            prev_w = cur_w;
            i = i + 1;
        };
    }

    #[test(admin = @orpheus_gauge, voter1 = @0x101, voter2 = @0x102, voter3 = @0x103)]
    fun test_emission_conservation_invariant(
        admin: &signer,
        voter1: &signer,
        voter2: &signer,
        voter3: &signer
    ) {
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(signer::address_of(voter1));
        account::create_account_for_test(signer::address_of(voter2));
        account::create_account_for_test(signer::address_of(voter3));

        voting_escrow::initialize(admin);
        gauge_controller::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();

        // 1,000,000 base emissions
        emission_distributor::initialize(admin, 1000000, 50, 100000, t_start);

        // Add 4 gauges
        gauge_controller::add_gauge(admin, admin_addr, 1, @0x201, 1, t_start);
        gauge_controller::add_gauge(admin, admin_addr, 2, @0x202, 1, t_start);
        gauge_controller::add_gauge(admin, admin_addr, 3, @0x203, 1, t_start);
        gauge_controller::add_gauge(admin, admin_addr, 4, @0x204, 1, t_start);

        // Three voters with diverse lock times and weights
        voting_escrow::create_lock(voter1, admin_addr, 100000, week * 52, t_start);
        voting_escrow::create_lock(voter2, admin_addr, 50000, week * 104, t_start);
        voting_escrow::create_lock(voter3, admin_addr, 200000, week * 26, t_start);

        // Voter 1 splits: 40% G1, 30% G2, 30% G3
        let v1_g = vector::empty<u64>();
        vector::push_back(&mut v1_g, 1);
        vector::push_back(&mut v1_g, 2);
        vector::push_back(&mut v1_g, 3);
        let v1_w = vector::empty<u64>();
        vector::push_back(&mut v1_w, 4000);
        vector::push_back(&mut v1_w, 3000);
        vector::push_back(&mut v1_w, 3000);
        gauge_controller::vote_for_gauge_weights(voter1, admin_addr, admin_addr, v1_g, v1_w, t_start);

        // Voter 2 splits: 20% G1, 50% G2, 30% G4
        let v2_g = vector::empty<u64>();
        vector::push_back(&mut v2_g, 1);
        vector::push_back(&mut v2_g, 2);
        vector::push_back(&mut v2_g, 4);
        let v2_w = vector::empty<u64>();
        vector::push_back(&mut v2_w, 2000);
        vector::push_back(&mut v2_w, 5000);
        vector::push_back(&mut v2_w, 3000);
        gauge_controller::vote_for_gauge_weights(voter2, admin_addr, admin_addr, v2_g, v2_w, t_start);

        // Voter 3 splits: 25% across all 4 gauges
        let v3_g = vector::empty<u64>();
        vector::push_back(&mut v3_g, 1);
        vector::push_back(&mut v3_g, 2);
        vector::push_back(&mut v3_g, 3);
        vector::push_back(&mut v3_g, 4);
        let v3_w = vector::empty<u64>();
        vector::push_back(&mut v3_w, 2500);
        vector::push_back(&mut v3_w, 2500);
        vector::push_back(&mut v3_w, 2500);
        vector::push_back(&mut v3_w, 2500);
        gauge_controller::vote_for_gauge_weights(voter3, admin_addr, admin_addr, v3_g, v3_w, t_start);

        let (total_budget, _, allocated_amounts) = emission_distributor::distribute_epoch_emissions(
            admin_addr,
            admin_addr,
            t_start
        );

        let sum_allocated: u64 = 0;
        let len = vector::length(&allocated_amounts);
        let k = 0;
        while (k < len) {
            sum_allocated = sum_allocated + *vector::borrow(&allocated_amounts, k);
            k = k + 1;
        };

        // Conservation Invariant: sum of allocations must not exceed total budget, with remainder strictly <= num_gauges wei
        assert!(sum_allocated <= total_budget, 301);
        let remainder = total_budget - sum_allocated;
        assert!(remainder <= (len as u64), 302);
    }
}
