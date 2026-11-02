# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""The contract between Blender and a platform's own interface: what the bridge sends and takes.

`native_ui.fbs` describes every snapshot and command, in the FlatBuffers schema language, so the
same file can give a binary encoding with `flatc` should JSON cost too much. Until then the bridge
sends JSON as FlatBuffers would write it, and this script:

- Generates the interfaces' types: `NativeUI.swift` for the iPad, `NativeUI.kt` for Android.
- Validates JSON against the schema, for tests: unknown fields, wrong types, missing required
  fields and unknown enum values are all errors.
- Checks the generated files are up to date, so neither side drifts from the schema.

Only the parts of the schema language the contract uses are read: `namespace`, `attribute`,
`enum`, `table`, `root_type`, vectors, defaults, and the `required`, `flexbuffer` and `deprecated`
attributes. A `[ubyte] (flexbuffer)` field takes any JSON: parts of a snapshot still to be
described.

    python3 native_ui_schema.py generate        # Write the generated files.
    python3 native_ui_schema.py check           # Fail if they are out of date.
    python3 native_ui_schema.py validate TYPE FILE...   # Validate JSON files as TYPE.
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "native_ui.fbs")
GENERATED = {
    "swift": os.path.join(HERE, "generated", "NativeUI.swift"),
    "kotlin": os.path.join(HERE, "generated", "NativeUI.kt"),
}

SCALARS = {
    "bool", "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong", "float", "double",
    "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64", "float32", "float64",
}
INTEGERS = SCALARS - {"bool", "float", "double", "float32", "float64"}


class SchemaError(Exception):
    pass


class Field:
    def __init__(self, name, type, default, attributes, doc):
        self.name = name
        # The element type for a vector, with `vector` set.
        self.vector = type.startswith("[")
        self.type = type.strip("[]")
        self.default = default
        self.attributes = attributes
        self.doc = doc

    @property
    def required(self):
        return "required" in self.attributes

    @property
    def any(self):
        return "flexbuffer" in self.attributes

    @property
    def nullable_elements(self):
        return "nullable_elements" in self.attributes

    @property
    def deprecated(self):
        return "deprecated" in self.attributes


class Table:
    def __init__(self, name, doc):
        self.name = name
        self.doc = doc
        self.fields = []


class Enum:
    def __init__(self, name, base, doc):
        self.name = name
        self.base = base
        self.doc = doc
        # (name, value, doc)
        self.values = []


class Schema:
    def __init__(self):
        self.namespace = ""
        self.tables = {}
        self.enums = {}
        self.order = []
        self.root = None

    def type_of(self, name):
        return self.tables.get(name) or self.enums.get(name)


def parse(text):
    """Read the parts of the FlatBuffers schema language the contract uses."""
    schema = Schema()
    tokens = re.findall(r'///[^\n]*|//[^\n]*|"[^"]*"|[A-Za-z_][A-Za-z0-9_.]*|-?[0-9.]+|\S', text)
    position = 0
    doc = []

    def take(expected=None):
        nonlocal position
        if position >= len(tokens):
            raise SchemaError("Unexpected end of schema")
        token = tokens[position]
        position += 1
        if expected is not None and token != expected:
            raise SchemaError("Expected %r, found %r" % (expected, token))
        return token

    def peek():
        return tokens[position] if position < len(tokens) else None

    def attributes():
        found = {}
        if peek() == "(":
            take("(")
            while peek() != ")":
                name = take()
                value = None
                if peek() == ":":
                    take(":")
                    value = take()
                found[name] = value
                if peek() == ",":
                    take(",")
            take(")")
        return found

    while position < len(tokens):
        token = take()
        if token.startswith("///"):
            doc.append(token[3:].strip())
            continue
        if token.startswith("//"):
            continue
        if token == "namespace":
            schema.namespace = take()
            take(";")
        elif token in {"attribute", "file_identifier", "file_extension", "include"}:
            take()
            take(";")
        elif token == "root_type":
            schema.root = take()
            take(";")
        elif token == "enum":
            enum = Enum(take(), None, doc)
            doc = []
            take(":")
            enum.base = take()
            attributes()
            take("{")
            value = 0
            value_doc = []
            while peek() != "}":
                name = take()
                if name.startswith("///"):
                    value_doc.append(name[3:].strip())
                    continue
                if name.startswith("//"):
                    continue
                if peek() == "=":
                    take("=")
                    value = int(take())
                enum.values.append((name, value, value_doc))
                value_doc = []
                value += 1
                if peek() == ",":
                    take(",")
            take("}")
            schema.enums[enum.name] = enum
            schema.order.append(enum)
        elif token in {"table", "struct"}:
            table = Table(take(), doc)
            doc = []
            attributes()
            take("{")
            field_doc = []
            while peek() != "}":
                name = take()
                if name.startswith("///"):
                    field_doc.append(name[3:].strip())
                    continue
                if name.startswith("//"):
                    continue
                take(":")
                type = take()
                if type == "[":
                    type = "[" + take() + "]"
                    take("]")
                default = None
                if peek() == "=":
                    take("=")
                    default = take()
                table.fields.append(Field(name, type, default, attributes(), field_doc))
                field_doc = []
                take(";")
            take("}")
            schema.tables[table.name] = table
            schema.order.append(table)
        else:
            raise SchemaError("Unexpected %r" % token)

    for table in schema.tables.values():
        for field in table.fields:
            if field.type not in SCALARS and field.type != "string" and not schema.type_of(field.type):
                raise SchemaError("%s.%s: unknown type %s" % (table.name, field.name, field.type))
    if schema.root and schema.root not in schema.tables:
        raise SchemaError("Unknown root_type %s" % schema.root)
    return schema


