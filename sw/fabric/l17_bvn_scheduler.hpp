// =============================================================================
// l17_bvn_scheduler.hpp -- Layer 17: Birkhoff-von Neumann traffic scheduling
//
// Decomposes a doubly stochastic demand matrix D into a convex combination of
// permutation matrices:
//
//     D = sum_k  alpha_k * P_k,     sum_k alpha_k = 1,    alpha_k > 0
//
// Each P_k is one conflict-free crossbar configuration (every input mapped to
// a distinct output), and alpha_k is the fraction of the schedule for which
// that configuration is held. Birkhoff's theorem guarantees the decomposition
// exists for any doubly stochastic matrix, and that at most n^2 - 2n + 2
// permutations are needed.
//
// Why the input must be doubly stochastic: the existence proof relies on
// Hall's condition, which holds for doubly stochastic matrices and can fail
// otherwise. decompose() therefore validates its input and reports why it
// refused rather than returning a schedule that does not reconstruct D.
// normalize() is provided to turn a raw demand matrix into a usable one.
//
// Complexity: each round runs one perfect matching (Kuhn's augmenting paths,
// O(V*E)) and removes at least one positive entry, so the loop is bounded.
// =============================================================================

#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <span>
#include <string_view>
#include <vector>

namespace lightrail::fabric {

enum class BvnError {
    NotSquare,
    Empty,
    NegativeEntry,
    NotDoublyStochastic,
    NoPerfectMatching,   // Hall's condition violated; input was not valid
    IterationLimit,
};

std::string_view to_string(BvnError e) noexcept;

// One crossbar configuration held for a fraction of the schedule.
struct TimeSlot {
    double                weight;    // alpha_k, in (0, 1]
    std::vector<uint32_t> port_map;  // port_map[in] = out, a permutation
};

class BvnScheduler {
public:
    // Tolerance for the doubly-stochastic check and for treating a residual
    // entry as zero.
    static constexpr double kEpsilon = 1e-9;

    // Decomposes a row-major n x n doubly stochastic matrix.
    [[nodiscard]] static std::expected<std::vector<TimeSlot>, BvnError>
        decompose(std::span<const double> matrix, size_t n);

    // Scales a non-negative matrix toward doubly stochastic by Sinkhorn
    // iteration. Returns false if it did not converge, which happens when the
    // matrix has a zero row or column and cannot be scaled at all.
    [[nodiscard]] static bool normalize(std::span<double> matrix, size_t n,
                                        int max_iters = 1000,
                                        double tol = 1e-12);

    // Reconstructs sum_k alpha_k * P_k, for verifying a decomposition.
    [[nodiscard]] static std::vector<double>
        reconstruct(std::span<const TimeSlot> slots, size_t n);

private:
    // Perfect matching over entries greater than kEpsilon. Returns empty when
    // none exists.
    [[nodiscard]] static std::vector<uint32_t>
        perfect_matching(std::span<const double> m, size_t n);
};

}  // namespace lightrail::fabric
