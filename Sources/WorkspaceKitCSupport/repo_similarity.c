/*
 * repo_similarity.c
 *
 * UTF-8-aware Levenshtein distance, Dice coefficient, and the hybrid
 * similarity score. Extracted from RepoPromptCore's
 * string_extensions_wrapper.c (WorkspaceKit adoption slice 4) so
 * search_scoring.c and ApplyEditsCSupport link one shared definition.
 */

#include "repo_similarity.h"
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <ctype.h>
#include <stdbool.h>

static size_t utf8_strlen(const char *s) {
    size_t len = 0;
    while (*s) {
        if ((*s & 0xC0) != 0x80) len++;
        s++;
    }
    return len;
}

/**
 * Get the nth UTF-8 character from a string
 * Returns pointer to the character, or NULL if out of bounds
 */
static const char* utf8_char_at(const char *s, size_t n) __attribute__((unused));
static const char* utf8_char_at(const char *s, size_t n) {
    size_t i = 0;
    while (*s && i < n) {
        if ((*s & 0xC0) != 0x80) i++;
        if (i <= n) s++;
    }
    return *s ? s : NULL;
}

/**
 * Compare two UTF-8 characters for equality
 * Returns 1 if equal, 0 if different
 */
static int utf8_char_equal(const char *a, const char *b) {
    if (!a || !b) return 0;
    
    /* Get the length of the first character */
    int len_a = 1;
    if ((*a & 0x80) == 0) len_a = 1;
    else if ((*a & 0xE0) == 0xC0) len_a = 2;
    else if ((*a & 0xF0) == 0xE0) len_a = 3;
    else if ((*a & 0xF8) == 0xF0) len_a = 4;
    
    /* Compare the bytes */
    for (int i = 0; i < len_a; i++) {
        if (a[i] != b[i]) return 0;
        if ((a[i] & 0xC0) != 0x80 && i > 0) return 0; /* Invalid UTF-8 */
    }
    
    return 1;
}

int repo_levenshtein_distance(const char *a, const char *b, int maxDist) {
    if (!a || !b) return -1;
    if (strcmp(a, b) == 0) return 0;

    /* Length in UTF-8 code-points (not bytes) */
    size_t len_a = utf8_strlen(a);
    size_t len_b = utf8_strlen(b);

    if (len_a == 0) return (int)len_b;
    if (len_b == 0) return (int)len_a;

    /* Fast reject when a capped distance is impossible */
    if (maxDist >= 0 && abs((int)len_a - (int)len_b) > maxDist)
        return maxDist + 1;

    /* Always iterate over the shorter string */
    if (len_b < len_a)
        return repo_levenshtein_distance(b, a, maxDist);

    /* Build lookup tables of UTF-8 character starts */
    const char **chars_a = malloc(len_a * sizeof(char*));
    const char **chars_b = malloc(len_b * sizeof(char*));
    if (!chars_a || !chars_b) {
        free(chars_a); free(chars_b);
        return -1;
    }

    const char *p = a;
    size_t idx = 0;
    while (*p) {
        if ((*p & 0xC0) != 0x80) chars_a[idx++] = p;
        p++;
    }

    p = b;
    idx = 0;
    while (*p) {
        if ((*p & 0xC0) != 0x80) chars_b[idx++] = p;
        p++;
    }

    /* DP rows */
    int *prev = malloc((len_b + 1) * sizeof(int));
    int *curr = malloc((len_b + 1) * sizeof(int));
    if (!prev || !curr) {
        free(prev); free(curr);
        free(chars_a); free(chars_b);
        return -1;
    }

    for (size_t j = 0; j <= len_b; j++) prev[j] = (int)j;

    /* ---------- Uncapped standard DP ---------- */
    if (maxDist < 0) {
        for (size_t i = 1; i <= len_a; i++) {
            curr[0] = (int)i;
            for (size_t j = 1; j <= len_b; j++) {
                int ins = curr[j - 1] + 1;
                int del = prev[j] + 1;
                int sub = prev[j - 1] +
                          (utf8_char_equal(chars_a[i - 1], chars_b[j - 1]) ? 0 : 1);
                int v = ins < del ? ins : del;
                if (sub < v) v = sub;
                curr[j] = v;
            }
            int *tmp = prev; prev = curr; curr = tmp;
        }
        int result = prev[len_b];
        free(prev); free(curr); free(chars_a); free(chars_b);
        return result;
    }

    /* ---------- Capped (banded) DP ---------- */
    int big = maxDist + 1;

    for (size_t j = 0; j <= len_b; j++) {
        prev[j] = big;
        curr[j] = big;
    }
    prev[0] = 0;
    size_t hi = (len_b < (size_t)maxDist) ? len_b : (size_t)maxDist;
    for (size_t j = 1; j <= hi; j++) prev[j] = (int)j;

    for (size_t i = 1; i <= len_a; i++) {
        int j_lo = (int)i - maxDist;
        if (j_lo < 1) j_lo = 1;
        int j_hi = (int)i + maxDist;
        if (j_hi > (int)len_b) j_hi = (int)len_b;

        for (size_t j = 0; j <= len_b; j++) curr[j] = big;
        if (j_lo == 1) curr[0] = (int)i;

        int row_min = big;

        for (int j = j_lo; j <= j_hi; j++) {
            int ins = curr[j - 1] + 1;
            int del = prev[j] + 1;
            int sub = prev[j - 1] +
                      (utf8_char_equal(chars_a[i - 1], chars_b[j - 1]) ? 0 : 1);
            int v = ins < del ? ins : del;
            if (sub < v) v = sub;
            curr[j] = v;
            if (v < row_min) row_min = v;
        }

        /* Bail out early if row can't beat maxDist */
        if (row_min > maxDist) {
            free(prev); free(curr); free(chars_a); free(chars_b);
            return big;
        }

        int *tmp = prev; prev = curr; curr = tmp;
    }

    int dist = prev[len_b];
    free(prev); free(curr); free(chars_a); free(chars_b);
    return (dist > maxDist) ? big : dist;
}

