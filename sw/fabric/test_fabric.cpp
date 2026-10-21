// =============================================================================
// test_fabric.cpp -- Layer 13 and Layer 17 tests
//
// Layer 13 asserts the property that matters: the sum is bit-identical for
// every permutation of the addends, including blocks chosen so that naive
// FP32 addition demonstrably is not.
//
// Layer 17 asserts that each extracted matrix really is a permutation, that
// the weights sum to one, and that the decomposition reconstructs the input.
// =============================================================================

#include "l13_repro_sum.hpp"
#include "l17_bvn_scheduler.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <numeric>
#include <random>
#include <vector>

using namespace lightrail::fabric;

namespace {

int g_checks = 0;
int g_errors = 0;

void check(bool cond, const char* what) {
    ++g_checks;
    if (!cond) { ++g_errors; std::printf("FAIL: %s\n", what); }
}

float repro_sum(const std::vector<float>& xs) {
    ReproSum::Accumulator acc{};
    ReproSum::add_span(acc, xs);
    return ReproSum::to_float(acc);
}

float naive_sum(const std::vector<float>& xs) {
    float s = 0.0f;
    for (float x : xs) s += x;
    return s;
}

}  // namespace

static void test_layer13() {
    std::printf("--- Layer 13: reproducible summation ---\n");

    // Classic catastrophic-cancellation block: one huge value, many small
    // ones, then the huge value removed. Naive FP32 loses the small terms.
    {
        std::vector<float> xs{1.0e8f};
        for (int i = 0; i < 100; ++i) xs.push_back(1.0f);
        xs.push_back(-1.0e8f);

        auto rev = xs; std::reverse(rev.begin(), rev.end());

        const float r_fwd = repro_sum(xs);
        const float r_rev = repro_sum(rev);
        const float n_fwd = naive_sum(xs);
        const float n_rev = naive_sum(rev);

        check(r_fwd == r_rev, "repro sum identical forward and reversed");
        check(r_fwd == 100.0f, "repro sum is exactly 100");
        std::printf("  repro: fwd=%.1f rev=%.1f   naive: fwd=%.1f rev=%.1f\n",
                    r_fwd, r_rev, n_fwd, n_rev);
        check(n_fwd != r_fwd || n_rev != r_fwd,
              "naive FP32 differs from the exact sum (shows the problem is real)");
    }

    // Order independence over many random shuffles, wide dynamic range.
    {
        std::mt19937 rng(12345);
        std::uniform_real_distribution<float> mag(-1.0f, 1.0f);
        std::uniform_int_distribution<int>    sc(-30, 30);

        std::vector<float> xs;
        for (int i = 0; i < 500; ++i)
            xs.push_back(std::ldexp(mag(rng), sc(rng)));

        const float ref = repro_sum(xs);
        bool all_same   = true;
        bool naive_varied = false;
        const float naive_ref = naive_sum(xs);

        for (int t = 0; t < 50; ++t) {
            std::shuffle(xs.begin(), xs.end(), rng);
            if (repro_sum(xs) != ref)    all_same = false;
            if (naive_sum(xs) != naive_ref) naive_varied = true;
        }
        check(all_same, "repro sum identical across 50 random shuffles");
        check(naive_varied,
              "naive FP32 sum DID vary across shuffles (contrast holds)");
    }

    // Accumulator merge is what a ring reduction does: partial sums combined
    // in any order must match a single-pass sum.
    {
        std::mt19937 rng(999);
        std::uniform_real_distribution<float> d(-1000.0f, 1000.0f);
        std::vector<float> xs(256);
        for (float& x : xs) x = d(rng);

        ReproSum::Accumulator whole{};
        ReproSum::add_span(whole, xs);

        ReproSum::Accumulator a{}, b{}, c{}, dd{};
        ReproSum::add_span(a,  std::span(xs).subspan(0, 64));
        ReproSum::add_span(b,  std::span(xs).subspan(64, 64));
        ReproSum::add_span(c,  std::span(xs).subspan(128, 64));
        ReproSum::add_span(dd, std::span(xs).subspan(192, 64));

        // Merge in two different orders.
        ReproSum::Accumulator m1 = a; ReproSum::add(m1, b);
        ReproSum::add(m1, c); ReproSum::add(m1, dd);

        ReproSum::Accumulator m2 = dd; ReproSum::add(m2, c);
        ReproSum::add(m2, b); ReproSum::add(m2, a);

        check(m1 == whole, "merged partials equal a single-pass accumulation");
        check(m1 == m2,    "merge order does not change the accumulator");
    }

    // Extremes of the FP32 range must not be dropped -- this is exactly what
    // a 128-bit accumulator gets wrong.
    {
        ReproSum::Accumulator acc{};
        const float tiny = std::ldexp(1.0f, -149);   // smallest subnormal
        const float big  = std::ldexp(1.0f, 100);
        ReproSum::add_float(acc, big);
        ReproSum::add_float(acc, tiny);
        ReproSum::add_float(acc, -big);
        check(ReproSum::to_float(acc) == tiny,
              "2^-149 survives alongside 2^100 (needs >128-bit accumulator)");
    }

    // Inf and NaN are reported, not silently folded in.
    {
        ReproSum::Accumulator acc{};
        check(!ReproSum::add_float(acc, INFINITY), "Inf rejected");
        check(!ReproSum::add_float(acc, NAN),      "NaN rejected");
        check(acc.is_zero(), "rejected values left the accumulator untouched");
    }

    // Signed zero and exact round-trip of simple values.
    {
        ReproSum::Accumulator acc{};
        ReproSum::add_float(acc, 0.5f);
        ReproSum::add_float(acc, 0.25f);
        ReproSum::add_float(acc, 0.125f);
        check(ReproSum::to_float(acc) == 0.875f, "exact dyadic sum round-trips");
    }
}

