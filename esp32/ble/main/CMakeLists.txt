idf_component_register(SRCS "ble_main.c" "gatt_svc.c" "pool.c" "hmi.c" "up_ring.c"
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
#     idf.py -DBLE_BAUD=500000 build      # override baud (500 k is now default)
#     idf.py -DBLE_START_TRIGGER=1 build  # start via GPIO button (BOOT key)
#
# ⚠️ 2026-09-30: BLE_START_TRIGGER added to the list below.
#    🔴 It had been left OUT, so `-DBLE_START_TRIGGER=1` only landed in the CMake
#    cache and never reached the compiler ==> the GPIO variant was silently NOT
#    built, and the two "different" builds produced an IDENTICAL 0xb60c0 binary.
#    ⭐ That is exactly the failure mode this comment block warns about.
#    ⇒ 🔴 ANY NEW SWITCH MUST BE ADDED TO THE foreach() BELOW, or it does nothing.
# ----------------------------------------------------------------------------
foreach(sw BLE_MODE BLE_HMI_ENABLE BLE_BAUD BLE_START_TRIGGER)
    if(DEFINED ${sw})
        target_compile_definitions(${COMPONENT_LIB} PRIVATE ${sw}=${${sw}})
        message(STATUS "ESP32 BLE bridge: ${sw}=${${sw}} (from command line)")
    else()
        message(STATUS "ESP32 BLE bridge: ${sw}=default (see ble_config.h)")
    endif()
endforeach()
