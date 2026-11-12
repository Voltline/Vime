// A small C interface over librime for Swift. Every call catches C++
// exceptions, and every string a snapshot returns is a copy the caller frees
// with vime_rime_snapshot_free.
#ifndef VIME_RIME_H
#define VIME_RIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uintptr_t VimeRimeSession;

typedef struct {
    char *text;
    char *comment;
    /// Completes the input past what was typed, such as a longer phrase.
    bool completion;
    /// The candidate before display filters such as the simplifier, so
    /// simplified text while traditional characters are shown. NULL when it
    /// equals `text`.
    char *genuine;
    /// Converts the input up to its end, not only a leading part of it.
    bool coversInput;
    /// Learned from what the user typed before.
    bool userPhrase;
    /// Made up of several dictionary words rather than being one entry.
    bool sentence;
    /// Rime's ranking score; higher is likelier.
    double quality;
} VimeRimeCandidate;

typedef struct {
    /// Raw input, such as pinyin; NULL when nothing is composed.
    char *input;
    /// The composition as shown, with UTF-8 byte offsets into it.
    char *preedit;
    int32_t cursor;
    int32_t selectionStart;
    int32_t selectionEnd;
    /// Text the host should insert, taken from the engine once.
    char *commit;
    /// The first candidates of the whole list, not only the current page.
    VimeRimeCandidate *candidates;
    int32_t candidateCount;
    int32_t highlighted;
    int32_t pageSize;
    /// The last dictionary word of `commit`, before display filters, and its
    /// syllable code for vime_rime_continuations. NULL when the commit did
    /// not end with a dictionary word, such as raw input.
    char *commitWord;
    char *commitCode;
} VimeRimeSnapshot;

typedef struct {
    /// The rest of the phrase after the word asked about, as shown.
    char *text;
    /// The same before display filters (simplified characters).
    char *genuine;
    /// The syllable code of `genuine`, for asking about it in turn.
    char *code;
} VimeRimeContinuation;

typedef struct {
    VimeRimeContinuation *items;
    int32_t count;
} VimeRimeContinuations;

/// Starts the engine once per process. `shared` holds the prebuilt data, and
/// `user` is a writable directory for user dictionaries.
bool vime_rime_start(const char *shared, const char *user);
void vime_rime_stop(void);

/// Compiles the schemas listed in `shared`/default.yaml into `staging`.
/// Meant for the build machine, not for the keyboard.
bool vime_rime_build(const char *shared, const char *user, const char *staging);

/// Compiles an OpenCC text dictionary into the binary form (.ocd2) that
/// the conversion configs in the shared data's opencc folder load.
/// Meant for the build machine, not for the keyboard.
bool vime_opencc_build_dictionary(const char *text, const char *binary);

/// Called on the engine's thread before a commit is learned; returning false
/// keeps the user dictionary unchanged. The text is the whole commit.
typedef bool (*VimeRimeLearningFilter)(const char *text);
void vime_rime_set_learning_filter(VimeRimeLearningFilter filter);

VimeRimeSession vime_rime_create_session(void);
void vime_rime_destroy_session(VimeRimeSession session);
bool vime_rime_select_schema(VimeRimeSession session, const char *schema);
/// X11 keysym and Rime modifier mask. False when the engine did not use it.
bool vime_rime_process_key(VimeRimeSession session, int32_t keycode, int32_t mask);
/// Index into the whole candidate list.
bool vime_rime_select_candidate(VimeRimeSession session, size_t index);
bool vime_rime_set_input(VimeRimeSession session, const char *input);
void vime_rime_clear(VimeRimeSession session);
/// Commits the whole composition with its current selections.
bool vime_rime_commit_composition(VimeRimeSession session);
bool vime_rime_is_composing(VimeRimeSession session);
/// Turns a schema option on or off, such as the simplifier's.
void vime_rime_set_option(VimeRimeSession session, const char *option, bool value);

VimeRimeSnapshot vime_rime_snapshot(VimeRimeSession session, int32_t candidateLimit);
void vime_rime_snapshot_free(VimeRimeSnapshot *snapshot);

/// Phrases of the session's dictionary that begin with `word` read as `code`
/// (from a snapshot or an earlier continuation), likeliest first, at most
/// `limit`. `traditional` converts their text as the simplifier would.
VimeRimeContinuations vime_rime_continuations(VimeRimeSession session, const char *word, const char *code,
                                              int32_t limit, bool traditional);
void vime_rime_continuations_free(VimeRimeContinuations *continuations);

#ifdef __cplusplus
}
#endif

#endif
