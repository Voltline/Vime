#include "VimeRime.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include <rime/candidate.h>
#include <rime/composition.h>
#include <rime/context.h>
#include <rime/deployer.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/table.h>
#include <rime/gear/opencc.h>
#include <rime/gear/translator_commons.h>
#include <rime/menu.h>
#include <rime/lever/deployment_tasks.h>
#include <rime/service.h>
#include <rime/ticket.h>
#include <rime/setup.h>
#include <rime_api.h>

#include <DictConverter.hpp>

extern "C" bool (*vime_rime_learning_filter)(const char *) = nullptr;

namespace {

std::mutex start_lock;
bool started = false;
std::string shared_dir, user_dir;

RimeApi *api() { return rime_get_api(); }

using Syllables = std::vector<rime::SyllableId>;

/// What a session committed last, kept until a snapshot hands it out.
struct LastCommit {
    std::string text;
    std::string word;
    Syllables code;
};
std::mutex commit_lock;
std::map<VimeRimeSession, LastCommit> last_commits;

std::string join(const Syllables &code) {
    std::string result;
    for (auto id : code) {
        if (!result.empty()) result += ' ';
        result += std::to_string(id);
    }
    return result;
}

Syllables split(const char *text) {
    Syllables code;
    std::istringstream stream(text ? text : "");
    int id;
    while (stream >> id) code.push_back(id);
    return code;
}

size_t utf8_length(const std::string &text) {
    return size_t(std::count_if(text.begin(), text.end(), [](char c) { return (c & 0xC0) != 0x80; }));
}

/// Drops the first `count` UTF-8 characters.
std::string utf8_drop(const std::string &text, size_t count) {
    size_t i = 0;
    while (i < text.size() && count > 0) {
        ++i;
        while (i < text.size() && (text[i] & 0xC0) == 0x80) ++i;
        --count;
    }
    return text.substr(i);
}

/// Remembers the composition's last dictionary word when it ends the input.
void record_commit(VimeRimeSession session, rime::Context *ctx) {
    LastCommit last;
    last.text = ctx->GetCommitText();
    const rime::Composition &composition = ctx->composition();
    if (!composition.empty() && composition.back().end >= ctx->input().length()) {
        auto selected = composition.back().GetSelectedCandidate();
        // A candidate converting only part of the segment leaves raw letters.
        if (selected && selected->end() >= composition.back().end) {
            auto genuine = rime::Candidate::GetGenuineCandidate(selected);
            if (auto sentence = rime::As<rime::Sentence>(genuine)) {
                if (!sentence->components().empty()) {
                    last.word = sentence->components().back().text;
                    const rime::Code &code = sentence->components().back().code;
                    last.code.assign(code.begin(), code.end());
                }
            } else if (auto phrase = rime::As<rime::Phrase>(genuine)) {
                last.word = phrase->text();
                last.code.assign(phrase->code().begin(), phrase->code().end());
            }
        }
    }
    std::lock_guard<std::mutex> lock(commit_lock);
    last_commits[session] = last;
}

std::mutex opencc_lock;
std::unique_ptr<rime::Opencc> traditional_converter;

std::string to_traditional(const std::string &text) {
    std::lock_guard<std::mutex> lock(opencc_lock);
    if (!traditional_converter)
        traditional_converter.reset(new rime::Opencc(rime::path(shared_dir) / "opencc" / "s2t.json"));
    std::string result;
    return traditional_converter->ConvertText(text, &result) ? result : text;
}

struct Continuation {
    const rime::table::Entry *entry;
    Syllables code;
};

const rime::table::TrunkIndexNode *find_node(const rime::table::PhraseIndex *index, rime::SyllableId key) {
    if (!index) return nullptr;
    for (const auto &node : index->trunk())
        if (node.key == key) return &node;
    return nullptr;
}

/// Phrases one or two syllables longer than `prefix`, read from the
/// table's index: three trunk levels by syllable, then a tail of longer codes.
std::vector<Continuation> continuations(rime::Table *table, const Syllables &prefix) {
    std::vector<Continuation> found;
    auto *metadata = table->metadata();
    const rime::table::Index *index = metadata ? metadata->index.get() : nullptr;
    if (!index || prefix.empty() || prefix[0] < 0 || size_t(prefix[0]) >= index->size) return found;
    auto add = [&](const rime::List<rime::table::Entry> &entries, Syllables code) {
        for (const auto &entry : entries) found.push_back({&entry, code});
    };
    const rime::table::HeadIndexNode &head = index->at[prefix[0]];
    if (prefix.size() == 1) {
        if (auto *next = head.next_level.get())
            for (const auto &node : next->trunk()) add(node.entries, {prefix[0], node.key});
        return found;
    }
    const rime::table::TrunkIndexNode *second = find_node(head.next_level.get(), prefix[1]);
    if (!second) return found;
    if (prefix.size() == 2) {
        if (auto *next = second->next_level.get())
            for (const auto &node : next->trunk()) {
                add(node.entries, {prefix[0], prefix[1], node.key});
                if (auto *tail = node.next_level.get())
                    for (const auto &item : tail->tail())
                        if (item.extra_code.size == 1)
                            found.push_back({&item.entry, Syllables{prefix[0], prefix[1], node.key, *item.extra_code.begin()}});
            }
        return found;
    }
    const rime::table::TrunkIndexNode *third = find_node(second->next_level.get(), prefix[2]);
    if (!third || !third->next_level.get()) return found;
    size_t extra = prefix.size() - 3;
    for (const auto &item : third->next_level.get()->tail()) {
        size_t size = item.extra_code.size;
        if (size <= extra || size > extra + 2) continue;
        if (!std::equal(prefix.begin() + 3, prefix.end(), item.extra_code.begin())) continue;
        Syllables code(prefix.begin(), prefix.begin() + 3);
        code.insert(code.end(), item.extra_code.begin(), item.extra_code.end());
        found.push_back({&item.entry, code});
    }
    return found;
}

char *copy(const char *text) {
    if (!text) return nullptr;
    size_t length = std::strlen(text);
    char *result = static_cast<char *>(std::malloc(length + 1));
    if (result) std::memcpy(result, text, length + 1);
    return result;
}

template <typename F>
bool guarded(F body) {
    try {
        return body();
    } catch (...) {
        return false;
    }
}

}  // namespace

