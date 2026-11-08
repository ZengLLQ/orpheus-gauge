#[test_only]
module orpheus_gauge::math_tests {
    use orpheus_gauge::math;

    #[test]
    fun test_constants_and_scaling() {
        let wad = math::scale_wad();
        assert!(wad == 1000000000000000000, 101);

        let ray = math::scale_ray();
        assert!(ray == 1000000000000000000000000000, 102);

        let bps = math::bps_base();
        assert!(bps == 10000, 103);

        let week = math::week();
        assert!(week == 604800, 104);

        let max_lock = math::max_lock_time();
        assert!(max_lock == 126144000, 105);

        let min_lock = math::min_lock_time();
        assert!(min_lock == 604800, 106);
    }

    #[test]
    fun test_fixed_point_arithmetic() {
        let wad = math::scale_wad();

        // 2.5 * 4.0 = 10.0 in WAD
        let a = (25 * wad) / 10;
        let b = 4 * wad;
        let c = math::wad_mul(a, b);
        assert!(c == 10 * wad, 201);

        // 10.0 / 4.0 = 2.5 in WAD
        let d = math::wad_div(c, b);
        assert!(d == a, 202);

        // mul_div_u128
        let res = math::mul_div_u128(100, 50, 20);
        assert!(res == 250, 203);

        // mul_div_u64
        let res64 = math::mul_div_u64(1000, 300, 150);
        assert!(res64 == 2000, 204);

        // min / max helpers
        assert!(math::min_u64(10, 20) == 10, 205);
        assert!(math::max_u64(10, 20) == 20, 206);
        assert!(math::min_u128(100, 200) == 100, 207);
        assert!(math::max_u128(100, 200) == 200, 208);
    }

    #[test]
    fun test_week_rounding() {
        let week = math::week();
        let t1 = 1700000000;
        let rounded = math::round_to_week(t1);
        assert!(rounded % week == 0, 301);
        assert!(rounded <= t1, 302);
        assert!(t1 - rounded < week, 303);
    }

    #[test]
    fun test_slope_and_bias_decay() {
        let max_lock = math::max_lock_time();
        let amount: u64 = 1000000; // 1M tokens
        let slope = math::calculate_slope(amount);
        assert!(slope > 0, 401);

        let t_start: u64 = 10000000;
        let t_unlock: u64 = t_start + max_lock; // 4-year lock

        let initial_bias = math::calculate_bias(slope, t_unlock, t_start);
        assert!(initial_bias > 0, 402);

        // At midpoint (2 years in), remaining voting power should be exactly half
        let t_mid = t_start + (max_lock / 2);
        let mid_weight = math::calculate_weight_at(initial_bias, slope, t_start, t_mid);
        let expected_mid = initial_bias / 2;
        let diff = if (mid_weight > expected_mid) { mid_weight - expected_mid } else { expected_mid - mid_weight };
        assert!(diff <= 10, 403); // Rounding error within 10 wei

        // At unlock time, weight should be exactly 0
        let end_weight = math::calculate_weight_at(initial_bias, slope, t_start, t_unlock);
        assert!(end_weight == 0, 404);

        // Past unlock time, weight stays 0
        let past_weight = math::calculate_weight_at(initial_bias, slope, t_start, t_unlock + 10000);
        assert!(past_weight == 0, 405);
    }

    #[test]
    fun test_curve_boost_dynamics() {
        let lp_amount: u64 = 10000; // 10k LP tokens
        let total_lp: u64 = 50000;  // 50k total LP tokens

        // Case 1: Zero veToken power -> exactly 40% unboosted base
        let boost_zero = math::calculate_boost(lp_amount, total_lp, 0, 100000);
        assert!(boost_zero == 4000, 501); // 40% of 10000 = 4000

        // Case 2: User owns 100% of veToken power -> maximum boost capped at 100% of staked LP
        let boost_max = math::calculate_boost(lp_amount, total_lp, 100000, 100000);
        assert!(boost_max == (lp_amount as u128), 502); // Capped at 10000 (2.5x boost)

        // Case 3: User owns 20% of veToken power (equal to their 20% LP share)
        // ve_component = 50000 * 60% * 20% = 50000 * 0.12 = 6000
        // total boosted = 4000 (base) + 6000 (ve) = 10000 (2.5x boost)
        let boost_balanced = math::calculate_boost(lp_amount, total_lp, 20000, 100000);
        assert!(boost_balanced == 10000, 503);

        // Case 4: User owns 10% of veToken power (half their 20% LP share)
        // ve_component = 50000 * 60% * 10% = 3000
        // total boosted = 4000 (base) + 3000 = 7000 (1.75x boost)
        let boost_partial = math::calculate_boost(lp_amount, total_lp, 10000, 100000);
        assert!(boost_partial == 7000, 504);
    }
}
