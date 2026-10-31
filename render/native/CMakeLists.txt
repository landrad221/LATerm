cmake_minimum_required(VERSION 3.10)
project(laterm_renderer C)

find_package(TCL REQUIRED)

add_library(laterm_renderer SHARED native_renderer.c)
target_include_directories(laterm_renderer PRIVATE
    ${TCL_INCLUDE_PATH}
    ${TK_INCLUDE_PATH}
)
target_link_libraries(laterm_renderer PRIVATE ${TK_LIBRARY} ${TCL_LIBRARY})
target_compile_features(laterm_renderer PRIVATE c_std_99)
target_compile_options(laterm_renderer PRIVATE -Wall -Wextra -Wpedantic)
set_target_properties(laterm_renderer PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "laterm_renderer"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
)

install(TARGETS laterm_renderer
    LIBRARY DESTINATION lib/laterm-renderer0.1
)
install(FILES native_renderer.tcl pkgIndex.tcl
    DESTINATION lib/laterm-renderer0.1
)