bool vime_rime_start(const char *shared, const char *user) {
    std::lock_guard<std::mutex> lock(start_lock);
    if (started) return true;
    return guarded([&] {
        shared_dir = shared;
        user_dir = user;
        RIME_STRUCT(RimeTraits, traits);
        traits.shared_data_dir = shared_dir.c_str();
        traits.user_data_dir = user_dir.c_str();
        traits.prebuilt_data_dir = shared_dir.c_str();
        traits.distribution_name = "Vime";
        traits.distribution_code_name = "vime";
        traits.distribution_version = "1";
        traits.app_name = "rime.vime";
        traits.min_log_level = 3;
        api()->setup(&traits);
        api()->initialize(&traits);
        started = true;
        return true;
    });
}

void vime_rime_stop(void) {
    std::lock_guard<std::mutex> lock(start_lock);
    if (!started) return;
    guarded([] { api()->finalize(); return true; });
    {
        std::lock_guard<std::mutex> lock(opencc_lock);
        traditional_converter.reset();
    }
    started = false;
}

bool vime_rime_build(const char *shared, const char *user, const char *staging) {
    return guarded([&] {
        rime::Deployer &deployer = rime::Service::instance().deployer();
        deployer.shared_data_dir = rime::path(shared);
        deployer.user_data_dir = rime::path(user);
        deployer.prebuilt_data_dir = rime::path(shared) / "build";
        deployer.staging_dir = rime::path(staging);
        rime::LoadModules(rime::kDeployerModules);
        rime::WorkspaceUpdate update;
        return update.Run(&deployer);
    });
}

bool vime_opencc_build_dictionary(const char *text, const char *binary) {
    return guarded([&] {
        opencc::ConvertDictionary(text, binary, "text", "ocd2");
        return true;
    });
}

void vime_rime_set_learning_filter(VimeRimeLearningFilter filter) {
    vime_rime_learning_filter = filter;
}

