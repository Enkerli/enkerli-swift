//
//  AudioKernel.mm
//  AudioKernel
//
//  One Objective-C++ compile unit, for the same reason `Kernel.mm` exists next
//  door: a header-only C++ target gives SwiftPM nothing to build, and without an
//  object file there is no module map for Swift to import. The headers carry all
//  the behaviour; this file exists so the target does.
//

#import "include/VaneDSPKernel.hpp"
#import "include/VaneAUProcessHelper.hpp"
