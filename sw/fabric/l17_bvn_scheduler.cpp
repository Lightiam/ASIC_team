// =============================================================================
// l17_bvn_scheduler.cpp -- Birkhoff-von Neumann decomposition
// =============================================================================

#include "l17_bvn_scheduler.hpp"

#include <algorithm>
#include <cmath>

namespace lightrail::fabric {

std::string_view to_string(BvnError e) noexcept {
    switch (e) {
        case BvnError::NotSquare:           return "NotSquare";
        case BvnError::Empty:               return "Empty";
        case BvnError::NegativeEntry:       return "NegativeEntry";
        case BvnError::NotDoublyStochastic: return "NotDoublyStochastic";
        case BvnError::NoPerfectMatching:   return "NoPerfectMatching";
        case BvnError::IterationLimit:      return "IterationLimit";
    }
    return "Unknown";
}

namespace {

// Kuhn's algorithm: try to find an augmenting path from row u.
bool try_augment(size_t u, size_t n, std::span<const double> m,
                 std::vector<char>& seen, std::vector<int>& match_col) {
    for (size_t v = 0; v < n; ++v) {
        if (m[u * n + v] <= BvnScheduler::kEpsilon) continue;
        if (seen[v]) continue;
        seen[v] = 1;
        if (match_col[v] < 0 ||
            try_augment(static_cast<size_t>(match_col[v]), n, m, seen, match_col)) {
            match_col[v] = static_cast<int>(u);
            return true;
        }
    }
    return false;
}

}  // namespace

std::vector<uint32_t>
BvnScheduler::perfect_matching(std::span<const double> m, size_t n) {
    std::vector<int> match_col(n, -1);

    for (size_t u = 0; u < n; ++u) {
        std::vector<char> seen(n, 0);
        if (!try_augment(u, n, m, seen, match_col))
            return {};                       // no perfect matching exists
    }

    std::vector<uint32_t> row_to_col(n, 0);
    for (size_t v = 0; v < n; ++v)
        row_to_col[static_cast<size_t>(match_col[v])] = static_cast<uint32_t>(v);
    return row_to_col;
}

std::expected<std::vector<TimeSlot>, BvnError>
BvnScheduler::decompose(std::span<const double> matrix, size_t n) {
    if (n == 0)                   return std::unexpected(BvnError::Empty);
    if (matrix.size() != n * n)   return std::unexpected(BvnError::NotSquare);

    for (double x : matrix)
        if (x < -kEpsilon) return std::unexpected(BvnError::NegativeEntry);

    // Validate doubly stochastic: every row and column must sum to 1.
    for (size_t i = 0; i < n; ++i) {
        double r = 0.0, c = 0.0;
        for (size_t j = 0; j < n; ++j) {
            r += matrix[i * n + j];
            c += matrix[j * n + i];
        }
        if (std::fabs(r - 1.0) > 1e-6 || std::fabs(c - 1.0) > 1e-6)
            return std::unexpected(BvnError::NotDoublyStochastic);
    }

    std::vector<double> work(matrix.begin(), matrix.end());
    std::vector<TimeSlot> slots;

    // Birkhoff's bound is n^2 - 2n + 2; allow a small margin for round-off.
    const size_t limit = n * n + 2;
    double remaining = 1.0;

    for (size_t iter = 0; iter < limit; ++iter) {
        bool all_zero = true;
        for (double x : work)
            if (x > kEpsilon) { all_zero = false; break; }
        if (all_zero) break;

        const std::vector<uint32_t> perm = perfect_matching(work, n);
        if (perm.empty()) return std::unexpected(BvnError::NoPerfectMatching);

        // The weight is the smallest entry along the matching: subtracting it
        // zeroes at least one entry, which is what bounds the iteration count.
        double alpha = 1.0;
        for (size_t i = 0; i < n; ++i)
            alpha = std::min(alpha, work[i * n + perm[i]]);

        if (alpha <= kEpsilon) break;        // numerical floor

        for (size_t i = 0; i < n; ++i) {
            double& cell = work[i * n + perm[i]];
            cell -= alpha;
            if (cell < kEpsilon) cell = 0.0; // snap, so the matching shrinks
        }

        slots.push_back(TimeSlot{alpha, std::vector<uint32_t>(perm.begin(), perm.end())});
        remaining -= alpha;
        if (remaining <= kEpsilon) break;
    }

    if (slots.empty()) return std::unexpected(BvnError::IterationLimit);
    return slots;
}

bool BvnScheduler::normalize(std::span<double> matrix, size_t n,
                             int max_iters, double tol) {
    if (n == 0 || matrix.size() != n * n) return false;

    for (double x : matrix)
        if (x < 0.0) return false;

    // A zero row or column can never be scaled to sum to one.
    for (size_t i = 0; i < n; ++i) {
        double r = 0.0, c = 0.0;
        for (size_t j = 0; j < n; ++j) { r += matrix[i * n + j]; c += matrix[j * n + i]; }
        if (r <= 0.0 || c <= 0.0) return false;
    }

    // Sinkhorn-Knopp: alternately normalise rows then columns.
    for (int it = 0; it < max_iters; ++it) {
        for (size_t i = 0; i < n; ++i) {
            double r = 0.0;
            for (size_t j = 0; j < n; ++j) r += matrix[i * n + j];
            if (r > 0.0)
                for (size_t j = 0; j < n; ++j) matrix[i * n + j] /= r;
        }
        for (size_t j = 0; j < n; ++j) {
            double c = 0.0;
            for (size_t i = 0; i < n; ++i) c += matrix[i * n + j];
            if (c > 0.0)
                for (size_t i = 0; i < n; ++i) matrix[i * n + j] /= c;
        }

        double worst = 0.0;
        for (size_t i = 0; i < n; ++i) {
            double r = 0.0, c = 0.0;
            for (size_t j = 0; j < n; ++j) { r += matrix[i * n + j]; c += matrix[j * n + i]; }
            worst = std::max({worst, std::fabs(r - 1.0), std::fabs(c - 1.0)});
        }
        if (worst < tol) return true;
    }
    return false;
}

std::vector<double>
BvnScheduler::reconstruct(std::span<const TimeSlot> slots, size_t n) {
    std::vector<double> out(n * n, 0.0);
    for (const TimeSlot& s : slots)
        for (size_t i = 0; i < n && i < s.port_map.size(); ++i)
            out[i * n + s.port_map[i]] += s.weight;
    return out;
}

}  // namespace lightrail::fabric