VimeRimeSession vime_rime_create_session(void) {
    VimeRimeSession session = 0;
    guarded([&] {
        session = api()->create_session();
        if (auto owner = rime::Service::instance().GetSession(session)) {
            owner->context()->commit_notifier().connect(
                [session](rime::Context *ctx) { record_commit(session, ctx); });
        }
        return true;
    });
    return session;
}

void vime_rime_destroy_session(VimeRimeSession session) {
    {
        std::lock_guard<std::mutex> lock(commit_lock);
        last_commits.erase(session);
    }
    guarded([&] { return bool(api()->destroy_session(session)); });
}

bool vime_rime_select_schema(VimeRimeSession session, const char *schema) {
    return guarded([&] { return bool(api()->select_schema(session, schema)); });
}

bool vime_rime_process_key(VimeRimeSession session, int32_t keycode, int32_t mask) {
    return guarded([&] { return bool(api()->process_key(session, keycode, mask)); });
}

bool vime_rime_select_candidate(VimeRimeSession session, size_t index) {
    return guarded([&] { return bool(api()->select_candidate(session, index)); });
}

bool vime_rime_set_input(VimeRimeSession session, const char *input) {
    return guarded([&] { return bool(api()->set_input(session, input)); });
}

void vime_rime_clear(VimeRimeSession session) {
    guarded([&] { api()->clear_composition(session); return true; });
}

bool vime_rime_commit_composition(VimeRimeSession session) {
    return guarded([&] { return bool(api()->commit_composition(session)); });
}

bool vime_rime_is_composing(VimeRimeSession session) {
    return guarded([&] {
        const char *input = api()->get_input(session);
        return input && *input;
    });
}

void vime_rime_set_option(VimeRimeSession session, const char *option, bool value) {
    guarded([&] { api()->set_option(session, option, value); return true; });
}

VimeRimeSnapshot vime_rime_snapshot(VimeRimeSession session, int32_t candidateLimit) {
    VimeRimeSnapshot snapshot = {};
    snapshot.highlighted = -1;
    guarded([&] {
        RIME_STRUCT(RimeCommit, commit);
        if (api()->get_commit(session, &commit)) {
            snapshot.commit = copy(commit.text);
            std::lock_guard<std::mutex> lock(commit_lock);
            auto last = last_commits.find(session);
            if (last != last_commits.end() && commit.text && last->second.text == commit.text
                && !last->second.word.empty() && !last->second.code.empty()) {
                snapshot.commitWord = copy(last->second.word.c_str());
                snapshot.commitCode = copy(join(last->second.code).c_str());
            }
            if (last != last_commits.end()) last_commits.erase(last);
            api()->free_commit(&commit);
        }
        RIME_STRUCT(RimeContext, context);
        if (!api()->get_context(session, &context)) return true;
        if (context.composition.length > 0) {
            snapshot.input = copy(api()->get_input(session));
            snapshot.preedit = copy(context.composition.preedit);
            snapshot.cursor = context.composition.cursor_pos;
            snapshot.selectionStart = context.composition.sel_start;
            snapshot.selectionEnd = context.composition.sel_end;
        }
        snapshot.pageSize = context.menu.page_size;
        if (context.menu.num_candidates > 0)
            snapshot.highlighted = context.menu.page_no * context.menu.page_size
                + context.menu.highlighted_candidate_index;
        api()->free_context(&context);

        if (candidateLimit <= 0) return true;
        snapshot.candidates = static_cast<VimeRimeCandidate *>(
            std::calloc(size_t(candidateLimit), sizeof(VimeRimeCandidate)));
        if (!snapshot.candidates) return true;
        // The C API leaves out a candidate's type, so read it from the menu.
        rime::an<rime::Menu> menu;
        size_t inputLength = 0;
        if (auto owner = rime::Service::instance().GetSession(session)) {
            rime::Context *ctx = owner->context();
            if (ctx && ctx->HasMenu()) menu = ctx->composition().back().menu;
            if (ctx) inputLength = ctx->input().length();
        }
        RimeCandidateListIterator iterator = {};
        if (api()->candidate_list_begin(session, &iterator)) {
            while (snapshot.candidateCount < candidateLimit && api()->candidate_list_next(&iterator)) {
                VimeRimeCandidate &out = snapshot.candidates[snapshot.candidateCount];
                out.text = copy(iterator.candidate.text);
                out.comment = copy(iterator.candidate.comment);
                if (menu) {
                    if (auto candidate = menu->GetCandidateAt(size_t(snapshot.candidateCount))) {
                        auto genuine = rime::Candidate::GetGenuineCandidate(candidate);
                        out.completion = genuine->type() == "completion";
                        out.userPhrase = genuine->type() == "user_phrase" || genuine->type() == "user_table";
                        out.coversInput = candidate->end() >= inputLength;
                        out.sentence = genuine->type() == "sentence";
                        out.quality = genuine->quality();
                        if (genuine->text() != iterator.candidate.text) out.genuine = copy(genuine->text().c_str());
                    }
                }
                ++snapshot.candidateCount;
            }
            api()->candidate_list_end(&iterator);
        }
        return true;
    });
    return snapshot;
}