def load():
    with open(SCHEMA) as file:
        return parse(file.read())


# -----------------------------------------------------------------------------
# Validation


def _describe(value):
    return json.dumps(value)[:60]


def validate(schema, type_name, value, path="$"):
    """The ways `value` breaks the schema for `type_name`, as messages: empty when it fits."""
    errors = []
    table = schema.tables.get(type_name)
    if table is None:
        raise SchemaError("Unknown table %s" % type_name)
    if not isinstance(value, dict):
        return ["%s: expected an object for %s, found %s" % (path, type_name, _describe(value))]
    fields = {field.name: field for field in table.fields}
    for key in value:
        if key not in fields:
            errors.append("%s.%s: not in %s" % (path, key, type_name))
    for field in table.fields:
        item = value.get(field.name)
        here = "%s.%s" % (path, field.name)
        if item is None:
            if field.required:
                errors.append("%s: required" % here)
            continue
        if field.vector:
            if not isinstance(item, list):
                if not field.any:
                    errors.append("%s: expected a list, found %s" % (here, _describe(item)))
                continue
            if field.any:
                continue
            for index, element in enumerate(item):
                if element is None and field.nullable_elements:
                    continue
                errors += _validate_value(schema, field, element, "%s[%d]" % (here, index))
        else:
            errors += _validate_value(schema, field, item, here)
    return errors


def _validate_value(schema, field, value, path):
    if field.any:
        return []
    kind = field.type
    if kind == "string":
        return [] if isinstance(value, str) else ["%s: expected a string, found %s" % (path, _describe(value))]
    if kind == "bool":
        # Blender writes some flags as 0 and 1.
        ok = isinstance(value, bool) or (isinstance(value, int) and value in (0, 1))
        return [] if ok else ["%s: expected a bool, found %s" % (path, _describe(value))]
    if kind in INTEGERS:
        ok = isinstance(value, int) and not isinstance(value, bool)
        return [] if ok else ["%s: expected an integer, found %s" % (path, _describe(value))]
    if kind in SCALARS:
        ok = isinstance(value, (int, float)) and not isinstance(value, bool)
        return [] if ok else ["%s: expected a number, found %s" % (path, _describe(value))]
    enum = schema.enums.get(kind)
    if enum:
        names = [name for name, _, _ in enum.values]
        if isinstance(value, str) and value in names:
            return []
        return ["%s: expected one of %s %s, found %s" % (path, kind, names, _describe(value))]
    return validate(schema, kind, value, path)


# -----------------------------------------------------------------------------
# Generation

HEADER = "Generated from native_ui.fbs by native_ui_schema.py: edit the schema, then run\n" \
         "`python3 source/blender/windowmanager/native_ui/native_ui_schema.py generate`."


def _camel(name):
    parts = name.split("_")
    return parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])


