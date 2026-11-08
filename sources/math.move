module orpheus_gauge::math {
    // Scaling constants for high-precision fixed-point math
    const SCALE_WAD: u128 = 1000000000000000000; // 1e18
    const SCALE_RAY: u128 = 1000000000000000000000000000; // 1e27
    const BPS_BASE: u64 = 10000; // 10,000 basis points = 100.00%
    const WEEK: u64 = 604800; // 7 days in seconds
    const MAX_LOCK_TIME: u64 = 126144000; // 4 years = 208 weeks
    const MIN_LOCK_TIME: u64 = 604800; // 1 week

    // Curve boost constants
    const BOOST_DENOMINATOR: u128 = 100;
    const BOOST_LP_FACTOR: u128 = 40; // 40% base unboosted liquidity
    const BOOST_VE_FACTOR: u128 = 60; // 60% boosted liquidity component

    // Error codes
    const ERR_DIV_BY_ZERO: u64 = 101;
    const ERR_OVERFLOW: u64 = 102;
    const ERR_INVALID_LOCK_DURATION: u64 = 103;

    public fun scale_wad(): u128 {
        SCALE_WAD
    }

    public fun scale_ray(): u128 {
        SCALE_RAY
    }

    public fun bps_base(): u64 {
        BPS_BASE
    }

    public fun week(): u64 {
        WEEK
    }

    public fun max_lock_time(): u64 {
        MAX_LOCK_TIME
    }

    public fun min_lock_time(): u64 {
        MIN_LOCK_TIME
    }

    /// Multiply two WAD numbers (18 decimals): (a * b) / 1e18
    public fun wad_mul(a: u128, b: u128): u128 {
        (a * b) / SCALE_WAD
    }

    /// Divide two WAD numbers (18 decimals): (a * 1e18) / b
    public fun wad_div(a: u128, b: u128): u128 {
        assert!(b > 0, ERR_DIV_BY_ZERO);
        (a * SCALE_WAD) / b
    }

    /// Generic 128-bit mul_div: (x * y) / z
    public fun mul_div_u128(x: u128, y: u128, z: u128): u128 {
        assert!(z > 0, ERR_DIV_BY_ZERO);
        (x * y) / z
    }

    /// Safe 64-bit mul_div via 128-bit intermediate: (x * y) / z
    public fun mul_div_u64(x: u64, y: u64, z: u64): u64 {
        assert!(z > 0, ERR_DIV_BY_ZERO);
        let prod = (x as u128) * (y as u128);
        (prod / (z as u128)) as u64
    }

    /// Round timestamp down to the nearest Thursday 00:00:00 UTC weekly epoch boundary
    public fun round_to_week(t: u64): u64 {
        (t / WEEK) * WEEK
    }

    public fun min_u64(a: u64, b: u64): u64 {
        if (a < b) { a } else { b }
    }

    public fun max_u64(a: u64, b: u64): u64 {
        if (a > b) { a } else { b }
    }

    public fun min_u128(a: u128, b: u128): u128 {
        if (a < b) { a } else { b }
    }

    public fun max_u128(a: u128, b: u128): u128 {
        if (a > b) { a } else { b }
    }

    /// Calculate slope mu = (amount * 1e18) / MAX_LOCK_TIME
    /// Preserves sub-integer precision so modest lock amounts maintain precise linear decay rates
    public fun calculate_slope(amount: u64): u128 {
        let amount_u128 = (amount as u128);
        (amount_u128 * SCALE_WAD) / (MAX_LOCK_TIME as u128)
    }

    /// Calculate initial bias beta = slope * (unlock_time - current_time) / 1e18
    public fun calculate_bias(slope: u128, unlock_time: u64, current_time: u64): u128 {
        if (unlock_time <= current_time) {
            0
        } else {
            let duration = ((unlock_time - current_time) as u128);
            (slope * duration) / SCALE_WAD
        }
    }

    /// Calculate current remaining voting weight at target_time given a point (bias, slope, point_time)
    public fun calculate_weight_at(bias: u128, slope: u128, point_time: u64, target_time: u64): u128 {
        if (target_time <= point_time) {
            bias
        } else {
            let elapsed = ((target_time - point_time) as u128);
            let decay = (slope * elapsed) / SCALE_WAD;
            if (decay >= bias) {
                0
            } else {
                bias - decay
            }
        }
    }

    /// Curve/Velodrome Boost formulation:
    /// Boosted Balance = min(staked_lp * 40% + total_staked_lp * (user_ve / total_ve) * 60%, staked_lp)
    /// Max boost = 100% / 40% = 2.5x
    public fun calculate_boost(
        staked_lp: u64,
        total_staked_lp: u64,
        user_ve: u128,
        total_ve: u128
    ): u128 {
        let lp_u128 = (staked_lp as u128);
        let base_lp = (lp_u128 * BOOST_LP_FACTOR) / BOOST_DENOMINATOR; // 40%

        if (total_ve == 0 || user_ve == 0 || total_staked_lp == 0) {
            return base_lp
        };

        let total_lp_u128 = (total_staked_lp as u128);
        // ve_ratio = user_ve / total_ve
        // ve_component = total_staked_lp * 60% * (user_ve / total_ve)
        let ve_component = (total_lp_u128 * BOOST_VE_FACTOR * user_ve) / (BOOST_DENOMINATOR * total_ve);
        let boosted = base_lp + ve_component;

        // Cap at 100% of staked LP
        min_u128(boosted, lp_u128)
    }
}
