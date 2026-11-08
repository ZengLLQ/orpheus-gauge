#[test_only]
module orpheus_gauge::emission_distributor_tests {
    use std::signer;
    use std::vector;
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::voting_escrow;
    use orpheus_gauge::gauge_controller;
    use orpheus_gauge::emission_distributor;

    #[test(admin = @orpheus_gauge, alice = @0x101)]
    fun test_emission_distribution_lifecycle(admin: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        let alice_addr = signer::address_of(alice);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(alice_addr);

        voting_escrow::initialize(admin);
        gauge_controller::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();

        // 1,000,000 tokens base emission, 100 bps (1%) decay, 100,000 floor
        emission_distributor::initialize(admin, 1000000, 100, 100000, t_start);

        // Add 2 gauges
        gauge_controller::add_gauge(admin, admin_addr, 1, @0x201, 1, t_start);
        gauge_controller::add_gauge(admin, admin_addr, 2, @0x202, 1, t_start);

        // Alice locks and votes 70% to Gauge 1 and 30% to Gauge 2
        voting_escrow::create_lock(alice, admin_addr, 100000, week * 52, t_start);

        let g_ids = vector::empty<u64>();
        vector::push_back(&mut g_ids, 1);
        vector::push_back(&mut g_ids, 2);

        let weights = vector::empty<u64>();
        vector::push_back(&mut weights, 7000); // 70%
        vector::push_back(&mut weights, 3000); // 30%

        gauge_controller::vote_for_gauge_weights(alice, admin_addr, admin_addr, g_ids, weights, t_start);

        // Distribute emissions for epoch 1
        let (total_budget, dist_g_ids, dist_amounts) = emission_distributor::distribute_epoch_emissions(
            admin_addr,
            admin_addr,
            t_start
        );

        assert!(total_budget == 1000000, 101);
        assert!(vector::length(&dist_g_ids) == 2, 102);

        let amt1 = *vector::borrow(&dist_amounts, 0);
        let amt2 = *vector::borrow(&dist_amounts, 1);

        // Gauge 1 should receive 700,000 (70%)
        let diff1 = if (amt1 > 700000) { amt1 - 700000 } else { 700000 - amt1 };
        assert!(diff1 <= 10, 103);

        // Gauge 2 should receive 300,000 (30%)
        let diff2 = if (amt2 > 300000) { amt2 - 300000 } else { 300000 - amt2 };
        assert!(diff2 <= 10, 104);

        assert!(amt1 + amt2 == total_budget, 105);
        assert!(emission_distributor::get_total_emitted(admin_addr) == (total_budget as u128), 106);
    }

    #[test]
    fun test_emission_decay_schedule() {
        let base: u64 = 1000000;
        let decay_bps: u64 = 100; // 1%
        let floor: u64 = 100000;

        let e0 = emission_distributor::calculate_emission_for_epoch(base, decay_bps, floor, 0);
        assert!(e0 == 1000000, 201);

        let e1 = emission_distributor::calculate_emission_for_epoch(base, decay_bps, floor, 1);
        assert!(e1 == 990000, 202); // 1,000,000 * 0.99 = 990,000

        let e2 = emission_distributor::calculate_emission_for_epoch(base, decay_bps, floor, 2);
        assert!(e2 == 980100, 203); // 990,000 * 0.99 = 980,100

        // In the long run, floor is respected
        let e_long = emission_distributor::calculate_emission_for_epoch(base, decay_bps, floor, 300);
        assert!(e_long == floor, 204);
    }

    #[test(admin = @orpheus_gauge, alice = @0x101)]
    #[expected_failure(abort_code = 4004, location = orpheus_gauge::emission_distributor)]
    fun test_double_distribution_in_same_epoch_reverts(admin: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(signer::address_of(alice));

        voting_escrow::initialize(admin);
        gauge_controller::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();

        emission_distributor::initialize(admin, 1000000, 100, 100000, t_start);
        gauge_controller::add_gauge(admin, admin_addr, 1, @0x201, 1, t_start);
        voting_escrow::create_lock(alice, admin_addr, 50000, week * 20, t_start);

        let g_ids = vector::empty<u64>();
        vector::push_back(&mut g_ids, 1);
        let weights = vector::empty<u64>();
        vector::push_back(&mut weights, 10000);
        gauge_controller::vote_for_gauge_weights(alice, admin_addr, admin_addr, g_ids, weights, t_start);

        // First distribution succeeds
        emission_distributor::distribute_epoch_emissions(admin_addr, admin_addr, t_start);

        // Second distribution in same epoch aborts with ERR_EPOCH_ALREADY_DISTRIBUTED (4004)
        emission_distributor::distribute_epoch_emissions(admin_addr, admin_addr, t_start + 1000);
    }
}