/* MARK: - Dice Coefficient */

static int compare_bigram_keys(const void *lhs, const void *rhs) {
    uint16_t a = *(const uint16_t *)lhs;
    uint16_t b = *(const uint16_t *)rhs;
    return (a > b) - (a < b);
}

/**
 * Sørensen–Dice coefficient on character bigrams
 * Returns value between 0.0 and 1.0
 */
double repo_dice_coefficient(const char *a, const char *b) {
    if (!a || !b) return 0.0;
    
    size_t len_a = strlen(a);
    size_t len_b = strlen(b);
    
    if (len_a == 0 || len_b == 0) return 0.0;
    if (strcmp(a, b) == 0) return 1.0;
    if (len_a == 1 || len_b == 1) {
        return (a[0] == b[0]) ? 1.0 : 0.0;
    }
    
    /* Multiset intersection of the two strings' (ASCII case-folded) bigrams.
     * Sorting the bigram keys and merging keeps the cost proportional to the
     * input; the former version zero-allocated and scanned two 65,536-entry
     * tables (512 KB) on every call. Short inputs use the stack. */
    size_t count_a = len_a - 1;
    size_t count_b = len_b - 1;
    uint16_t stack_keys[512];
    uint16_t *keys_a = stack_keys;
    uint16_t *keys_b = stack_keys + 256;
    uint16_t *heap_keys = NULL;
    if (count_a > 256 || count_b > 256) {
        heap_keys = malloc((count_a + count_b) * sizeof(uint16_t));
        if (!heap_keys) return 0.0;
        keys_a = heap_keys;
        keys_b = heap_keys + count_a;
    }

    for (size_t i = 0; i < count_a; i++) {
        unsigned char c1 = tolower((unsigned char)a[i]);
        unsigned char c2 = tolower((unsigned char)a[i + 1]);
        keys_a[i] = (uint16_t)(((uint16_t)c1 << 8) | c2);
    }
    for (size_t i = 0; i < count_b; i++) {
        unsigned char c1 = tolower((unsigned char)b[i]);
        unsigned char c2 = tolower((unsigned char)b[i + 1]);
        keys_b[i] = (uint16_t)(((uint16_t)c1 << 8) | c2);
    }
    qsort(keys_a, count_a, sizeof(uint16_t), compare_bigram_keys);
    qsort(keys_b, count_b, sizeof(uint16_t), compare_bigram_keys);

    size_t intersection = 0;
    size_t ia = 0, ib = 0;
    while (ia < count_a && ib < count_b) {
        if (keys_a[ia] == keys_b[ib]) {
            intersection++;
            ia++;
            ib++;
        } else if (keys_a[ia] < keys_b[ib]) {
            ia++;
        } else {
            ib++;
        }
    }
    free(heap_keys);

    return (2.0 * (double)intersection) / (double)(count_a + count_b);
}

/* MARK: - Longest Common Subsequence */

/**
 * Get the next UTF-8 character and advance the pointer
 */
static const char* next_utf8_char(const char *s, int *char_len) {
    if (!s || !*s) {
        *char_len = 0;
        return NULL;
    }
    
    unsigned char c = *s;
    if ((c & 0x80) == 0) *char_len = 1;
    else if ((c & 0xE0) == 0xC0) *char_len = 2;
    else if ((c & 0xF0) == 0xE0) *char_len = 3;
    else if ((c & 0xF8) == 0xF0) *char_len = 4;
    else *char_len = 1; /* Invalid UTF-8, treat as single byte */
    
    return s;
}

/**
 * Compare UTF-8 characters at given positions
 */
static bool utf8_chars_equal(const char *a, int a_len, const char *b, int b_len) {
    if (a_len != b_len) return false;
    return memcmp(a, b, a_len) == 0;
}

/**
 * Finds the longest common subsequence between two strings
 * Returns dynamically allocated string that must be freed by caller
 */

