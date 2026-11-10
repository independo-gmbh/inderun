//
//  Exports.swift
//  IndeRunCoreAIProviders
//
//  Re-exports IndeRunCore -- and, through it, IndeRunContracts -- and IndeRunNeuralSpeech
//  to consumers of this module. See the same file in IndeRunCore for why. This module's
//  public API names types from all three (SpeechGraphExecutor, SpeechTensor), so one
//  import has to be enough to use it.
//

@_exported import IndeRunCore
@_exported import IndeRunNeuralSpeech
