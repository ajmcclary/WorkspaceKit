/*
 * repo_similarity.h — UTF-8-aware string-similarity primitives shared by
 * the workspace search scorer and RepoPromptCore's string helpers.
 */

#ifndef REPO_SIMILARITY_H
#define REPO_SIMILARITY_H

#ifdef __cplusplus
extern "C" {
#endif

/* Levenshtein distance with optional cap (maxDist = -1 for uncapped;
 * returns maxDist + 1 when the true distance exceeds the cap). */
int repo_levenshtein_distance(const char *a, const char *b, int maxDist);

/* Sørensen–Dice coefficient on byte bigrams. */
double repo_dice_coefficient(const char *a, const char *b);

/* Hybrid similarity: exact / capped-Levenshtein / Dice fallbacks. */
double repo_similarity_score(const char *a, const char *b);

/* Longest common subsequence (caller frees the returned string). */
char* repo_longest_common_subsequence(const char *a, const char *b);

#ifdef __cplusplus
}
#endif

#endif /* REPO_SIMILARITY_H */
