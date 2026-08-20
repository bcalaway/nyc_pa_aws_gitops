cmake_minimum_required(VERSION 3.28)
project(cpp_app_template CXX)

# "At least C++20, newer where the toolchain/deps actually support it" (Bill's
# call for this template) -- C++23 is what the base image's clang actually
# ships, verified against this exact Dockerfile, not assumed.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# clang-tidy (the Dockerfile's `lint` stage) needs this to know each file's
# real compile flags/include paths.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# This project doesn't use C++20 modules, but CMake 3.28+'s Ninja generator
# scans for them by default whenever CMAKE_CXX_STANDARD >= 20 -- which
# injects a `@foo.cpp.o.modmap` response-file argument into each affected
# translation unit's entry in compile_commands.json. clang-tidy re-executes
# those recorded commands directly and doesn't understand that argument,
# failing with "no such file or directory: '...modmap'" on every file it
# touches (confirmed for real: 6 of 7 source files failed lint over this
# before this line was added). Off, since there's nothing to scan for.
set(CMAKE_CXX_SCAN_FOR_MODULES OFF)

find_package(Protobuf CONFIG REQUIRED)
find_package(gRPC CONFIG REQUIRED)
find_package(GTest CONFIG REQUIRED)
find_package(libpqxx CONFIG REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)
find_package(httplib CONFIG REQUIRED)

# --- Protobuf/gRPC codegen -------------------------------------------------
# Standard pattern from grpc's own C++ examples (protoc + the grpc_cpp_plugin
# invoked via add_custom_command), not a higher-level CMake module -- keeps
# this template working regardless of which protobuf CMake helpers a given
# vcpkg version does or doesn't ship.
set(PROTO_FILE "${CMAKE_SOURCE_DIR}/proto/example_service.proto")
set(GENERATED_DIR "${CMAKE_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(PROTO_SRCS "${GENERATED_DIR}/example_service.pb.cc")
set(PROTO_HDRS "${GENERATED_DIR}/example_service.pb.h")
set(GRPC_SRCS "${GENERATED_DIR}/example_service.grpc.pb.cc")
set(GRPC_HDRS "${GENERATED_DIR}/example_service.grpc.pb.h")

add_custom_command(
  OUTPUT "${PROTO_SRCS}" "${PROTO_HDRS}" "${GRPC_SRCS}" "${GRPC_HDRS}"
  COMMAND protobuf::protoc
  ARGS --cpp_out "${GENERATED_DIR}"
       --grpc_out "${GENERATED_DIR}"
       --plugin=protoc-gen-grpc=$<TARGET_FILE:gRPC::grpc_cpp_plugin>
       -I "${CMAKE_SOURCE_DIR}/proto"
       "${PROTO_FILE}"
  DEPENDS "${PROTO_FILE}" protobuf::protoc gRPC::grpc_cpp_plugin
  COMMENT "Generating gRPC code from example_service.proto"
)

add_library(proto_gen STATIC ${PROTO_SRCS} ${PROTO_HDRS} ${GRPC_SRCS} ${GRPC_HDRS})
target_link_libraries(proto_gen PUBLIC protobuf::libprotobuf gRPC::grpc++)
target_include_directories(proto_gen PUBLIC "${GENERATED_DIR}")

# --- App library (everything except main(), so tests can link it too) -----
add_library(app_lib STATIC
  src/config.cpp
  src/db.cpp
  src/session_store.cpp
  src/oidc_client.cpp
  src/http_server.cpp
  src/grpc_service.cpp
)
target_include_directories(app_lib PUBLIC src)
target_link_libraries(app_lib PUBLIC
  proto_gen
  httplib::httplib
  libpqxx::pqxx
  nlohmann_json::nlohmann_json
)

# --- Main executable --------------------------------------------------------
add_executable(app src/main.cpp)
target_link_libraries(app PRIVATE app_lib)

# --- Tests -------------------------------------------------------------------
enable_testing()
add_executable(app_tests
  tests/http_server_test.cpp
  tests/grpc_service_test.cpp
  tests/config_test.cpp
)
target_link_libraries(app_tests PRIVATE app_lib GTest::gtest GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(app_tests)