static void test_layer17() {
    std::printf("--- Layer 17: Birkhoff-von Neumann decomposition ---\n");

    auto is_permutation = [](const std::vector<uint32_t>& p, size_t n) {
        if (p.size() != n) return false;
        std::vector<char> seen(n, 0);
        for (uint32_t v : p) {
            if (v >= n || seen[v]) return false;
            seen[v] = 1;
        }
        return true;
    };

    auto verify = [&](std::vector<double> m, size_t n, const char* label) {
        auto res = BvnScheduler::decompose(m, n);
        if (!res) {
            ++g_errors; ++g_checks;
            std::printf("FAIL: %s decompose failed: %s\n",
                        label, std::string(to_string(res.error())).c_str());
            return;
        }
        const auto& slots = *res;

        bool perms_ok = true;
        double wsum = 0.0;
        for (const auto& s : slots) {
            if (!is_permutation(s.port_map, n)) perms_ok = false;
            if (s.weight <= 0.0) perms_ok = false;
            wsum += s.weight;
        }
        check(perms_ok, (std::string(label) + ": every slot is a valid permutation").c_str());
        check(std::fabs(wsum - 1.0) < 1e-6,
              (std::string(label) + ": weights sum to 1").c_str());

        const auto recon = BvnScheduler::reconstruct(slots, n);
        double worst = 0.0;
        for (size_t i = 0; i < n * n; ++i)
            worst = std::max(worst, std::fabs(recon[i] - m[i]));
        check(worst < 1e-6,
              (std::string(label) + ": reconstruction matches the input").c_str());

        check(slots.size() <= n * n - 2 * n + 2,
              (std::string(label) + ": slot count within Birkhoff's bound").c_str());

        std::printf("  %-18s n=%zu slots=%zu  weight_sum=%.9f  max_err=%.2e\n",
                    label, n, slots.size(), wsum, worst);
    };

    // Identity: one slot, weight 1.
    {
        const size_t n = 4;
        std::vector<double> m(n * n, 0.0);
        for (size_t i = 0; i < n; ++i) m[i * n + i] = 1.0;
        verify(m, n, "identity");
    }

    // Uniform: every entry 1/n, needs n slots.
    {
        const size_t n = 5;
        std::vector<double> m(n * n, 1.0 / static_cast<double>(n));
        verify(m, n, "uniform");
    }

    // A permutation matrix other than the identity.
    {
        const size_t n = 4;
        std::vector<double> m(n * n, 0.0);
        const uint32_t p[4] = {2, 0, 3, 1};
        for (size_t i = 0; i < n; ++i) m[i * n + p[i]] = 1.0;
        verify(m, n, "single permutation");
    }

    // Random doubly stochastic, built by Sinkhorn from random positives.
    {
        std::mt19937 rng(4242);
        std::uniform_real_distribution<double> d(0.1, 1.0);
        for (size_t n : {3u, 6u, 8u}) {
            std::vector<double> m(n * n);
            for (double& x : m) x = d(rng);
            const bool ok = BvnScheduler::normalize(m, n);
            check(ok, "Sinkhorn normalisation converged");
            if (ok) verify(m, n, "random doubly stochastic");
        }
    }

    // Input validation: a matrix that is not doubly stochastic is refused,
    // rather than returning a schedule that does not reconstruct it.
    {
        const size_t n = 3;
        std::vector<double> m(n * n, 0.0);
        m[0] = 1.0; m[4] = 1.0;              // column 2 and row 2 sum to 0
        auto res = BvnScheduler::decompose(m, n);
        check(!res, "non-doubly-stochastic input refused");
        check(!res && res.error() == BvnError::NotDoublyStochastic,
              "refusal reports NotDoublyStochastic");
    }

    // Degenerate inputs.
    {
        std::vector<double> empty;
        check(!BvnScheduler::decompose(empty, 0), "n=0 refused");
        std::vector<double> wrong(5, 0.0);
        check(!BvnScheduler::decompose(wrong, 3), "wrong-sized matrix refused");

        std::vector<double> zero_row(9, 0.0);
        check(!BvnScheduler::normalize(zero_row, 3),
              "Sinkhorn refuses a matrix with a zero row");
    }
}

int main() {
    test_layer13();
    test_layer17();

    std::printf("----------------------------------------------------------\n");
    if (g_errors == 0)
        std::printf("PASS: fabric algorithms passed all %d checks.\n", g_checks);
    else
        std::printf("FAIL: fabric algorithms had %d errors in %d checks.\n",
                    g_errors, g_checks);
    std::printf("----------------------------------------------------------\n");
    return g_errors == 0 ? 0 : 1;
}
