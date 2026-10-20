#pragma once
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(x) ((void)0)
#define portEXIT_CRITICAL(x) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_INTERNAL 2
#define MALLOC_CAP_8BIT 4
static inline size_t heap_caps_get_total_size(int x){return 1000000;}
static inline size_t heap_caps_get_largest_free_block(int x){return 1000000;}
static inline void *heap_caps_malloc(size_t n,int x){return malloc(n);}
