// Sources/protoc-gen-swift/MessageGenerator.swift - Per-message logic
//
// Copyright (c) 2014 - 2016 Apple Inc. and the project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See LICENSE.txt for license information:
// https://github.com/apple/swift-protobuf/blob/master/LICENSE.txt
//
// -----------------------------------------------------------------------------
///
/// This provides the overall support for building Swift structs to represent
/// a proto message.  In particular, this handles the copy-on-write deferred
/// for messages that require it.
///
// -----------------------------------------------------------------------------

import Foundation
import PluginLibrary
import SwiftProtobuf

class MessageGenerator {
  private let descriptor: Descriptor
  private let generatorOptions: GeneratorOptions
  private let namer: SwiftProtobufNamer
  private let visibility: String
  private let swiftFullName: String
  private let swiftRelativeName: String
  private let swiftMessageConformance: String
  private let fields: [MessageFieldGenerator]
  private let fieldsSortedByNumber: [MessageFieldGenerator]
  private let oneofs: [OneofGenerator]
  private let extensions: [ExtensionGenerator]
  private let storage: MessageStorageClassGenerator?
  private let enums: [EnumGenerator]
  private let messages: [MessageGenerator]
  private let isProto3: Bool
  private let isExtensible: Bool
  private let isAnyMessage: Bool

  init(
    descriptor: Descriptor,
    generatorOptions: GeneratorOptions,
    namer: SwiftProtobufNamer,
    context: Context
  ) {
    self.descriptor = descriptor
    self.generatorOptions = generatorOptions
    self.namer = namer

    self.visibility = generatorOptions.visibilitySourceSnippet
    self.isProto3 = descriptor.file.syntax == .proto3
    self.isExtensible = !descriptor.extensionRanges.isEmpty
    swiftRelativeName = namer.relativeName(message: descriptor)
    swiftFullName = namer.fullName(message: descriptor)
    self.isAnyMessage = (isProto3 &&
                         descriptor.fullName == ".google.protobuf.Any" &&
                         descriptor.file.name == "google/protobuf/any.proto")
    var conformance: [String] = ["SwiftProtobuf.Message"]
    if isExtensible {
      conformance.append("SwiftProtobuf.ExtensibleMessage")
    }
    self.swiftMessageConformance = conformance.joined(separator: ", ")

    fields = descriptor.fields.map {
      return MessageFieldGenerator(descriptor: $0, generatorOptions: generatorOptions, context: context)
    }
    fieldsSortedByNumber = fields.sorted {$0.number < $1.number}

    extensions = descriptor.extensions.map {
      return ExtensionGenerator(descriptor: $0, generatorOptions: generatorOptions, namer: namer)
    }

    var i: Int32 = 0
    var oneofs = [OneofGenerator]()
    for o in descriptor.oneofs {
      let oneofFields = fields.filter {
        $0.descriptor.hasOneofIndex && $0.descriptor.oneofIndex == Int32(i)
      }
      i += 1
      let oneof = OneofGenerator(descriptor: o, generatorOptions: generatorOptions, namer: namer, fields: oneofFields)
      oneofs.append(oneof)
    }
    self.oneofs = oneofs

    self.enums = descriptor.enums.map {
      return EnumGenerator(descriptor: $0, generatorOptions: generatorOptions, namer: namer)
    }

    var messages = [MessageGenerator]()
    for m in descriptor.messages where !m.isMapEntry {
      messages.append(MessageGenerator(descriptor: m, generatorOptions: generatorOptions, namer: namer, context: context))
    }
    self.messages = messages

    // NOTE: This check for fields.count likely isn't completely correct
    // when the message has one or more oneof{}s. As that will efficively
    // reduce the real number of fields and the message might not need heap
    // storage yet.
    let useHeapStorage = fields.count > 16 ||
      hasMessageField(descriptor: descriptor.proto, context: context)
    if isAnyMessage {
      self.storage = AnyMessageStorageClassGenerator(
        descriptor: descriptor,
        fields: fields,
        oneofs: oneofs)
    } else if useHeapStorage {
      self.storage = MessageStorageClassGenerator(
        descriptor: descriptor,
        fields: fields,
        oneofs: oneofs)
    } else {
        self.storage = nil
    }
  }

