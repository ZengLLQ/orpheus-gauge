#[test_only]
module orpheus_gauge::voting_escrow_tests {
    use std::signer;
    use aptos_framework::account;
    use orpheus_gauge::math;
    use orpheus_gauge::voting_escrow;

    #[test(admin = @orpheus_gauge, alice = @0x101, bob = @0x102)]
    fun test_lock_lifecycle_and_decay(admin: &signer, alice: &signer, bob: &signer) {
        let admin_addr = signer::address_of(admin);
        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(alice_addr);
        account::create_account_for_test(bob_addr);

        voting_escrow::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();
        let one_year = week * 52;

        // Alice locks 100,000 tokens for 52 weeks (1 year)
        voting_escrow::create_lock(alice, admin_addr, 100000, one_year, t_start);

        assert!(voting_escrow::has_lock(admin_addr, alice_addr), 101);
        let (amt, end) = voting_escrow::get_lock(admin_addr, alice_addr);
        assert!(amt == 100000, 102);
        assert!(end == math::round_to_week(t_start + one_year), 103);
        assert!(voting_escrow::get_total_locked(admin_addr) == 100000, 104);

        // Initial voting power > 0
        let vp_start = voting_escrow::get_voting_power(admin_addr, alice_addr, t_start);
        assert!(vp_start > 0, 105);

        // Total voting power at start matches Alice's power
        let total_vp_start = voting_escrow::get_total_voting_power(admin_addr, t_start);
        assert!(total_vp_start == vp_start, 106);

        // Advance to 26 weeks (halfway through lock)
        let t_half = t_start + (week * 26);
        let vp_half = voting_escrow::get_voting_power(admin_addr, alice_addr, t_half);
        assert!(vp_half > 0, 107);
        assert!(vp_half < vp_start, 108);

        // Check halfway decay ratio (approx 50% decay)
        let diff = if (vp_start / 2 > vp_half) { (vp_start / 2) - vp_half } else { vp_half - (vp_start / 2) };
        assert!(diff <= (vp_start / 50), 109); // within 2% margin

        // At expiration time, voting power is 0
        let vp_end = voting_escrow::get_voting_power(admin_addr, alice_addr, end);
        assert!(vp_end == 0, 110);
        assert!(voting_escrow::is_lock_expired(admin_addr, alice_addr, end), 111);

        // Withdraw post expiration
        let withdrawn = voting_escrow::withdraw(alice, admin_addr, end + 10);
        assert!(withdrawn == 100000, 112);
        assert!(!voting_escrow::has_lock(admin_addr, alice_addr), 113);
        assert!(voting_escrow::get_total_locked(admin_addr) == 0, 114);
    }

    #[test(admin = @orpheus_gauge, alice = @0x101)]
    fun test_increase_amount(admin: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        let alice_addr = signer::address_of(alice);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(alice_addr);

        voting_escrow::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();

        voting_escrow::create_lock(alice, admin_addr, 50000, week * 52, t_start);
        let vp1 = voting_escrow::get_voting_power(admin_addr, alice_addr, t_start);

        // At week 10, Alice adds 50,000 more tokens
        let t_step = t_start + (week * 10);
        voting_escrow::increase_amount(alice, admin_addr, 50000, t_step);

        let (amt, _) = voting_escrow::get_lock(admin_addr, alice_addr);
        assert!(amt == 100000, 201);
        assert!(voting_escrow::get_total_locked(admin_addr) == 100000, 202);

        let vp2 = voting_escrow::get_voting_power(admin_addr, alice_addr, t_step);
        // After adding 50k tokens, voting power at week 10 must be higher than before adding
        let vp_before_add = math::calculate_weight_at(vp1, math::calculate_slope(50000), t_start, t_step);
        assert!(vp2 > vp_before_add, 203);
    }

    #[test(admin = @orpheus_gauge, bob = @0x102)]
    fun test_extend_lock_duration(admin: &signer, bob: &signer) {
        let admin_addr = signer::address_of(admin);
        let bob_addr = signer::address_of(bob);

        account::create_account_for_test(admin_addr);
        account::create_account_for_test(bob_addr);

        voting_escrow::initialize(admin);

        let t_start: u64 = 1700000000;
        let week = math::week();

        // Bob locks for 26 weeks
        voting_escrow::create_lock(bob, admin_addr, 80000, week * 26, t_start);
        let (_, old_end) = voting_escrow::get_lock(admin_addr, bob_addr);

        // At week 5, Bob extends lock to 104 weeks (2 years)
        let t_extend = t_start + (week * 5);
        let vp_before = voting_escrow::get_voting_power(admin_addr, bob_addr, t_extend);

        voting_escrow::extend_lock_duration(bob, admin_addr, week * 104, t_extend);
        let (_, new_end) = voting_escrow::get_lock(admin_addr, bob_addr);
        assert!(new_end > old_end, 301);

        let vp_after = voting_escrow::get_voting_power(admin_addr, bob_addr, t_extend);
        assert!(vp_after > vp_before, 302);
    }

    #[test(admin = @orpheus_gauge, alice = @0x101)]
    #[expected_failure(abort_code = 2010, location = orpheus_gauge::voting_escrow)]
    fun test_early_withdraw_reverts(admin: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(signer::address_of(alice));

        voting_escrow::initialize(admin);
        let t_start: u64 = 1700000000;
        let week = math::week();

        voting_escrow::create_lock(alice, admin_addr, 10000, week * 10, t_start);

        // Attempt withdrawal at week 5 before expiration -> must abort with ERR_LOCK_NOT_EXPIRED (2010)
        voting_escrow::withdraw(alice, admin_addr, t_start + (week * 5));
    }

    #[test(admin = @orpheus_gauge, alice = @0x101)]
    #[expected_failure(abort_code = 2007, location = orpheus_gauge::voting_escrow)]
    fun test_duplicate_lock_reverts(admin: &signer, alice: &signer) {
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(signer::address_of(alice));

        voting_escrow::initialize(admin);
        let t_start: u64 = 1700000000;
        let week = math::week();

        voting_escrow::create_lock(alice, admin_addr, 10000, week * 10, t_start);
        // Duplicate lock must abort with ERR_LOCK_ALREADY_EXISTS (2007)
        voting_escrow::create_lock(alice, admin_addr, 20000, week * 20, t_start);
    }
}
