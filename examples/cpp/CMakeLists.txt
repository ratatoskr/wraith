cmake_minimum_required(VERSION 3.21)
project(example_cpp LANGUAGES CXX)

# The wraith launcher makes Wraith's API and schemas/ into headers as it builds. -DWRAITH=<path> picks another
find_program(WRAITH wraith REQUIRED)
execute_process(COMMAND "${WRAITH}" sdk cmake "${CMAKE_BINARY_DIR}/wraith.cmake" COMMAND_ERROR_IS_FATAL ANY)
include("${CMAKE_BINARY_DIR}/wraith.cmake")

# wraith_example_cpp_x64.dll, or _x86 for a 32-bit build, put in dist/ with what Wraith reads beside it
wraith_plugin(example_cpp CXX src/plugin.cpp)
