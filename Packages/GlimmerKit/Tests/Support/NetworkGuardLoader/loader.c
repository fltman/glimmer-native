#include "NetworkGuardLoader.h"

// Defined in Swift (Tests/Support/NetworkGuard/NetworkGuard.swift).
extern void glimmer_install_network_guard(void);

// Runs when the test process loads, before any test: no test can get ahead of the guard.
__attribute__((constructor)) static void glimmer_load_network_guard(void) { glimmer_install_network_guard(); }

void glimmer_network_guard_loaded(void) {}
