#[test_only]
module orpheus_gauge::gauge_controller_tests {
    use std::signer;
    use std::vector;
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::voting_escrow;
    use orpheus_gauge::gauge_controller;

    #[test(admin = @orpheus_gauge, alice = @0x101, bob = @0x102)]
    fun test_gauge_voting_and_relative_weights(admin: &signer, alice: &signer, bob: &signer) {
        let admin_addr = signer::address_of(admin);
        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(alice_addr);
        account::create_account_for_test(bob_addr);

        voting_escrow::initialize(admin);
        gauge_controller::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();

        // Add 3 gauges
        gauge_controller::add_gauge(admin, admin_addr, 1, @0x201, 1, t_start);
        gauge_controller::add_gauge(admin, admin_addr, 2, @0x202, 1, t_start);
        gauge_controller::add_gauge(admin, admin_addr, 3, @0x203, 1, t_start);

        assert!(gauge_controller::get_gauge_count(admin_addr) == 3, 101);

        // Alice locks 100,000 tokens for 52 weeks
        voting_escrow::create_lock(alice, admin_addr, 100000, week * 52, t_start);
        // Bob locks 100,000 tokens for 52 weeks
        voting_escrow::create_lock(bob, admin_addr, 100000, week * 52, t_start);

        // Alice votes 50% to Gauge 1 and 50% to Gauge 2
        let alice_g_ids = vector::empty<u64>();
        vector::push_back(&mut alice_g_ids, 1);
        vector::push_back(&mut alice_g_ids, 2);

        let alice_weights = vector::empty<u64>();
        vector::push_back(&mut alice_weights, 5000); // 50%
        vector::push_back(&mut alice_weights, 5000); // 50%

        gauge_controller::vote_for_gauge_weights(alice, admin_addr, admin_addr, alice_g_ids, alice_weights, t_start);

        // Bob votes 30% to Gauge 1 and 70% to Gauge 3
        let bob_g_ids = vector::empty<u64>();
        vector::push_back(&mut bob_g_ids, 1);
        vector::push_back(&mut bob_g_ids, 3);

        let bob_weights = vector::empty<u64>();
        vector::push_back(&mut bob_weights, 3000); // 30%
        vector::push_back(&mut bob_weights, 7000); // 70%

        gauge_controller::vote_for_gauge_weights(bob, admin_addr, admin_addr, bob_g_ids, bob_weights, t_start);

        let w1 = gauge_controller::get_gauge_weight(admin_addr, 1, t_start);
        let w2 = gauge_controller::get_gauge_weight(admin_addr, 2, t_start);
        let w3 = gauge_controller::get_gauge_weight(admin_addr, 3, t_start);
        let total_w = gauge_controller::get_total_weight(admin_addr, t_start);

        assert!(w1 > 0, 102);
        assert!(w2 > 0, 103);
        assert!(w3 > 0, 104);
        assert!(total_w == w1 + w2 + w3, 105);

        // Relative weights
        let rw1 = gauge_controller::get_gauge_relative_weight(admin_addr, 1, t_start);
        let rw2 = gauge_controller::get_gauge_relative_weight(admin_addr, 2, t_start);
        let rw3 = gauge_controller::get_gauge_relative_weight(admin_addr, 3, t_start);

        let wad = math::scale_wad();
        // rw1 should be approx 40% (0.4 * 1e18)
        let expected_rw1 = (wad * 4) / 10;
        let diff1 = if (rw1 > expected_rw1) { rw1 - expected_rw1 } else { expected_rw1 - rw1 };
        assert!(diff1 <= 10000000000000, 106); // Within 1e-5 tolerance

        // rw2 should be approx 25% (0.25 * 1e18)
        let expected_rw2 = (wad * 25) / 100;
        let diff2 = if (rw2 > expected_rw2) { rw2 - expected_rw2 } else { expected_rw2 - rw2 };
        assert!(diff2 <= 10000000000000, 107);

        // rw3 should be approx 35% (0.35 * 1e18)
        let expected_rw3 = (wad * 35) / 100;
        let diff3 = if (rw3 > expected_rw3) { rw3 - expected_rw3 } else { expected_rw3 - rw3 };
        assert!(diff3 <= 10000000000000, 108);

        // Sum of relative weights equals 100% (WAD)
        let sum_rw = rw1 + rw2 + rw3;
        let diff_sum = if (sum_rw > wad) { sum_rw - wad } else { wad - sum_rw };
        assert!(diff_sum <= 10000000000000, 109);
    }

    #[test(admin = @orpheus_gauge, alice = @0x101)]
    #[expected_failure(abort_code = 3010, location = orpheus_gauge::gauge_controller)]
    fun test_vote_cooldown_reverts(admin: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(signer::address_of(alice));

        voting_escrow::initialize(admin);
        gauge_controller::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();

        gauge_controller::add_gauge(admin, admin_addr, 1, @0x201, 1, t_start);
        voting_escrow::create_lock(alice, admin_addr, 10000, week * 20, t_start);

        let g_ids = vector::empty<u64>();
        vector::push_back(&mut g_ids, 1);
        let weights = vector::empty<u64>();
        vector::push_back(&mut weights, 10000);

        // Vote at t_start
        gauge_controller::vote_for_gauge_weights(alice, admin_addr, admin_addr, g_ids, weights, t_start);

        // Attempt second vote within 2 days (less than 1 week) -> aborts with ERR_VOTE_COOLDOWN_ACTIVE (3010)
        gauge_controller::vote_for_gauge_weights(alice, admin_addr, admin_addr, g_ids, weights, t_start + 172800);
    }

    #[test(admin = @orpheus_gauge, alice = @0x101)]
    #[expected_failure(abort_code = 3008, location = orpheus_gauge::gauge_controller)]
    fun test_vote_exceeding_100_percent_reverts(admin: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(signer::address_of(alice));

        voting_escrow::initialize(admin);
        gauge_controller::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();

        gauge_controller::add_gauge(admin, admin_addr, 1, @0x201, 1, t_start);
        gauge_controller::add_gauge(admin, admin_addr, 2, @0x202, 1, t_start);
        voting_escrow::create_lock(alice, admin_addr, 10000, week * 20, t_start);

        let g_ids = vector::empty<u64>();
        vector::push_back(&mut g_ids, 1);
        vector::push_back(&mut g_ids, 2);

        let weights = vector::empty<u64>();
        vector::push_back(&mut weights, 6000);
        vector::push_back(&mut weights, 5000); // 60% + 50% = 110% > 100%

        // Aborts with ERR_VOTE_WEIGHTS_EXCEED_100_PERCENT (3008)
        gauge_controller::vote_for_gauge_weights(alice, admin_addr, admin_addr, g_ids, weights, t_start);
    }
}