  func generateMainStruct(printer p: inout CodePrinter, parent: MessageGenerator?) {
    p.print(
        "\n",
        descriptor.protoSourceComments(),
        "\(visibility)struct \(swiftRelativeName): \(swiftMessageConformance) {\n")
    p.indent()
    if let parent = parent {
        p.print("\(visibility)static let protoMessageName: String = \(parent.swiftFullName).protoMessageName + \".\(descriptor.name)\"\n")
    } else if !descriptor.file.package.isEmpty {
        p.print("\(visibility)static let protoMessageName: String = _protobuf_package + \".\(descriptor.name)\"\n")
    } else {
        p.print("\(visibility)static let protoMessageName: String = \"\(descriptor.name)\"\n")
    }

    let usesHeadStorage = storage != nil
    var oneofHandled = Set<Int32>()
    for f in fields {
      // If this is in a oneof, generate the oneof first to match the layout in
      // the proto file.
      if f.descriptor.hasOneofIndex {
        let oneofIndex = f.descriptor.oneofIndex
        if !oneofHandled.contains(oneofIndex) {
          let oneof = oneofs[Int(oneofIndex)]
          oneofHandled.insert(oneofIndex)
          if (usesHeadStorage) {
            oneof.generateProxyIvar(printer: &p)
          } else {
            oneof.generateTopIvar(printer: &p)
          }
        }
      }
      if usesHeadStorage {
        f.generateProxyIvar(printer: &p)
      } else {
        f.generateTopIvar(printer: &p)
      }
      f.generateHasProperty(printer: &p, usesHeapStorage: usesHeadStorage)
      f.generateClearMethod(printer: &p, usesHeapStorage: usesHeadStorage)
    }

    p.print(
        "\n",
        "\(visibility)var unknownFields = SwiftProtobuf.UnknownStorage()\n")

    for o in oneofs {
      o.generateMainEnum(printer: &p)
    }

    // Nested enums
    for e in enums {
      e.generateMainEnum(printer: &p)
    }

    // Nested messages
    for m in messages {
      m.generateMainStruct(printer: &p, parent: self)
    }

    // Generate the default initializer. If we don't, Swift seems to sometimes
    // generate it along with others that can take public proprerties. When it
    // generates the others doesn't seem to be documented.
    p.print(
        "\n",
        "\(visibility)init() {}\n")

    // isInitialized
    generateIsInitialized(printer:&p)

    p.print("\n")
    generateDecodeMessage(printer: &p)

    p.print("\n")
    generateTraverse(printer: &p)

    // Optional extension support
    if isExtensible {
      p.print(
          "\n",
          "\(visibility)var _protobuf_extensionFieldValues = SwiftProtobuf.ExtensionFieldValueSet()\n")
    }
    if let storage = storage {
      if !isExtensible {
        p.print("\n")
      }
      p.print("\(storage.storageVisibility) var _storage = _StorageClass()\n")
    } else {
      var subMessagePrinter = CodePrinter()
      for f in fields {
        f.generateTopIvarStorage(printer: &subMessagePrinter)
      }
      if !subMessagePrinter.isEmpty {
        if !isExtensible {
          p.print("\n")
        }
        p.print(subMessagePrinter.content)
      }
    }

    p.outdent()
    p.print("}\n")
  }

  func generateProtobufExtensionDeclarations(printer p: inout CodePrinter) {
    if !extensions.isEmpty {
      p.print(
          "\n",
          "extension \(swiftFullName) {\n")
      p.indent()
      p.print("enum Extensions {\n")
      p.indent()
      var addNewline = false
      for e in extensions {
        if addNewline {
          p.print("\n")
        } else {
          addNewline = true
        }
        e.generateProtobufExtensionDeclarations(printer: &p)
      }
      p.outdent()
      p.print("}\n")
      p.outdent()
      p.print("}\n")
    }
    for m in messages {
      m.generateProtobufExtensionDeclarations(printer: &p)
    }
  }

  func generateMessageSwiftExtensionForProtobufExtensions(printer p: inout CodePrinter) {
    for e in extensions {
      e.generateMessageSwiftExtensionForProtobufExtensions(printer: &p)
    }
    for m in messages {
      m.generateMessageSwiftExtensionForProtobufExtensions(printer: &p)
    }
  }

  func registerExtensions(registry: inout [String]) {
    for e in extensions {
      registry.append(e.swiftFullExtensionName)
    }
    for m in messages {
      m.registerExtensions(registry: &registry)
    }
  }

