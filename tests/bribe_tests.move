#[test_only]
module orpheus_gauge::bribe_tests {
    use std::signer;
    use std::vector;
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::voting_escrow;
    use orpheus_gauge::gauge_controller;
    use orpheus_gauge::bribe_marketplace;

    #[test(admin = @orpheus_gauge, sponsor = @0x301, alice = @0x101, bob = @0x102)]
    fun test_bribe_deposit_and_proportional_claim(
        admin: &signer,
        sponsor: &signer,
        alice: &signer,
        bob: &signer
    ) {
        let admin_addr = signer::address_of(admin);
        let sponsor_addr = signer::address_of(sponsor);
        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(sponsor_addr);
        account::create_account_for_test(alice_addr);
        account::create_account_for_test(bob_addr);

        voting_escrow::initialize(admin);
        gauge_controller::initialize(admin);
        bribe_marketplace::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();
        let target_epoch = math::round_to_week(t_start + (week * 2));

        // Register Gauge 1
        gauge_controller::add_gauge(admin, admin_addr, 1, @0x201, 1, t_start);

        // Alice locks 50,000 tokens for 52 weeks
        voting_escrow::create_lock(alice, admin_addr, 50000, week * 52, t_start);
        // Bob locks 30,000 tokens for 52 weeks
        voting_escrow::create_lock(bob, admin_addr, 30000, week * 52, t_start);

        // Both Alice and Bob vote 100% of their power to Gauge 1
        let g_ids = vector::empty<u64>();
        vector::push_back(&mut g_ids, 1);
        let weights = vector::empty<u64>();
        vector::push_back(&mut weights, 10000);

        gauge_controller::vote_for_gauge_weights(alice, admin_addr, admin_addr, g_ids, weights, t_start);
        gauge_controller::vote_for_gauge_weights(bob, admin_addr, admin_addr, g_ids, weights, t_start);

        // External sponsor deposits two bribes for Gauge 1 targeting `target_epoch`:
        // Bribe Token 1 (e.g. USDC): 80,000 units
        // Bribe Token 2 (e.g. PROTOCOL): 40,000 units
        bribe_marketplace::deposit_bribe(sponsor, admin_addr, 1, target_epoch, 1, 80000, t_start);
        bribe_marketplace::deposit_bribe(sponsor, admin_addr, 1, target_epoch, 2, 40000, t_start);

        let (b1_tot, b1_claimed) = bribe_marketplace::get_bribe_pool_info(admin_addr, target_epoch, 1, 1);
        assert!(b1_tot == 80000, 101);
        assert!(b1_claimed == 0, 102);

        // Advance to target_epoch
        let t_claim = target_epoch + 100;

        // Alice claims Token 1 bribe:
        // Alice has 50k lock vs Bob's 30k lock -> Alice owns 5/8 (62.5%) of the vote
        // Alice reward: 80,000 * 5/8 = 50,000
        let a_reward_1 = bribe_marketplace::claim_bribe(alice, admin_addr, admin_addr, 1, target_epoch, 1, t_claim);
        let diff_a = if (a_reward_1 > 50000) { a_reward_1 - 50000 } else { 50000 - a_reward_1 };
        assert!(diff_a <= 2, 103);
        assert!(bribe_marketplace::has_claimed(admin_addr, alice_addr, target_epoch, 1, 1), 104);

        // Bob claims Token 1 bribe:
        // Bob owns 3/8 (37.5%) of the vote
        // Bob reward: 80,000 * 3/8 = 30,000
        let b_reward_1 = bribe_marketplace::claim_bribe(bob, admin_addr, admin_addr, 1, target_epoch, 1, t_claim);
        let diff_b = if (b_reward_1 > 30000) { b_reward_1 - 30000 } else { 30000 - b_reward_1 };
        assert!(diff_b <= 2, 105);
        assert!(bribe_marketplace::has_claimed(admin_addr, bob_addr, target_epoch, 1, 1), 106);

        // Total Token 1 claimed
        let (_, b1_final_claimed) = bribe_marketplace::get_bribe_pool_info(admin_addr, target_epoch, 1, 1);
        assert!(b1_final_claimed == a_reward_1 + b_reward_1, 107);
        assert!(b1_final_claimed <= 80000 && 80000 - b1_final_claimed <= 10, 108);

        // Alice claims Token 2 bribe: 40,000 * 5/8 = 25,000
        let a_reward_2 = bribe_marketplace::claim_bribe(alice, admin_addr, admin_addr, 1, target_epoch, 2, t_claim);
        let diff_a2 = if (a_reward_2 > 25000) { a_reward_2 - 25000 } else { 25000 - a_reward_2 };
        assert!(diff_a2 <= 2, 109);

        // Bob claims Token 2 bribe: 40,000 * 3/8 = 15,000
        let b_reward_2 = bribe_marketplace::claim_bribe(bob, admin_addr, admin_addr, 1, target_epoch, 2, t_claim);
        let diff_b2 = if (b_reward_2 > 15000) { b_reward_2 - 15000 } else { 15000 - b_reward_2 };
        assert!(diff_b2 <= 2, 110);

        // Total Token 2 claimed
        let (_, b2_final_claimed) = bribe_marketplace::get_bribe_pool_info(admin_addr, target_epoch, 1, 2);
        assert!(b2_final_claimed == a_reward_2 + b_reward_2, 111);
        assert!(b2_final_claimed <= 40000 && 40000 - b2_final_claimed <= 10, 112);
    }

    #[test(admin = @orpheus_gauge, sponsor = @0x301, alice = @0x101)]
    #[expected_failure(abort_code = 6007, location = orpheus_gauge::bribe_marketplace)]
    fun test_double_claim_reverts(admin: &signer, sponsor: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(signer::address_of(sponsor));
        account::create_account_for_test(signer::address_of(alice));

        voting_escrow::initialize(admin);
        gauge_controller::initialize(admin);
        bribe_marketplace::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();
        let target_epoch = math::round_to_week(t_start + week);

        gauge_controller::add_gauge(admin, admin_addr, 1, @0x201, 1, t_start);
        voting_escrow::create_lock(alice, admin_addr, 50000, week * 20, t_start);

        let g_ids = vector::empty<u64>();
        vector::push_back(&mut g_ids, 1);
        let weights = vector::empty<u64>();
        vector::push_back(&mut weights, 10000);
        gauge_controller::vote_for_gauge_weights(alice, admin_addr, admin_addr, g_ids, weights, t_start);

        bribe_marketplace::deposit_bribe(sponsor, admin_addr, 1, target_epoch, 1, 10000, t_start);

        // First claim succeeds
        bribe_marketplace::claim_bribe(alice, admin_addr, admin_addr, 1, target_epoch, 1, target_epoch + 10);

        // Second claim aborts with ERR_ALREADY_CLAIMED (6007)
        bribe_marketplace::claim_bribe(alice, admin_addr, admin_addr, 1, target_epoch, 1, target_epoch + 10);
    }
}
