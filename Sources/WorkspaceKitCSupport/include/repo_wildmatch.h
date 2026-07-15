/*
 * repo_wildmatch.h
 *
 * Public interface for the bundled wildmatch matcher and its
 * gitignore-compatible wrappers. These declarations previously lived
 * inline in RepoPrompt's bridging header; they moved here when the
 * ignore stack was promoted into WorkspaceKit (adoption slice 1).
 */

#ifndef REPO_WILDMATCH_H
#define REPO_WILDMATCH_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bundled wildmatch matcher for gitignore-compatible pattern matching */
int repo_wildmatch(const char *pattern, const char *text, unsigned int flags);

/* Gitignore-specific matching functions */
int repo_gitignore_match_anchored(const char *pattern, const char *path);
int repo_gitignore_match_anywhere(const char *pattern, const char *path);
void repo_normalize_pattern(char *dest, const char *src, size_t dest_size);

/* Parsed pattern structure for Swift interop */
typedef struct {
    char pattern[1024];
    bool is_negation;
    bool directory_only;
    bool absolute;
} repo_gitignore_pattern;

/* Parse a single gitignore line into a pattern structure */
bool repo_parse_gitignore_line(const char *line, repo_gitignore_pattern *result);

#ifdef __cplusplus
}
#endif

#endif /* REPO_WILDMATCH_H */
