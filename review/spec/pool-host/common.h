#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stddef.h>
typedef void *SemaphoreHandle_t;
typedef int esp_err_t;
#define portMAX_DELAY 0
#define pdMS_TO_TICKS(x) (x)
#define UART_NUM_0 0
#define UART_NUM_1 1
#define UART_NUM_2 2
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
#define ESP_LOGD(...) ((void)0)
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_INTERNAL 2
#define MALLOC_CAP_8BIT 4
static inline size_t heap_caps_get_total_size(int x){return 1000000;}
static inline size_t heap_caps_get_largest_free_block(int x){return 1000000;}
static inline void *heap_caps_malloc(size_t n,int x){return malloc(n);}
static void *xSemaphoreCreateMutex(void){return (void*)1;}
static void xSemaphoreTake(void*x,int n){}
static void xSemaphoreGive(void*x);
static int64_t esp_timer_get_time(void){return 1000000;}
static void vTaskDelay(int x){}
static int uart_write_bytes(int port,const char *buf,size_t n);