  func generateRuntimeSupport(printer p: inout CodePrinter, file: FileGenerator, parent: MessageGenerator?) {
    p.print(
        "\n",
        "extension \(swiftFullName): SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {\n")
    p.indent()
    generateProtoNameProviding(printer: &p)
    if let storage = storage {
      p.print("\n")
      storage.generateTypeDeclaration(printer: &p)
      p.print(
          "\n",
          "\(storage.storageVisibility) mutating func _uniqueStorage() -> _StorageClass {\n")
      p.indent()
      p.print("if !isKnownUniquelyReferenced(&_storage) {\n")
      p.indent()
      p.print("_storage = _StorageClass(copying: _storage)\n")
      p.outdent()
      p.print("}\n")
      p.print("return _storage\n")
      p.outdent()
      p.print("}\n")
    }
    p.print("\n")
    generateMessageImplementationBase(printer: &p)
    p.outdent()
    p.print("}\n")

    for o in oneofs {
      o.generateRuntimeSupport(printer: &p)
    }

    // Nested enums and messages
    for e in enums {
      e.generateRuntimeSupport(printer: &p)
    }
    for m in messages {
      m.generateRuntimeSupport(printer: &p, file: file, parent: self)
    }
  }

  private func generateProtoNameProviding(printer p: inout CodePrinter) {
    if fields.isEmpty {
      p.print("\(visibility)static let _protobuf_nameMap = SwiftProtobuf._NameMap()\n")
    } else {
      p.print("\(visibility)static let _protobuf_nameMap: SwiftProtobuf._NameMap = [\n")
      p.indent()
      for f in fields {
        p.print("\(f.number): \(f.fieldMapNames),\n")
      }
      p.outdent()
      p.print("]\n")
    }
  }


  /// Generates the `decodeMessage` method for the message.
  ///
  /// - Parameter p: The code printer.
  private func generateDecodeMessage(printer p: inout CodePrinter) {
    p.print("\(visibility)mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {\n")
    p.indent()
    if storage != nil {
      p.print("_ = _uniqueStorage()\n")
    }
    let varName: String
    if fields.isEmpty && !isExtensible {
      varName = "_"
    } else {
      varName = "fieldNumber"
    }
    generateWithLifetimeExtension(printer: &p, throws: true) { p in
      p.print("while let \(varName) = try decoder.nextFieldNumber() {\n")
      p.indent()
      if !fields.isEmpty {
        p.print("switch fieldNumber {\n")
        var oneofHandled = Set<Int32>()
        for f in fieldsSortedByNumber {
          if f.descriptor.hasOneofIndex {
            let oneofIndex = f.descriptor.oneofIndex
            if !oneofHandled.contains(oneofIndex) {
              p.print("case \(oneofFieldNumbersPattern(index: oneofIndex)):\n")
              let oneof = f.oneof!
              p.indent()
              p.print("if \(storedProperty(forOneof: oneof)) != nil {\n")
              p.indent()
              p.print("try decoder.handleConflictingOneOf()\n")
              p.outdent()
              p.print("}\n")
              p.print("\(storedProperty(forOneof: oneof)) = try \(swiftFullName).\(oneof.swiftRelativeType)(byDecodingFrom: &decoder, fieldNumber: fieldNumber)\n")
              p.outdent()
              oneofHandled.insert(oneofIndex)
            }
          } else {
            f.generateDecodeFieldCase(printer: &p, usesStorage: storage != nil)
          }
        }
        if isExtensible {
          p.print("case \(descriptor.proto.swiftExtensionRangeExpressions):\n")
          p.indent()
          p.print("try decoder.decodeExtensionField(values: &_protobuf_extensionFieldValues, messageType: \(swiftRelativeName).self, fieldNumber: fieldNumber)\n")
          p.outdent()
        }
        p.print("default: break\n")
      } else if isExtensible {
        // Just output a simple if-statement if the message had no fields of its
        // own but we still need to generate a decode statement for extensions.
        p.print("if \(descriptor.proto.swiftExtensionRangeBooleanExpression(variable: "fieldNumber")) {\n")
        p.indent()
        p.print("try decoder.decodeExtensionField(values: &_protobuf_extensionFieldValues, messageType: \(swiftRelativeName).self, fieldNumber: fieldNumber)\n")
        p.outdent()
        p.print("}\n")
      }
      if !fields.isEmpty {
        p.print("}\n")
      }
      p.outdent()
      p.print("}\n")
    }
    p.outdent()
    p.print("}\n")
  }

