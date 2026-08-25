# static/ergopti_plus/windows/native/nav_event_owner/CMakeLists.txt
# MODULE: Ergopti navigation event owner native build.
# DESCRIPTION: Builds the x64 Win32 DLL and deterministic state-machine test.

cmake_minimum_required(VERSION 3.20)

project(ergopti_nav_owner LANGUAGES C)

if(NOT WIN32)
	message(FATAL_ERROR "ergopti_nav_owner requires Win32")
endif()

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
	message(FATAL_ERROR "ergopti_nav_owner supports x64 only")
endif()

add_library(ergopti_nav_owner SHARED
	nav_event_owner.c
	nav_event_owner.def
)

target_compile_features(ergopti_nav_owner PRIVATE c_std_11)
target_link_libraries(ergopti_nav_owner PRIVATE user32)

add_executable(ergopti_nav_event_owner_test
	nav_event_owner_test.c
	nav_event_owner.c
)

target_compile_features(ergopti_nav_event_owner_test PRIVATE c_std_11)
target_compile_definitions(ergopti_nav_event_owner_test PRIVATE
	ERGOPTI_NAV_TESTING=1)
target_link_libraries(ergopti_nav_event_owner_test PRIVATE user32)

if(MSVC)
	set_property(TARGET ergopti_nav_owner PROPERTY
		MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
	set_property(TARGET ergopti_nav_event_owner_test PROPERTY
		MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
	# VS 2019 16.11 diagnoses SDK 10.0.19041's own macro expansion as C5105.
	# Keep warnings fatal while suppressing only that external-header warning.
	target_compile_options(ergopti_nav_owner PRIVATE /W4 /WX /wd5105)
	target_compile_options(ergopti_nav_event_owner_test PRIVATE /W4 /WX /wd5105)
endif()

include(CTest)
if(BUILD_TESTING)
	add_test(NAME ergopti_nav_event_owner_test
		COMMAND ergopti_nav_event_owner_test)
endif()
