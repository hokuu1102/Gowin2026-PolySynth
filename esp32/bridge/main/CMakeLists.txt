idf_component_register(SRCS "bridge_main.c" "pool.c" "hmi.c"
                       INCLUDE_DIRS "."
                       REQUIRES bt esp_driver_uart esp_driver_gpio nvs_flash esp_timer)

# ----------------------------------------------------------------------------
# Build-time switches, forwarded to the C compiler.
#
# WHY this block is needed (learned the hard way, 2026-09-23):
#   Passing `-DXXX=1` to idf.py only creates a CMake CACHE variable.
#   It does NOT reach the C compiler by itself -- confirmed by inspecting
#   build/CMakeCache.txt, which showed `BRIDGE_MODE:UNINITIALIZED=1`.
#   => the preprocessor never saw it, so two supposedly-different builds
#      produced a byte-identical binary and the switch silently did nothing.
#
# Usage:
#     idf.py build                          # mode A, HMI on  (defaults)
#     idf.py -DBRIDGE_MODE=1 build          # mode B (pool)
#     idf.py -DBRIDGE_HMI_ENABLE=0 build    # no serial screen
#
# NOTE: bridge_config.h wraps its defaults in `#ifndef`, so a define
#       supplied here wins over the in-file default.
# ----------------------------------------------------------------------------
foreach(sw BRIDGE_MODE BRIDGE_HMI_ENABLE)
    if(DEFINED ${sw})
        target_compile_definitions(${COMPONENT_LIB} PRIVATE ${sw}=${${sw}})
        message(STATUS "ESP32 bridge: ${sw}=${${sw}} (from command line)")
    else()
        message(STATUS "ESP32 bridge: ${sw}=default (see bridge_config.h)")
    endif()
endforeach()