  /// Returns a Swift pattern (or list of patterns) suitable for a `case`
  /// statement that matches any of the field numbers corresponding to the
  /// `oneof` with the given index.
  ///
  /// This function collapses large contiguous field number sequences into
  /// into range patterns instead of listing all of the fields explicitly.
  ///
  /// - Parameter index: The index of the `oneof`.
  /// - Returns: The Swift pattern(s) that match the `oneof`'s field numbers.
  private func oneofFieldNumbersPattern(index: Int32) -> String {
    let oneofFields = oneofs[Int(index)].fieldsSortedByNumber.map { $0.number }
    assert(oneofFields.count > 0)

    if oneofFields.count <= 2 {
      // For one or two fields, just return "n" or "n, m". ("n...m" would
      // also be valid, but this is one character shorter.)
      return oneofFields.lazy.map { String($0) }.joined(separator: ", ")
    }

    let first = oneofFields.first!
    let last = oneofFields.last!

    if first + oneofFields.count - 1 == last {
      // The field numbers were contiguous, so return a range instead.
      return "\(first)...\(last)"
    }
    // Not a contiguous range, so just print the comma-delimited list of
    // field numbers. (We could consider optimizing this to print ranges
    // for contiguous subsequences later, as well.)
    return oneofFields.lazy.map { String($0) }.joined(separator: ", ")
  }

  /// Generates the `traverse` method for the message.
  ///
  /// - Parameter p: The code printer.
  private func generateTraverse(printer p: inout CodePrinter) {
    p.print("\(visibility)func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {\n")
    p.indent()
    generateWithLifetimeExtension(printer: &p, throws: true) { p in
      if let storage = storage {
        storage.generatePreTraverse(printer: &p)
      }
      var ranges = descriptor.proto.extensionRange.makeIterator()
      var nextRange = ranges.next()
      var currentOneofGenerator: OneofGenerator?
      var oneofStart = 0
      var oneofEnd = 0
      for f in fieldsSortedByNumber {
        while nextRange != nil && Int(nextRange!.start) < f.number {
          p.print("try visitor.visitExtensionFields(fields: _protobuf_extensionFieldValues, start: \(nextRange!.start), end: \(nextRange!.end))\n")
          nextRange = ranges.next()
        }
        if let c = currentOneofGenerator, let n = f.oneof, n.name == c.descriptor.name {
          oneofEnd = f.number + 1
        } else {
          if let oneof = currentOneofGenerator {
            if oneof.oneofIsContinuousInParent {
              p.print("try \(storedProperty(forOneof: oneof.descriptor))?.traverse(visitor: &visitor)\n")
            } else {
              p.print("try \(storedProperty(forOneof: oneof.descriptor))?.traverse(visitor: &visitor, start: \(oneofStart), end: \(oneofEnd))\n")
            }
            currentOneofGenerator = nil
          }
          if f.descriptor.hasOneofIndex {
            oneofStart = f.number
            oneofEnd = f.number + 1
            currentOneofGenerator = oneofs[Int(f.descriptor.oneofIndex)]
          } else {
            f.generateTraverse(printer: &p, usesStorage: storage != nil)
          }
        }
      }
      if let oneof = currentOneofGenerator {
        if oneof.oneofIsContinuousInParent {
          p.print("try \(storedProperty(forOneof: oneof.descriptor))?.traverse(visitor: &visitor)\n")
        } else {
          p.print("try \(storedProperty(forOneof: oneof.descriptor))?.traverse(visitor: &visitor, start: \(oneofStart), end: \(oneofEnd))\n")
        }
      }
      while nextRange != nil {
        p.print("try visitor.visitExtensionFields(fields: _protobuf_extensionFieldValues, start: \(nextRange!.start), end: \(nextRange!.end))\n")
        nextRange = ranges.next()
      }
    }
    p.print("try unknownFields.traverse(visitor: &visitor)\n")
    p.outdent()
    p.print("}\n")
  }

