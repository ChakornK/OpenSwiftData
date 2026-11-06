# FoundationEssentials compatibility shim

This package provides a `FoundationEssentials` module that re-exports Foundation for Linux-hosted builds targeting Apple platforms.

The Linux Swift `#Predicate` macro qualifies generated expression-builder references through `FoundationEssentials`, while Apple SDKs expose those declarations through `Foundation`. Consumers that need to compile such predicates against an Apple SDK from a Linux host can depend on this package directly and enable the module import for their iOS target.

Keep this package separate from OpenSwiftData's root package. A Linux build that places a target named `FoundationEssentials` ahead of the toolchain's own module can shadow the host FoundationEssentials module and create a dependency cycle. Native Apple-hosted builds should use Apple's Foundation and do not need this shim.