double repo_similarity_score(const char *a, const char *b) {
    if (!a || !b) return 0.0;
    if (strcmp(a, b) == 0) return 1.0;
    
    size_t len_a = strlen(a);
    size_t len_b = strlen(b);
    
    /* Use Dice coefficient for long strings */
    if (len_a > 64 || len_b > 64) {
        return repo_dice_coefficient(a, b);
    }
    
    /* Use Levenshtein for shorter strings */
    size_t max_len = (len_a > len_b) ? len_a : len_b;
    if (max_len == 0) return 1.0;
    
    /* Calculate with reasonable cap for 85% similarity */
    int max_allowed_dist = (int)ceil(max_len * 0.15);
    int dist = repo_levenshtein_distance(a, b, max_allowed_dist);
    
    /* If distance exceeds cap, fall back to Dice */
    if (dist > max_allowed_dist) {
        return repo_dice_coefficient(a, b);
    }
    
    return 1.0 - (double)dist / (double)max_len;
}


char* repo_longest_common_subsequence(const char *a, const char *b) {
    if (!a || !b) return NULL;
    
    /* Count UTF-8 characters and build position arrays */
    size_t m = 0, n = 0;
    const char *p;
    
    /* Count characters in a */
    p = a;
    while (*p) {
        int char_len;
        next_utf8_char(p, &char_len);
        if (char_len == 0) break;
        p += char_len;
        m++;
    }
    
    /* Count characters in b */
    p = b;
    while (*p) {
        int char_len;
        next_utf8_char(p, &char_len);
        if (char_len == 0) break;
        p += char_len;
        n++;
    }
    
    if (m == 0 || n == 0) {
        return strdup("");
    }
    
    /* Build character position arrays */
    const char **a_chars = malloc(m * sizeof(char*));
    int *a_lens = malloc(m * sizeof(int));
    const char **b_chars = malloc(n * sizeof(char*));
    int *b_lens = malloc(n * sizeof(int));
    
    if (!a_chars || !a_lens || !b_chars || !b_lens) {
        free(a_chars); free(a_lens); free(b_chars); free(b_lens);
        return NULL;
    }
    
    /* Fill position arrays */
    p = a;
    for (size_t i = 0; i < m; i++) {
        a_chars[i] = next_utf8_char(p, &a_lens[i]);
        p += a_lens[i];
    }
    
    p = b;
    for (size_t i = 0; i < n; i++) {
        b_chars[i] = next_utf8_char(p, &b_lens[i]);
        p += b_lens[i];
    }
    
    /* Allocate DP table */
    int **dp = malloc((m + 1) * sizeof(int*));
    if (!dp) {
        free(a_chars); free(a_lens); free(b_chars); free(b_lens);
        return NULL;
    }
    
    for (size_t i = 0; i <= m; i++) {
        dp[i] = calloc(n + 1, sizeof(int));
        if (!dp[i]) {
            for (size_t j = 0; j < i; j++) free(dp[j]);
            free(dp);
            free(a_chars); free(a_lens); free(b_chars); free(b_lens);
            return NULL;
        }
    }
    
    /* Fill DP table */
    for (size_t i = 1; i <= m; i++) {
        for (size_t j = 1; j <= n; j++) {
            if (utf8_chars_equal(a_chars[i-1], a_lens[i-1], b_chars[j-1], b_lens[j-1])) {
                dp[i][j] = dp[i - 1][j - 1] + 1;
            } else {
                dp[i][j] = (dp[i - 1][j] > dp[i][j - 1]) ? dp[i - 1][j] : dp[i][j - 1];
            }
        }
    }
    
    /* Calculate space needed for LCS */
    size_t lcs_char_count = dp[m][n];
    size_t lcs_byte_size = 0;
    
    /* Backtrack to calculate byte size */
    size_t i = m, j = n;
    size_t *indices = malloc(lcs_char_count * sizeof(size_t));
    size_t idx = lcs_char_count;
    
    while (i > 0 && j > 0) {
        if (utf8_chars_equal(a_chars[i-1], a_lens[i-1], b_chars[j-1], b_lens[j-1])) {
            indices[--idx] = i - 1;
            lcs_byte_size += a_lens[i - 1];
            i--;
            j--;
        } else if (dp[i - 1][j] > dp[i][j - 1]) {
            i--;
        } else {
            j--;
        }
    }
    
    /* Build result string */
    char *lcs = malloc(lcs_byte_size + 1);
    if (!lcs) {
        free(indices);
        for (size_t k = 0; k <= m; k++) free(dp[k]);
        free(dp);
        free(a_chars); free(a_lens); free(b_chars); free(b_lens);
        return NULL;
    }
    
    char *dest = lcs;
    for (size_t k = 0; k < lcs_char_count; k++) {
        size_t char_idx = indices[k];
        memcpy(dest, a_chars[char_idx], a_lens[char_idx]);
        dest += a_lens[char_idx];
    }
    *dest = '\0';
    
    /* Clean up */
    free(indices);
    for (size_t k = 0; k <= m; k++) free(dp[k]);
    free(dp);
    free(a_chars); free(a_lens); free(b_chars); free(b_lens);
    
    return lcs;
}

/* MARK: - Similarity Score */

/**
 * Calculates similarity score based on algorithm selection
 * For strings <= 64 chars: Uses Levenshtein distance
 * For longer strings: Uses Dice coefficient
 */