  private func generateMessageImplementationBase(printer p: inout CodePrinter) {
    p.print("\(visibility)func _protobuf_generated_isEqualTo(other: \(swiftFullName)) -> Bool {\n")
    p.indent()
    var compareFields = true
    if let storage = storage {
      p.print("if _storage !== other._storage {\n")
      p.indent()
      p.print("let storagesAreEqual: Bool = ")
      if storage.storageProvidesEqualTo {
        p.print("_storage.isEqualTo(other: other._storage)\n")
        compareFields = false
      }
    }
    if compareFields {
      generateWithLifetimeExtension(printer: &p,
                                    alsoCapturing: "other") { p in
        var oneofHandled = Set<Int32>()
        for f in fields {
          if let o = f.oneof {
            if !oneofHandled.contains(f.descriptor.oneofIndex) {
              p.print("if \(storedProperty(forOneof: o)) != \(storedProperty(forOneof: o, in: "other")) {return false}\n")
              oneofHandled.insert(f.descriptor.oneofIndex)
            }
          } else {
            let notEqualClause: String
            if isProto3 || f.isRepeated {
              notEqualClause = "\(storedProperty(forField: f)) != \(storedProperty(forField: f, in: "other"))"
            } else {
              notEqualClause = "\(storedProperty(forField: f)) != \(storedProperty(forField: f, in: "other"))"
            }
            p.print("if \(notEqualClause) {return false}\n")
          }
        }
        if storage != nil {
          p.print("return true\n")
        }
      }
    }
    if storage != nil {
      p.print("if !storagesAreEqual {return false}\n")
      p.outdent()
      p.print("}\n")
    }
    p.print("if unknownFields != other.unknownFields {return false}\n")
    if isExtensible {
      p.print("if _protobuf_extensionFieldValues != other._protobuf_extensionFieldValues {return false}\n")
    }
    p.print("return true\n")
    p.outdent()
    p.print("}\n")
  }

  /// Generates the `isInitialized` property for the message, if needed.
  ///
  /// This may generate nothing, if the `isInitialized` property is not
  /// needed.
  ///
  /// - Parameter printer: The code printer.
  private func generateIsInitialized(printer p: inout CodePrinter) {

    var requiredPrinter: CodePrinter?
    if !isProto3 {
      // Only proto2 syntax can have field presence (required fields); ensure required
      // fields have values.
      requiredPrinter = CodePrinter()
      for f in fields {
        if f.label == .required {
          requiredPrinter!.print("if \(storedProperty(forField: f)) == nil {return false}\n")
        }
      }
    }

    var subMessagePrinter = CodePrinter()

    // Check that all non-oneof embedded messages are initialized.
    for f in fields where f.oneof == nil {
      if f.isGroupOrMessage && f.messageType.hasRequiredFields() {
        if f.isRepeated {  // Map or Array
          subMessagePrinter.print("if !SwiftProtobuf.Internal.areAllInitialized(\(storedProperty(forField: f))) {return false}\n")
        } else {
          subMessagePrinter.print("if let v = \(storedProperty(forField: f)), !v.isInitialized {return false}\n")
        }
      }
    }

    // Check that all oneof embedded messages are initialized.
    for oneofField in oneofs {
      var fieldsToCheck: [MessageFieldGenerator] = []
      for f in oneofField.fields {
        if f.isGroupOrMessage && f.messageType.hasRequiredFields() {
          fieldsToCheck.append(f)
        }
      }
      if fieldsToCheck.count == 1 {
        let f = fieldsToCheck.first!
        subMessagePrinter.print("if case .\(f.swiftName)(let v)? = \(storedProperty(forOneof: oneofField.descriptor)), !v.isInitialized {return false}\n")
      } else if fieldsToCheck.count > 1 {
        subMessagePrinter.print("switch \(storedProperty(forOneof: oneofField.descriptor)) {\n")
        for f in fieldsToCheck {
          subMessagePrinter.print("case .\(f.swiftName)(let v)?: if !v.isInitialized {return false}\n")
        }
        // Covers other cases or if the oneof wasn't set (was nil).
        subMessagePrinter.print(
            "default: break\n",
            "}\n")
      }
    }

    let hasRequiredFields = requiredPrinter != nil && !requiredPrinter!.isEmpty
    let hasMessageFieldsToCheck = !subMessagePrinter.isEmpty

    if !isExtensible && !hasRequiredFields && !hasMessageFieldsToCheck {
      // No need to generate isInitialized.
      return
    }

    p.print(
        "\n",
        "public var isInitialized: Bool {\n")
    p.indent()
    if isExtensible {
      p.print("if !_protobuf_extensionFieldValues.isInitialized {return false}\n")
    }
    if hasRequiredFields || hasMessageFieldsToCheck {
      generateWithLifetimeExtension(printer: &p, returns: true) { p in
        if let requiredPrinter = requiredPrinter {
          p.print(requiredPrinter.content)
        }
        p.print(subMessagePrinter.content)
        p.print("return true\n")
      }
    } else {
      p.print("return true\n")
    }
    p.outdent()
    p.print("}\n")
  }