void vime_rime_snapshot_free(VimeRimeSnapshot *snapshot) {
    if (!snapshot) return;
    std::free(snapshot->input);
    std::free(snapshot->preedit);
    std::free(snapshot->commit);
    for (int32_t i = 0; i < snapshot->candidateCount; ++i) {
        std::free(snapshot->candidates[i].text);
        std::free(snapshot->candidates[i].comment);
        std::free(snapshot->candidates[i].genuine);
    }
    std::free(snapshot->candidates);
    std::free(snapshot->commitWord);
    std::free(snapshot->commitCode);
    *snapshot = {};
}

VimeRimeContinuations vime_rime_continuations(VimeRimeSession session, const char *word, const char *code,
                                              int32_t limit, bool traditional) {
    VimeRimeContinuations result = {};
    if (!word || !*word || limit <= 0) return result;
    guarded([&] {
        auto owner = rime::Service::instance().GetSession(session);
        if (!owner || !owner->schema()) return false;
        rime::Ticket ticket(owner->schema(), "translator");
        auto *component = rime::Dictionary::Require("dictionary");
        if (!component) return false;
        rime::the<rime::Dictionary> dictionary(component->Create(ticket));
        if (!dictionary || !dictionary->Load()) return false;
        rime::Table *table = dictionary->primary_table().get();
        Syllables prefix = split(code);
        std::string head(word);
        size_t headLength = utf8_length(head);
        auto found = continuations(table, prefix);
        std::stable_sort(found.begin(), found.end(),
                         [](const Continuation &a, const Continuation &b) { return a.entry->weight > b.entry->weight; });
        result.items = static_cast<VimeRimeContinuation *>(std::calloc(size_t(limit), sizeof(VimeRimeContinuation)));
        if (!result.items) return false;
        std::vector<std::string> seen;
        for (const auto &item : found) {
            if (result.count >= limit) break;
            std::string text = table->GetEntryText(*item.entry);
            // The same syllables can spell other words, such as 惊天 for 今天.
            if (text.size() <= head.size() || text.compare(0, head.size(), head) != 0) continue;
            std::string rest = text.substr(head.size());
            if (std::find(seen.begin(), seen.end(), rest) != seen.end()) continue;
            seen.push_back(rest);
            std::string shown = rest;
            if (traditional) {
                std::string converted = to_traditional(text);
                shown = utf8_length(converted) == utf8_length(text) ? utf8_drop(converted, headLength) : to_traditional(rest);
            }
            Syllables restCode(item.code.begin() + std::min(prefix.size(), item.code.size()), item.code.end());
            VimeRimeContinuation &out = result.items[result.count++];
            out.text = copy(shown.c_str());
            out.genuine = copy(rest.c_str());
            out.code = copy(join(restCode).c_str());
        }
        return true;
    });
    return result;
}

void vime_rime_continuations_free(VimeRimeContinuations *continuations) {
    if (!continuations) return;
    for (int32_t i = 0; i < continuations->count; ++i) {
        std::free(continuations->items[i].text);
        std::free(continuations->items[i].genuine);
        std::free(continuations->items[i].code);
    }
    std::free(continuations->items);
    *continuations = {};
}