SWIFT_KEYWORDS = {"default", "operator", "protocol", "self", "Type", "in", "is", "as", "case", "class",
                  "enum", "func", "import", "init", "let", "var", "return", "struct", "switch", "where",
                  "repeat", "extension", "internal", "private", "public", "static", "subscript", "true",
                  "false", "nil", "super", "throw", "throws", "try", "while", "for", "if", "else", "do",
                  "break", "continue", "defer", "guard", "fallthrough", "associatedtype", "inout", "rethrows"}
KOTLIN_KEYWORDS = {"as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in",
                   "interface", "is", "null", "object", "package", "return", "super", "this", "throw",
                   "true", "try", "typealias", "typeof", "val", "var", "when", "while"}

SWIFT_SCALARS = {
    "bool": "Bool", "float": "Float", "float32": "Float", "double": "Double", "float64": "Double",
    "long": "Int64", "int64": "Int64", "ulong": "UInt64", "uint64": "UInt64",
}
KOTLIN_SCALARS = {
    "bool": "Boolean", "float": "Float", "float32": "Float", "double": "Double", "float64": "Double",
    "long": "Long", "int64": "Long", "ulong": "Long", "uint64": "Long",
}


def _swift_name(name):
    name = _camel(name)
    return "`%s`" % name if name in SWIFT_KEYWORDS else name


def _swift_case(name):
    case = _camel(name.lower())
    return "`%s`" % case if case in SWIFT_KEYWORDS else case


def _swift_doc(lines, indent):
    return "".join("%s/// %s\n" % (indent, line) if line else "%s///\n" % indent for line in lines)


def _swift_type(schema, field):
    if field.any:
        return "Open"
    if field.type == "string":
        base = "String"
    elif field.type in SCALARS:
        base = SWIFT_SCALARS.get(field.type, "Int")
    else:
        base = field.type
    if field.vector and field.nullable_elements:
        return "[%s?]" % base
    return "[%s]" % base if field.vector else base


def _swift_default(schema, field):
    """The value a field takes when absent, or None for an optional."""
    if field.vector and not field.any:
        return "[]"
    if field.type in SCALARS and not field.vector:
        if field.default == "null":
            return None
        if field.type == "bool":
            return "true" if field.default in {"true", "1"} else "false"
        return field.default or "0"
    enum = schema.enums.get(field.type)
    if enum and not field.vector and field.default and field.default != "null":
        return "." + _swift_case(field.default)
    return None


def _swift_read(schema, field, value):
    """An expression reading `value`, an `Any?` from `JSONSerialization`, as the field's type, or
    nil when it does not fit."""
    if field.any:
        return "Open(%s)" % value
    def element(kind, item):
        if kind == "string":
            return "%s as? String" % item
        if kind == "bool":
            return "flag(%s)" % item
        if kind in SCALARS:
            swift = SWIFT_SCALARS.get(kind, "Int")
            return "(%s as? NSNumber)?.%sValue" % (item, {"Bool": "bool", "Float": "float", "Double": "double",
                                                       "Int64": "int64", "UInt64": "uint64"}.get(swift, "int"))
        if kind in schema.enums:
            return "(%s as? String).map { %s(rawValue: $0) ?? .unknown }" % (item, kind)
        return "(%s as? [String: Any]).flatMap(%s.init(json:))" % (item, kind)
    if field.vector:
        inner = element(field.type, "$0")
        if field.nullable_elements:
            return "(%s as? [Any])?.map { $0 is NSNull ? nil : %s }" % (value, inner)
        return "(%s as? [Any])?.compactMap { %s }" % (value, inner)
    return element(field.type, value)


def _swift_failable(schema, table):
    return any(field.required and _swift_default(schema, field) is None
               for field in table.fields if not field.deprecated)


