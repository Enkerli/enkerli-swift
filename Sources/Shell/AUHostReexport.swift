//
//  AUHostReexport.swift
//  Shell
//
//  `ObservableAUParameter`, `ParameterTreeSpec` and the rest moved down into
//  `AUHost` when the synth needed them without the MIDI kernel attached. Seven
//  plug-in repos say `import Shell` and use those types, and none of them should
//  have had to learn a second module name for a change that is not about them.
//
//  So `Shell` re-exports what it no longer owns. This is the one place in the
//  package that uses an underscored attribute, and it is worth the exception:
//  the alternative is a `public typealias` for every moved type, which decays
//  the moment somebody adds one, or an edit in seven repos for no reason a
//  reader of those repos could see.
//

@_exported import AUHost
