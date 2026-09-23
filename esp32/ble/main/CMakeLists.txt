idf_component_register(SRCS "ble_main.c" "gatt_svc.c" "pool.c" "hmi.c"
                       INCLUDE_DIRS "."
                       REQUIRES bt nvs_flash esp_timer
                       PRIV_REQUIRES esp_driver_uart esp_driver_gpio)

# ----------------------------------------------------------------------------
# Build-time switches, forwarded to the C compiler.
#
# WHY: passing -DXXX=1 to idf.py only creates a CMake CACHE variable; it does
#      NOT reach the C compiler by itself.  We hit exactly this on the SPP
#      side: two supposedly-different builds produced a byte-identical binary
#      and the switch silently did nothing.
#
# Usage:
#     idf.py build                        # mode A (passthrough), HMI on
#     idf.py -DBLE_MODE=1 build           # mode B (pool)
#     idf.py -DBLE_HMI_ENABLE=0 build     # no serial screen
# ----------------------------------------------------------------------------
foreach(sw BLE_MODE BLE_HMI_ENABLE BLE_BAUD)
    if(DEFINED ${sw})
        target_compile_definitions(${COMPONENT_LIB} PRIVATE ${sw}=${${sw}})
        message(STATUS "ESP32 BLE bridge: ${sw}=${${sw}} (from command line)")
    else()
        message(STATUS "ESP32 BLE bridge: ${sw}=default (see ble_config.h)")
    endif()
endforeach()
