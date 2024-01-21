set(LWIP_DIR 
    ${CMAKE_CURRENT_SOURCE_DIR}/../submodules/lwip
)

set(LWIP_INCLUDE_DIRS
    ${LWIP_DIR}/src/include
    ${CMAKE_CURRENT_SOURCE_DIR}
)

set (LWIP_DEFINITIONS LWIP_DEBUG=0)
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_BUILD_TYPE Release)

set(LWIP_COMPILER_FLAGS -ffreestanding -fno-stack-protector)
include(${LWIP_DIR}/src/Filelists.cmake)

add_library(tcpip STATIC tcpip.c)
target_include_directories(tcpip PRIVATE ${LWIP_INCLUDE_DIRS})
target_compile_options(tcpip PRIVATE -ffreestanding -fno-stack-protector)
target_link_libraries(tcpip lwipallapps lwipcore)