def generate_swift(schema):
    out = ["// SPDX-FileCopyrightText: 2026 Blender Authors\n//\n// SPDX-License-Identifier: GPL-2.0-or-later\n\n"]
    out.append("".join("// %s\n" % line for line in HEADER.splitlines()))
    out.append("\nimport Foundation\n\n")
    out.append(SWIFT_SUPPORT)
    body = [SWIFT_OPEN]
    for item in schema.order:
        if isinstance(item, Enum):
            body.append("\n" + _swift_doc(item.doc, ""))
            body.append("enum %s: String, Equatable, Sendable {\n" % item.name)
            for name, _, doc in item.values:
                body.append(_swift_doc(doc, "  "))
                body.append("  case %s = \"%s\"\n" % (_swift_case(name), name))
            body.append("  /// A value from a newer Blender than this interface knows.\n")
            body.append("  case unknown\n}\n")
            continue
        body.append("\n" + _swift_doc(item.doc, ""))
        body.append("struct %s: Equatable, @unchecked Sendable {\n" % item.name)
        fields = [field for field in item.fields if not field.deprecated]
        for field in fields:
            body.append(_swift_doc(field.doc, "  "))
            # An open part holds JSON's null itself.
            optional = "" if (_swift_default(schema, field) is not None or field.required or field.any) else "?"
            body.append("  var %s: %s%s\n" % (_swift_name(field.name), _swift_type(schema, field), optional))
        failable = _swift_failable(schema, item)
        body.append("\n  /// From the snapshot as `JSONSerialization` reads it.%s\n"
                    % (" Nil without its required fields." if failable else ""))
        body.append("  init%s(json: [String: Any]) {\n" % ("?" if failable else ""))
        for field in fields:
            name = _swift_name(field.name)
            read = _swift_read(schema, field, "json[\"%s\"]" % field.name)
            default = _swift_default(schema, field)
            if field.any:
                body.append("    %s = %s\n" % (name, read))
            elif field.required and default is None:
                body.append("    guard let %s = %s else {\n      return nil\n    }\n" % (name.strip("`"), read))
                body.append("    self.%s = %s\n" % (name, name.strip("`")))
            elif default is not None:
                body.append("    %s = %s ?? %s\n" % (name, read, default))
            else:
                body.append("    %s = %s\n" % (name, read))
        body.append("  }\n}\n")
    # Within a namespace of their own, clear of the interface's own types.
    text = "".join(body)
    out.append("\nenum NativeUI {\n")
    out.append("".join(("  " + line if line.strip() else line) for line in text.splitlines(True)))
    out.append("}\n")
    return "".join(out)


SWIFT_OPEN = '''/// A part of a snapshot the schema leaves open, as `JSONSerialization` read it: any JSON, for parts
/// still to be described. Nil for JSON\'s null.
struct Open: Equatable, @unchecked Sendable {
  let value: Any?

  init(_ value: Any?) {
    self.value = value is NSNull ? nil : value
  }

  var dictionary: [String: Any]? { value as? [String: Any] }

  static func == (a: Open, b: Open) -> Bool {
    switch (a.value, b.value) {
      case (nil, nil): return true
      case let (x as NSObject, y as NSObject): return x.isEqual(y)
      default: return false
    }
  }
}
'''

SWIFT_SUPPORT = '''/// Blender writes some flags as 0 and 1, others as false and true.
private func flag(_ value: Any?) -> Bool? {
  (value as? NSNumber)?.boolValue
}
'''


def _kotlin_name(name):
    name = _camel(name)
    return "`%s`" % name if name in KOTLIN_KEYWORDS else name


def _kotlin_type(schema, field):
    if field.any:
        return "JsonElement"
    if field.type == "string":
        base = "String"
    elif field.type in SCALARS:
        base = KOTLIN_SCALARS.get(field.type, "Int")
    else:
        base = field.type
    if field.vector and field.nullable_elements:
        return "List<%s?>" % base
    return "List<%s>" % base if field.vector else base


def _kotlin_doc(lines, indent):
    if not lines:
        return ""
    if len(lines) == 1:
        return "%s/** %s */\n" % (indent, lines[0])
    return "%s/**\n%s%s */\n" % (indent, "".join("%s * %s\n" % (indent, line) for line in lines), indent)


