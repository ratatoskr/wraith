# Made by `wraith sdk cmake`, which a plugin's CMakeLists.txt runs as it configures, so it's this wraith's.
#
#     find_program(WRAITH wraith REQUIRED)
#     execute_process(COMMAND "${WRAITH}" sdk cmake "${CMAKE_BINARY_DIR}/wraith.cmake" COMMAND_ERROR_IS_FATAL ANY)
#     include("${CMAKE_BINARY_DIR}/wraith.cmake")
#     wraith_plugin(my_plugin CXX src/plugin.cpp)

# wraith_plugin(<id> <C|CXX> <sources>...): a Wraith plugin, wraith_<id>_<arch>.dll, for the arch it's
# configured for. Wraith's API and its schemas are headers it includes, like wraith_plugin.hpp and schema.hpp,
# made by `wraith sdk c types` or `wraith sdk cpp types` in the build folder, and made again whenever what
# they're made from changes: its schemas, those of the plugins it depends on, or this wraith. Once it's
# built, it and what Wraith reads beside it go in dist/, which `wraith dev add dist` loads.
function(wraith_plugin id language)
    if(language STREQUAL "CXX")
        set(kind cpp)
    elseif(language STREQUAL "C")
        set(kind c)
    else()
        message(FATAL_ERROR "wraith_plugin(${id} ${language}): its language is C or CXX")
    endif()
    if(CMAKE_SIZEOF_VOID_P EQUAL 8)
        set(arch x64)
    else()
        set(arch x86)
    endif()

    set(made "${CMAKE_CURRENT_BINARY_DIR}/wraith_${kind}")
    set(make "${WRAITH}" sdk ${kind} types --out "${made}" --pointer-size ${CMAKE_SIZEOF_VOID_P})
    # Now, so the headers are there and what they're made from is known
    execute_process(COMMAND ${make} WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" OUTPUT_QUIET COMMAND_ERROR_IS_FATAL ANY)
    # What they're made from: its files, and the folders' schemas, so a new one configures it again
    file(STRINGS "${made}/inputs.txt" listed)
    set(inputs)
    foreach(input IN LISTS listed)
        if(IS_DIRECTORY "${input}")
            file(GLOB_RECURSE found CONFIGURE_DEPENDS "${input}/*.sal")
        elseif(EXISTS "${input}")
            list(APPEND inputs "${input}")
        endif()
    endforeach()
    # And when the list changes, like for a new dependency
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${made}/inputs.txt")
    add_custom_command(
        OUTPUT "${made}/stamp"
        COMMAND ${make}
        COMMAND "${CMAKE_COMMAND}" -E touch "${made}/stamp"
        DEPENDS ${inputs}
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        COMMENT "Wraith's API and ${id}'s schemas as headers"
        VERBATIM)
    add_custom_target(${id}_wraith_types DEPENDS "${made}/stamp")

    add_library(${id} SHARED ${ARGN})
    add_dependencies(${id} ${id}_wraith_types)
    target_include_directories(${id} PRIVATE "${made}")
    set_target_properties(${id} PROPERTIES OUTPUT_NAME "wraith_${id}_${arch}" PREFIX "")
    if(kind STREQUAL "cpp")
        target_compile_features(${id} PRIVATE cxx_std_20)
    else()
        set_target_properties(${id} PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
    endif()

    set(dist "${CMAKE_CURRENT_SOURCE_DIR}/dist")
    add_custom_command(TARGET ${id} POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${dist}"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:${id}>" "${dist}"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/wraith.json" "${dist}"
        VERBATIM)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/schemas")
        add_custom_command(TARGET ${id} POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/schemas" "${dist}/schemas"
            VERBATIM)
    endif()
endfunction()
