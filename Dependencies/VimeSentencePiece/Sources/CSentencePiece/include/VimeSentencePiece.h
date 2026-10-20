#ifndef VIME_SENTENCEPIECE_H
#define VIME_SENTENCEPIECE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/// Returns NULL unless the model has exactly `pieces` pieces and PAD/UNK/BOS/EOS = 0/1/2/3.
void *vime_sp_load(const char *path, int32_t pieces);
void vime_sp_destroy(void *processor);
int vime_sp_encode(void *processor, const char *text, size_t bytes, int32_t **ids, size_t *count);
int vime_sp_decode(void *processor, const int32_t *ids, size_t count, char **text, size_t *bytes);
void vime_sp_free(void *buffer);
#ifdef __cplusplus
}
#endif
#endif