def generate_kotlin(schema):
    package = "org." + schema.namespace.lower() if schema.namespace else "org.blender.nativeui"
    out = ["// SPDX-FileCopyrightText: 2026 Blender Authors\n//\n// SPDX-License-Identifier: GPL-2.0-or-later\n\n"]
    out.append("".join("// %s\n" % line for line in HEADER.splitlines()))
    out.append("\n@file:Suppress(\"unused\")\n\npackage %s\n\n" % package)
    out.append("import kotlinx.serialization.KSerializer\n")
    out.append("import kotlinx.serialization.SerialName\n")
    out.append("import kotlinx.serialization.Serializable\n")
    out.append("import kotlinx.serialization.descriptors.PrimitiveKind\n")
    out.append("import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor\n")
    out.append("import kotlinx.serialization.encoding.Decoder\n")
    out.append("import kotlinx.serialization.encoding.Encoder\n")
    out.append("import kotlinx.serialization.json.JsonDecoder\n")
    out.append("import kotlinx.serialization.json.JsonElement\n")
    out.append("import kotlinx.serialization.json.JsonPrimitive\n")
    out.append("import kotlinx.serialization.json.booleanOrNull\n")
    out.append("import kotlinx.serialization.json.intOrNull\n\n")
    out.append(KOTLIN_SUPPORT)
    for item in schema.order:
        if isinstance(item, Enum):
            out.append("\n" + _kotlin_doc(item.doc, ""))
            out.append("@Serializable\nenum class %s {\n" % item.name)
            for name, _, doc in item.values:
                out.append(_kotlin_doc(doc, "  "))
                out.append("  @SerialName(\"%s\") %s,\n" % (name, name))
            out.append("}\n")
            continue
        out.append("\n" + _kotlin_doc(item.doc, ""))
        fields = [field for field in item.fields if not field.deprecated]
        if not fields:
            out.append("@Serializable\nclass %s\n" % item.name)
            continue
        out.append("@Serializable\ndata class %s(\n" % item.name)
        for field in fields:
            out.append(_kotlin_doc(field.doc, "  "))
            kind = _kotlin_type(schema, field)
            default = _swift_default(schema, field)
            if field.type == "bool" and not field.vector:
                annotation = "@Serializable(with = Flag::class) "
            else:
                annotation = ""
            if default == "[]":
                value = "%s = emptyList()" % kind
            elif default is not None and default.startswith("."):
                value = "%s = %s.%s" % (kind, field.type, field.default)
            elif default is not None:
                value = "%s = %s" % (kind, default + ("f" if kind == "Float" and "." in default else ".0f" if kind == "Float" else ""))
            else:
                value = "%s? = null" % kind
            out.append("  @SerialName(\"%s\") %sval %s: %s,\n" % (field.name, annotation, _kotlin_name(field.name), value))
        out.append(")\n")
    return "".join(out)


KOTLIN_SUPPORT = '''/** Blender writes some flags as 0 and 1, others as false and true. */
object Flag : KSerializer<Boolean> {
  override val descriptor = PrimitiveSerialDescriptor("Flag", PrimitiveKind.BOOLEAN)

  override fun deserialize(decoder: Decoder): Boolean {
    val element = (decoder as JsonDecoder).decodeJsonElement() as JsonPrimitive
    return element.booleanOrNull ?: ((element.intOrNull ?: 0) != 0)
  }

  override fun serialize(encoder: Encoder, value: Boolean) = encoder.encodeBoolean(value)
}
'''


def generated():
    schema = load()
    return {"swift": generate_swift(schema), "kotlin": generate_kotlin(schema)}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("generate", help="Write the generated files")
    commands.add_parser("check", help="Fail when the generated files are out of date")
    validate_parser = commands.add_parser("validate", help="Validate JSON files against a table")
    validate_parser.add_argument("type", help="The table the files hold, such as Toolbar")
    validate_parser.add_argument("files", nargs="+")
    args = parser.parse_args()

    if args.command == "generate":
        for language, text in generated().items():
            os.makedirs(os.path.dirname(GENERATED[language]), exist_ok=True)
            with open(GENERATED[language], "w") as file:
                file.write(text)
            print("Wrote %s" % os.path.relpath(GENERATED[language]))
    elif args.command == "check":
        stale = []
        for language, text in generated().items():
            try:
                with open(GENERATED[language]) as file:
                    current = file.read()
            except OSError:
                current = None
            if current != text:
                stale.append(GENERATED[language])
        for path in stale:
            print("Out of date: %s (run `native_ui_schema.py generate`)" % path)
        sys.exit(1 if stale else 0)
    else:
        schema = load()
        failed = False
        for path in args.files:
            with open(path) as file:
                errors = validate(schema, args.type, json.load(file))
            for error in errors:
                print("%s: %s" % (path, error))
            failed = failed or bool(errors)
        sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
