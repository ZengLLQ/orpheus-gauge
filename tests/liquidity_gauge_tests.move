#[test_only]
module orpheus_gauge::liquidity_gauge_tests {
    use std::signer;
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::voting_escrow;
    use orpheus_gauge::liquidity_gauge;

    #[test(admin = @orpheus_gauge, alice = @0x101, bob = @0x102)]
    fun test_boosted_staking_and_rewards(admin: &signer, alice: &signer, bob: &signer) {
        let admin_addr = signer::address_of(admin);
        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(alice_addr);
        account::create_account_for_test(bob_addr);

        voting_escrow::initialize(admin);
        liquidity_gauge::initialize_gauge(admin, 1, 1700000000);

        let t_start: u64 = 1700000000;

        // Alice locks 100,000 veTokens for 4 years (max lock) -> Alice has massive veToken power
        voting_escrow::create_lock(alice, admin_addr, 100000, math::max_lock_time(), t_start);

        // Bob has NO veToken lock (0 veToken power)

        // Both Alice and Bob deposit 10,000 LP tokens into the gauge
        liquidity_gauge::deposit_lp(alice, admin_addr, admin_addr, 10000, t_start);
        liquidity_gauge::deposit_lp(bob, admin_addr, admin_addr, 10000, t_start);

        let (a_staked, a_boosted, a_unclaimed) = liquidity_gauge::get_user_position(admin_addr, alice_addr);
        let (b_staked, b_boosted, b_unclaimed) = liquidity_gauge::get_user_position(admin_addr, bob_addr);

        assert!(a_staked == 10000, 101);
        assert!(b_staked == 10000, 102);
        assert!(a_unclaimed == 0 && b_unclaimed == 0, 103);

        // Bob has 0 veToken -> gets 40% unboosted base = 4,000 boosted LP
        assert!(b_boosted == 4000, 104);

        // Alice has 100% of veToken power -> gets capped 10,000 boosted LP (2.5x boost vs Bob)
        assert!(a_boosted == 10000, 105);

        let (total_staked, total_boosted, _) = liquidity_gauge::get_pool_stats(admin_addr);
        assert!(total_staked == 20000, 106);
        assert!(total_boosted == 14000, 107); // 10,000 + 4,000 = 14,000

        // Notify gauge of 140,000 newly arrived emissions
        liquidity_gauge::notify_emission_reward(admin_addr, 140000, t_start + 1000);

        // Alice's expected reward: 10,000 / 14,000 * 140,000 = 100,000
        let a_pending = liquidity_gauge::get_pending_rewards(admin_addr, alice_addr);
        assert!(a_pending == 100000, 108);

        // Bob's expected reward: 4,000 / 14,000 * 140,000 = 40,000
        let b_pending = liquidity_gauge::get_pending_rewards(admin_addr, bob_addr);
        assert!(b_pending == 40000, 109);

        // Alice claims rewards
        let a_claimed = liquidity_gauge::claim_rewards(alice, admin_addr);
        assert!(a_claimed == 100000, 110);
        assert!(liquidity_gauge::get_pending_rewards(admin_addr, alice_addr) == 0, 111);

        // Bob claims rewards
        let b_claimed = liquidity_gauge::claim_rewards(bob, admin_addr);
        assert!(b_claimed == 40000, 112);
        assert!(liquidity_gauge::get_pending_rewards(admin_addr, bob_addr) == 0, 113);
    }

    #[test(admin = @orpheus_gauge, alice = @0x101)]
    fun test_withdraw_lp(admin: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        let alice_addr = signer::address_of(alice);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(alice_addr);

        voting_escrow::initialize(admin);
        liquidity_gauge::initialize_gauge(admin, 1, 1700000000);

        let t_start: u64 = 1700000000;
        liquidity_gauge::deposit_lp(alice, admin_addr, admin_addr, 10000, t_start);

        // Withdraw 4,000 LP tokens
        let withdrawn = liquidity_gauge::withdraw_lp(alice, admin_addr, admin_addr, 4000, t_start + 100);
        assert!(withdrawn == 4000, 201);

        let (staked, boosted, _) = liquidity_gauge::get_user_position(admin_addr, alice_addr);
        assert!(staked == 6000, 202);
        assert!(boosted == 2400, 203); // 40% of 6000 = 2400

        let (tot_staked, tot_boosted, _) = liquidity_gauge::get_pool_stats(admin_addr);
        assert!(tot_staked == 6000, 204);
        assert!(tot_boosted == 2400, 205);
    }

    #[test(admin = @orpheus_gauge, alice = @0x101, kicker = @0x103)]
    fun test_kick_expired_locker(admin: &signer, alice: &signer, kicker: &signer) {
        let admin_addr = signer::address_of(admin);
        let alice_addr = signer::address_of(alice);
        let kicker_addr = signer::address_of(kicker);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(alice_addr);
        account::create_account_for_test(kicker_addr);

        voting_escrow::initialize(admin);
        liquidity_gauge::initialize_gauge(admin, 1, 1700000000);

        let t_start: u64 = 1700000000;
        let week = math::week();

        // Alice locks for 10 weeks
        voting_escrow::create_lock(alice, admin_addr, 100000, week * 10, t_start);
        liquidity_gauge::deposit_lp(alice, admin_addr, admin_addr, 10000, t_start);

        let (_, initial_boost, _) = liquidity_gauge::get_user_position(admin_addr, alice_addr);
        assert!(initial_boost == 10000, 301);

        // Advance 12 weeks (Alice's veLock is now expired!)
        let t_after_expiry = t_start + (week * 12);

        // Kicker calls kick on Alice
        liquidity_gauge::kick(kicker, admin_addr, admin_addr, alice_addr, t_after_expiry);

        let (_, new_boost, _) = liquidity_gauge::get_user_position(admin_addr, alice_addr);
        // Alice's boost has dropped from 10,000 (2.5x) to 4,000 (1.0x base)!
        assert!(new_boost == 4000, 302);
        assert!(new_boost < initial_boost, 303);
    }
}