  /// Returns the Swift expression used to access the actual stored property
  /// for the given field.
  ///
  /// This method has knowledge of the lifetime extension logic implemented
  /// by `generateWithLifetimeExtension` such that if the stored property is
  /// in a storage object, the proper dot-expression is returned.
  ///
  /// - Parameter field: The `MessageFieldGenerator` corresponding to the
  ///   field.
  /// - Parameter variable: The name of the variable representing the message
  ///   whose stored property should be accessed. The default value if
  ///   omitted is the empty string, which represents implicit `self`.
  /// - Returns: The Swift expression used to access the actual stored
  ///   property for the field.
  private func storedProperty(
    forField field: MessageFieldGenerator,
    in variable: String = ""
  ) -> String {
    if storage != nil {
      return "\(variable)_storage.\(field.swiftStorageName)"
    }
    let prefix = variable.isEmpty ? "self." : "\(variable)."
    if field.isRepeated || field.isMap {
      return "\(prefix)\(field.swiftName)"
    }
    if !isProto3 {
      return "\(prefix)\(field.swiftStorageName)"
    }
    return "\(prefix)\(field.swiftName)"
  }

  /// Returns the Swift expression used to access the actual stored property
  /// for the given oneof.
  ///
  /// This method has knowledge of the lifetime extension logic implemented
  /// by `generateWithLifetimeExtension` such that if the stored property is
  /// in a storage object, the proper dot-expression is returned.
  ///
  /// - Parameter oneof: The oneof descriptor.
  /// - Parameter variable: The name of the variable representing the message
  ///   whose stored property should be accessed. The default value if
  ///   omitted is the empty string, which represents implicit `self`.
  /// - Returns: The Swift expression used to access the actual stored
  ///   property for the oneof.
  private func storedProperty(
    forOneof oneof: Google_Protobuf_OneofDescriptorProto,
    in variable: String = ""
  ) -> String {
    if storage != nil {
      return "\(variable)_storage._\(oneof.swiftFieldName)"
    }
    let prefix = variable.isEmpty ? "self." : "\(variable)."
    return "\(prefix)\(oneof.swiftFieldName)"
  }

  /// Executes the given closure, wrapping the code that it prints in a call
  /// to `withExtendedLifetime` for the storage object if the message uses
  /// one.
  ///
  /// - Parameter p: The code printer.
  /// - Parameter canThrow: Indicates whether the code that will be printed
  ///   inside the block can throw; if so, the printed call to
  ///   `withExtendedLifetime` will be preceded by `try`.
  /// - Parameter returns: Indicates whether the code that will be printed
  ///   inside the block returns a value; if so, the printed call to
  ///   `withExtendedLifetime` will be preceded by `return`.
  /// - Parameter capturedVariable: The name of another variable (which is
  ///   assumed to be the same type as `self`) whose storage should also be
  ///   captured (used for equality testing, where two messages are operated
  ///   on simultaneously).
  /// - Parameter body: A closure that takes the code printer as its sole
  ///   `inout` argument.
  private func generateWithLifetimeExtension(
    printer p: inout CodePrinter,
    throws canThrow: Bool = false,
    returns: Bool = false,
    alsoCapturing capturedVariable: String? = nil,
    body: (inout CodePrinter) -> Void
  ) {
    if storage != nil {
      let prefixKeywords = "\(returns ? "return " : "")" +
        "\(canThrow ? "try " : "")"

      let actualArgs: String
      let formalArgs: String
      if let capturedVariable = capturedVariable {
        actualArgs = "(_storage, \(capturedVariable)._storage)"
        formalArgs = "(_storage, \(capturedVariable)_storage)"
      } else {
        actualArgs = "_storage"
        // The way withExtendedLifetime is defined causes ambiguities in the
        // singleton argument case, which we have to resolve by writing out
        // the explicit type of the closure argument.
        formalArgs = "(_storage: _StorageClass)"
      }
      p.print(prefixKeywords +
        "withExtendedLifetime(\(actualArgs)) { \(formalArgs) in\n")
      p.indent()
    }

    body(&p)

    if storage != nil {
      p.outdent()
      p.print("}\n")
    }
  }
}

fileprivate func hasMessageField(
  descriptor: Google_Protobuf_DescriptorProto,
  context: Context
) -> Bool {
  let hasMessageField = descriptor.field.contains {
    ($0.type == .message || $0.type == .group)
    && $0.label != .repeated
    && (context.getMessageForPath(path: $0.typeName)?.options.mapEntry != true)
  }
  return hasMessageField
}
