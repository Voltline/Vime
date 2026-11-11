#include "VimeRime.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

#include <rime/candidate.h>
#include <rime/composition.h>
#include <rime/context.h>
#include <rime/deployer.h>
#include <rime/menu.h>
#include <rime/lever/deployment_tasks.h>
#include <rime/service.h>
#include <rime/setup.h>
#include <rime_api.h>

#include <DictConverter.hpp>

extern "C" bool (*vime_rime_learning_filter)(const char *) = nullptr;

namespace {

std::mutex start_lock;
bool started = false;
std::string shared_dir, user_dir;

RimeApi *api() { return rime_get_api(); }

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
    guarded([&] { session = api()->create_session(); return true; });
    return session;
}

void vime_rime_destroy_session(VimeRimeSession session) {
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
    *snapshot = {};
}
