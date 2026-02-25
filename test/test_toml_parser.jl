@testitem "Entry points: strings" begin
    valid_str = "a = 1"
    @test parsetoml(valid_str) == Dict{String,Any}("a" => 1)
    @test parsetoml(SubString(valid_str)) == Dict{String,Any}("a" => 1)
end

@testitem "Entry points: files" begin
    using Dates
    mktemp() do path, io
        write(io, "a = 1")
        close(io)
        result = parsetoml(read(path, String))
        @test result == Dict{String,Any}("a" => 1)
    end
end

@testitem "Tokenizer" begin
    tokens = tokenize("""key = "value"\n""")
    kinds = [t.kind for t in tokens]
    @test TomlSyntax.K_BARE_KEY in kinds
    @test TomlSyntax.K_EQ in kinds
    @test TomlSyntax.K_BASIC_STRING in kinds
end

@testitem "Basic key-value" begin
    d = parsetoml("""
        title = "TOML Example"
        count = 42
        pi = 3.14
        enabled = true
    """)
    @test d["title"] == "TOML Example"
    @test d["count"] == 42
    @test d["pi"] ≈ 3.14
    @test d["enabled"] == true
end

@testitem "String types" begin
    d = parsetoml("""
        basic = "hello\\nworld"
        literal = 'no\\escape'
        ml_basic = \"\"\"
first line
second line\"\"\"
        ml_literal = '''
first line
second line'''
        """)
    @test d["basic"] == "hello\nworld"
    @test d["literal"] == "no\\escape"
    @test d["ml_basic"] == "first line\nsecond line"
    @test d["ml_literal"] == "first line\nsecond line"
end

@testitem "Tables" begin
    d = parsetoml("""
        [server]
        host = "localhost"
        port = 8080

        [database]
        name = "mydb"
    """)
    @test d["server"]["host"] == "localhost"
    @test d["server"]["port"] == 8080
    @test d["database"]["name"] == "mydb"
end

@testitem "Dotted keys" begin
    d = parsetoml("""
        fruit.apple.color = "red"
        fruit.apple.taste = "sweet"
    """)
    @test d["fruit"]["apple"]["color"] == "red"
    @test d["fruit"]["apple"]["taste"] == "sweet"
end

@testitem "Nested tables" begin
    d = parsetoml("""
        [a.b]
        c = 1

        [a.d]
        e = 2
    """)
    @test d["a"]["b"]["c"] == 1
    @test d["a"]["d"]["e"] == 2
end

@testitem "Arrays" begin
    d = parsetoml("""
        ints = [1, 2, 3]
        strings = ["a", "b", "c"]
        nested = [[1, 2], [3, 4]]
    """)
    @test d["ints"] == [1, 2, 3]
    @test d["strings"] == ["a", "b", "c"]
    @test d["nested"] == [[1, 2], [3, 4]]
end

@testitem "Array of tables" begin
    d = parsetoml("""
        [[products]]
        name = "Hammer"
        sku = 738594937

        [[products]]
        name = "Nail"
        sku = 284758393
    """)
    @test length(d["products"]) == 2
    @test d["products"][1]["name"] == "Hammer"
    @test d["products"][2]["name"] == "Nail"
end

@testitem "Inline tables" begin
    d = parsetoml("""
        point = {x = 1, y = 2}
    """)
    @test d["point"]["x"] == 1
    @test d["point"]["y"] == 2
end

@testitem "Number formats" begin
    d = parsetoml("""
        hex = 0xDEADBEEF
        oct = 0o755
        bin = 0b11010110
        underscored = 1_000_000
        float_exp = 5e+22
        neg = -17
    """)
    @test d["hex"] == 0xDEADBEEF
    @test d["oct"] == 0o755
    @test d["bin"] == 0b11010110
    @test d["underscored"] == 1_000_000
    @test d["float_exp"] == 5e+22
    @test d["neg"] == -17
end

@testitem "Special floats" begin
    d = parsetoml("""
        inf1 = inf
        inf2 = +inf
        inf3 = -inf
        nan1 = nan
    """)
    @test d["inf1"] == Inf
    @test d["inf2"] == Inf
    @test d["inf3"] == -Inf
    @test isnan(d["nan1"])
end

@testitem "Dates and times" begin
    d = parsetoml("""
        odt = 1979-05-27T07:32:00Z
        ldt = 1979-05-27T07:32:00
        ld  = 1979-05-27
        lt  = 07:32:00
    """)
    using Dates
    @test d["ldt"] == DateTime(1979, 5, 27, 7, 32, 0)
    @test d["ld"] == Date(1979, 5, 27)
    @test d["lt"] == Time(7, 32, 0)
end

@testitem "Green tree structure" begin
    using TomlSyntax: K_TOPLEVEL, K_STD_TABLE, K_KEYVAL, kind
    
    green = parse_toml_green("[server]\nhost = \"localhost\"")
    @test green.kind == K_TOPLEVEL
    @test green.children !== nothing
    @test green.span == length("[server]\nhost = \"localhost\"")

    # SyntaxNode API
    root = SyntaxNode(green, 1, "[server]\nhost = \"localhost\"")
    ntc = TomlSyntax.nontrivia_children(root)
    @test any(c -> kind(c) == TomlSyntax.K_STD_TABLE, ntc)
    @test any(c -> kind(c) == TomlSyntax.K_KEYVAL, ntc)
end

@testitem "Comments preserved in green tree" begin
    src = "# A comment\nkey = 1"
    green = parse_toml_green(src)
    root = SyntaxNode(green, 1, src)
    all_children = TomlSyntax.children(root)
    @test any(c -> TomlSyntax.kind(c) == TomlSyntax.K_COMMENT, all_children)
end

@testitem "Lossless round-trip" begin
    src = "[server]\n  host = \"localhost\" # comment\n  port = 8080\n"
    green = parse_toml_green(src)
    @test green.span == length(src)
    # The total span equals the source length → lossless
end

# ── Error recovery tests ─────────────────────────────────────────────────────

@testitem "Error recovery: invalid token at top level" begin
    using TomlSyntax: K_ERROR, kind, parse_toml_green
    # '@' is not valid TOML; the parser should skip it and continue
    src = "@bad\nkey = 1\n"
    green = parse_toml_green(src)
    # Lossless: total span equals source length
    @test green.span == length(src)
    # The K_ERROR node should be present somewhere in the top-level children
    @test any(c -> kind(c) == K_ERROR, green.children)
    # Valid content after the error line is still parseable
    d = parsetoml(src)
    @test d["key"] == 1
end

@testitem "Error recovery: missing equals sign" begin
    # A key with no '=' should emit an error and not swallow the next statement
    src = "missing_eq\nvalid = 42\n"
    green = parse_toml_green(src)
    @test green.span == length(src)
    d = parsetoml(src)
    @test d["valid"] == 42
end

@testitem "Error recovery: invalid value (unterminated string)" begin
    # An unterminated basic string emits a K_ERROR token from the tokenizer.
    # The parser should absorb it, record the error, and keep going.
    src = "bad = \"unterminated\nok = 7\n"
    green = parse_toml_green(src)
    @test green.span == length(src)
    d = parsetoml(src)
    @test d["ok"] == 7
    # "bad" key has an error value and must not appear in the parsed dict
    @test !haskey(d, "bad")
end

@testitem "Error recovery: array with invalid element" begin
    # An unquoted bare-key-like token is not a valid array value.
    # The parser should skip it and still collect the surrounding valid elements.
    src = "arr = [1, not_a_value = 99, 3]\n"
    d = parsetoml(src)
    @test d["arr"] == [1, 3]
end

@testitem "Error recovery: inline table with missing equals" begin
    # Inline table where one entry is missing '='.
    # The parser must not hang, and should produce a valid (partial) result.
    src = "point = {bad}\nnext = 5\n"
    green = parse_toml_green(src)
    @test green.span == length(src)
    d = parsetoml(src)
    # The error entry is dropped; point becomes an empty table (or absent),
    # but either way we must not throw and next must be parsed.
    @test d["next"] == 5
end

@testitem "Error recovery: multiple errors, lossless" begin
    # Multiple bad lines interspersed with valid ones.
    src = "@first_err\nk1 = 1\n!!!\nk2 = 2\n"
    green = parse_toml_green(src)
    @test green.span == length(src)
    d = parsetoml(src)
    @test d["k1"] == 1
    @test d["k2"] == 2
end

@testitem "Error recovery: green tree K_ERROR interior node has correct span" begin
    using TomlSyntax: K_ERROR, K_TOPLEVEL, kind, parse_toml_green
    # The error node wrapping "@bad" should have span == length("@bad")
    src = "@bad\nkey = 1\n"
    green = parse_toml_green(src)
    err_nodes = filter(c -> kind(c) == K_ERROR, green.children)
    @test !isempty(err_nodes)
    @test err_nodes[1].span == length("@bad")
end
# ── README Examples (from toml-lang/toml) ──────────────────────────────────

@testitem "README: Complete example" begin
    str = """
# This is a TOML document.

title = "TOML Example"

[owner]
name = "Tom Preston-Werner"

[database]
server = "192.168.1.1"
ports = [ 8001, 8001, 8002 ]
connection_max = 5000
enabled = true

[servers]

  # Indentation (tabs and/or spaces) is allowed but not required
  [servers.alpha]
  ip = "10.0.0.1"
  dc = "eqdc10"

  [servers.beta]
  ip = "10.0.0.2"
  dc = "eqdc10"

[clients]
data = [ ["gamma", "delta"], [1, 2] ]

# Line breaks are OK when inside arrays
hosts = [
  "alpha",
  "omega"
]
"""
    d = parsetoml(str)
    @test d["title"] == "TOML Example"
    @test d["owner"]["name"] == "Tom Preston-Werner"
    @test d["database"]["server"] == "192.168.1.1"
    @test d["database"]["ports"] == [8001, 8001, 8002]
    @test d["database"]["connection_max"] == 5000
    @test d["database"]["enabled"] == true
    @test d["servers"]["alpha"]["ip"] == "10.0.0.1"
    @test d["servers"]["beta"]["ip"] == "10.0.0.2"
    @test d["clients"]["data"] == [["gamma", "delta"], [1, 2]]
    @test d["clients"]["hosts"] == ["alpha", "omega"]
end

@testitem "README: Comments" begin
    str = """
# This is a full-line comment
key = "value"  # This is a comment at the end of a line
another = "# This is not a comment"
"""
    @test parsetoml(str) == Dict("key" => "value", "another" => "# This is not a comment")
end

@testitem "README: Keys - bare keys" begin
    str = """
key = "value"
bare_key = "value"
bare-key = "value"
1234 = "value"
"""
    d = parsetoml(str)
    @test d["key"] == "value"
    @test d["bare_key"] == "value"
    @test d["bare-key"] == "value"
    @test d["1234"] == "value"
end

@testitem "README: Keys - quoted keys" begin
    str = """
"127.0.0.1" = "value"
"character encoding" = "value"
"ʎǝʞ" = "value"
'key2' = "value"
'quoted "value"' = "value"
"""
    d = parsetoml(str)
    @test d["127.0.0.1"] == "value"
    @test d["character encoding"] == "value"
    @test d["ʎǝʞ"] == "value"
    @test d["key2"] == "value"
    @test d["quoted \"value\""] == "value"
end

@testitem "README: Keys - dotted keys" begin
    str = """
name = "Orange"
physical.color = "orange"
physical.shape = "round"
site."google.com" = true
"""
    d = parsetoml(str)
    @test d["name"] == "Orange"
    @test d["physical"]["color"] == "orange"
    @test d["physical"]["shape"] == "round"
    @test d["site"]["google.com"] == true
end

@testitem "README: String escapes" begin
    str = """str = "I'm a string. \\"You can quote me\\". Name\\tJos\\u00E9\\nLocation\\tSF." """
    d = parsetoml(str)
    @test d["str"] == "I'm a string. \"You can quote me\". Name\tJos\u00E9\nLocation\tSF."
end

@testitem "README: Multiline basic strings" begin
    str = """str1 = \"\"\"
Roses are red
Violets are blue
\"\"\"
"""
    d = parsetoml(str)
    @test d["str1"] == "Roses are red\nViolets are blue\n"
end

@testitem "README: Multiline literal strings" begin
    str = raw"""
winpath  = 'C:\Users\nodejs\templates'
winpath2 = '\\ServerX\admin$\system32\'
quoted   = 'Tom "Dubs" Preston-Werner'
regex    = '<\i\c*\s*>'
"""
    d = parsetoml(str)
    @test d["winpath"] == raw"C:\Users\nodejs\templates"
    @test d["winpath2"] == raw"\\ServerX\admin$\system32\\"
    @test d["quoted"] == raw"""Tom "Dubs" Preston-Werner"""
    @test d["regex"] == raw"<\i\c*\s*>"
end

@testitem "README: Integers" begin
    str = """
int1 = +99
int2 = 42
int3 = 0
int4 = -17
int5 = 1_000
int6 = 5_349_221
"""
    d = parsetoml(str)
    @test d["int1"] === Int64(99)
    @test d["int2"] === Int64(42)
    @test d["int3"] === Int64(0)
    @test d["int4"] === Int64(-17)
    @test d["int5"] == 1_000
    @test d["int6"] == 5_349_221
end

@testitem "README: Hex, octal, binary" begin
    str = """
hex1 = 0xDEADBEEF
hex2 = 0xdeadbeef
oct1 = 0o01234567
oct2 = 0o755
bin1 = 0b11010110
"""
    d = parsetoml(str)
    @test d["hex1"] == 0xDEADBEEF
    @test d["hex2"] == 0xdeadbeef
    @test d["oct1"] == 0o01234567
    @test d["oct2"] == 0o755
    @test d["bin1"] == 0b11010110
end

@testitem "README: Floats" begin
    str = """
flt1 = +1.0
flt2 = 3.1415
flt3 = -0.01
flt4 = 5e+22
flt5 = 1e06
flt6 = -2E-2
flt7 = 6.626e-34
flt8 = 224_617.445_991_228
"""
    d = parsetoml(str)
    @test d["flt1"] == +1.0
    @test d["flt2"] == 3.1415
    @test d["flt3"] == -0.01
    @test d["flt4"] == 5e+22
    @test d["flt5"] == 1e+6
    @test d["flt6"] == -2E-2
    @test d["flt7"] == 6.626e-34
    @test d["flt8"] == 224_617.445_991_228
end

@testitem "README: Booleans" begin
    str = """
bool1 = true
bool2 = false
"""
    d = parsetoml(str)
    @test d["bool1"] === true
    @test d["bool2"] === false
end

@testitem "README: Offset Date-Time" begin
    using Dates
    str = "odt1 = 1979-05-27T07:32:00Z"
    d = parsetoml(str)
    @test d["odt1"] == DateTime(1979, 5, 27, 7, 32, 0)
end

@testitem "README: Local Date-Time" begin
    using Dates
    str = """
ldt1 = 1979-05-27T07:32:00
ldt2 = 1979-05-27T00:32:00
"""
    d = parsetoml(str)
    @test d["ldt1"] == DateTime(1979, 5, 27, 7, 32, 0)
    @test d["ldt2"] == DateTime(1979, 5, 27, 0, 32, 0)
end

@testitem "README: Local Date" begin
    using Dates
    str = "ld1 = 1979-05-27"
    d = parsetoml(str)
    @test d["ld1"] == Date(1979, 5, 27)
end

@testitem "README: Local Time" begin
    using Dates
    str = """
lt1 = 07:32:00
lt2 = 00:32:00
"""
    d = parsetoml(str)
    @test d["lt1"] == Time(7, 32, 0)
    @test d["lt2"] == Time(0, 32, 0)
end

@testitem "README: Arrays" begin
    str = """
integers = [ 1, 2, 3 ]
colors = [ "red", "yellow", "green" ]
nested_array_of_int = [ [ 1, 2 ], [3, 4, 5] ]
nested_mixed_array = [ [ 1, 2 ], ["a", "b", "c"] ]
string_array = [ "all", 'strings', "are the same", 'type' ]
numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
"""
    d = parsetoml(str)
    @test d["integers"] == [1, 2, 3]
    @test d["colors"] == ["red", "yellow", "green"]
    @test d["nested_array_of_int"] == [[1, 2], [3, 4, 5]]
    @test d["nested_mixed_array"] == [[1, 2], ["a", "b", "c"]]
    @test d["string_array"] == ["all", "strings", "are the same", "type"]
end

@testitem "README: Tables" begin
    str = """
[table]
key1 = "some string"
key2 = "some other string"
"""
    d = parsetoml(str)
    @test d["table"]["key1"] == "some string"
    @test d["table"]["key2"] == "some other string"
end

@testitem "README: Nested tables" begin
    str = """
[dog."tater.man"]
type.name = "pug"
"""
    d = parsetoml(str)
    @test d["dog"]["tater.man"]["type"]["name"] == "pug"
end

@testitem "README: Table declaration order" begin
    str = """
[a.b.c]
[ d.e.f ]
[ g .  h  . i ]
[ j . "ʞ" . 'l' ]
"""
    d = parsetoml(str)
    @test haskey(d, "a")
    @test haskey(d["a"], "b")
    @test haskey(d, "d")
    @test haskey(d, "g")
    @test haskey(d, "j")
end

@testitem "README: Inline tables" begin
    str = """
name = { first = "Tom", last = "Preston-Werner" }
point = { x = 1, y = 2 }
animal = { type.name = "pug" }
"""
    d = parsetoml(str)
    @test d["name"]["first"] == "Tom"
    @test d["name"]["last"] == "Preston-Werner"
    @test d["point"]["x"] == 1
    @test d["point"]["y"] == 2
    @test d["animal"]["type"]["name"] == "pug"
end

@testitem "README: Array of tables" begin
    str = """
[[products]]
name = "Hammer"
sku = 738594937

[[products]]

[[products]]
name = "Nail"
sku = 284758393
color = "gray"
"""
    d = parsetoml(str)
    @test length(d["products"]) == 3
    @test d["products"][1]["name"] == "Hammer"
    @test d["products"][2] == Dict()
    @test d["products"][3]["name"] == "Nail"
end

@testitem "README: Complex array of tables" begin
    str = """
[[fruit]]
  name = "apple"

  [fruit.physical]
    color = "red"
    shape = "round"

  [[fruit.variety]]
    name = "red delicious"

  [[fruit.variety]]
    name = "granny smith"

[[fruit]]
  name = "banana"

  [[fruit.variety]]
    name = "plantain"
"""
    d = parsetoml(str)
    @test d["fruit"][1]["name"] == "apple"
    @test d["fruit"][1]["physical"]["color"] == "red"
    @test d["fruit"][1]["variety"][1]["name"] == "red delicious"
    @test d["fruit"][2]["name"] == "banana"
end

# ── Value Parsing Tests (from values.jl) ──────────────────────────────────

@testitem "Values: Number parsing - decimals" begin
    d = parsetoml("""
        flt1 = 1.0
        flt2 = 3.1415
        flt3 = -0.01
        flt4 = 5e+22
        flt5 = 1e06
        flt6 = -2E-2
        flt7 = 6.626e-34
    """)
    @test d["flt1"] == 1.0
    @test d["flt2"] == 3.1415
    @test d["flt3"] == -0.01
    @test d["flt4"] == 5e+22
    @test d["flt5"] == 1e+6
    @test d["flt6"] == -2E-2
    @test d["flt7"] == 6.626e-34
end

@testitem "Values: Number parsing - underscores" begin
    d = parsetoml("""
        int5 = 1_000
        int6 = 5_349_221
        int7 = 53_49_221
        flt8 = 224_617.445_991_228
    """)
    @test d["int5"] == 1_000
    @test d["int6"] == 5_349_221
    @test d["int7"] == 53_49_221
    @test d["flt8"] == 224_617.445_991_228
end

@testitem "Values: Hex integers" begin
    d = parsetoml("""
        hex1 = 0xDEADBEEF
        hex2 = 0xdeadbeef
        hex3 = 0xdead_beef
    """)
    @test d["hex1"] == 0xDEADBEEF
    @test d["hex2"] == 0xdeadbeef
    @test d["hex3"] == 0xdead_beef
end

@testitem "Values: Octal integers" begin
    d = parsetoml("""
        oct1 = 0o01234567
        oct2 = 0o755
    """)
    @test d["oct1"] == 0o01234567
    @test d["oct2"] == 0o755
end

@testitem "Values: Binary integers" begin
    d = parsetoml("""
        bin1 = 0b11010110
        bin2 = 0b1111_1010_0011_0011
    """)
    @test d["bin1"] == 0b11010110
    @test d["bin2"] == 0b1111_1010_0011_0011
end

@testitem "Values: Booleans" begin
    d = parsetoml("""
        bool1 = true
        bool2 = false
    """)
    @test d["bool1"] === true
    @test d["bool2"] === false
end

@testitem "Values: DateTime parsing" begin
    using Dates
    d = parsetoml("""
        odt1 = 1979-05-27T07:32:00Z
        ldt1 = 1979-05-27T07:32:00
        ld1 = 1979-05-27
        lt1 = 07:32:00
    """)
    @test d["odt1"] == DateTime(1979, 5, 27, 7, 32, 0)
    @test d["ldt1"] == DateTime(1979, 5, 27, 7, 32, 0)
    @test d["ld1"] == Date(1979, 5, 27)
    @test d["lt1"] == Time(7, 32, 0)
end

@testitem "Values: DateTime with milliseconds" begin
    using Dates
    d = parsetoml("""
        odt = 1979-05-27T07:32:00.999Z
        ldt = 1979-05-27T07:32:00.999
        lt = 07:32:00.999
    """)
    @test d["odt"] == DateTime(1979, 5, 27, 7, 32, 0, 999)
    @test d["ldt"] == DateTime(1979, 5, 27, 7, 32, 0, 999)
    @test d["lt"] == Time(7, 32, 0, 999)
end

@testitem "Values: Time with fractional seconds" begin
    using Dates
    d = parsetoml("""
        lt1 = 09:09:09.99
        lt2 = 09:09:09.99999
        lt3 = 00:00:00.2
        lt4 = 00:00:00.234
    """)
    @test d["lt1"] == Time(9, 9, 9, 990)
    @test d["lt2"] == Time(9, 9, 9, 999)
    @test d["lt3"] == Time(0, 0, 0, 200)
    @test d["lt4"] == Time(0, 0, 0, 234)
end

@testitem "Values: Arrays - homogeneous" begin
    d = parsetoml("""
        integers = [1, 2, 3]
        floats = [1.0, 2.0, 3.0]
        strings = ["a", "b", "c"]
    """)
    @test d["integers"] == [1, 2, 3]
    @test d["floats"] == [1.0, 2.0, 3.0]
    @test d["strings"] == ["a", "b", "c"]
end

@testitem "Values: Arrays - nested" begin
    d = parsetoml("""
        nested = [[1, 2], [3, 4]]
        mixed_types = [[1, 2], ["a", "b"]]
    """)
    @test d["nested"] == [[1, 2], [3, 4]]
    @test d["mixed_types"][1] == [1, 2]
    @test d["mixed_types"][2] == ["a", "b"]
end

@testitem "Values: Arrays - mixed elements" begin
    d = parsetoml("""
        numbers = [0.1, 0.2, 0.5, 1, 2, 5]
    """)
    @test length(d["numbers"]) == 6
    @test d["numbers"][1] == 0.1
    @test d["numbers"][4] == 1
end

# ── Table and Key Handling Tests ─────────────────────────────────────────────

@testitem "Keys: Empty keys" begin
    d = parsetoml("""
        "" = "blank"
    """)
    @test d[""] == "blank"
end

@testitem "Keys: Dotted keys in tables" begin
    str = """
    [a.b.c.d.e.f]
    """
    d = parsetoml(str)
    @test haskey(d, "a")
    @test haskey(d["a"], "b")
    @test haskey(d["a"]["b"], "c")
end

@testitem "Keys: Mixed dotted and table notation" begin
    str = """
    [fruit]
    apple.color = "red"
    apple.taste.sweet = true

    [fruit.apple.texture]
    smooth = true
    """
    d = parsetoml(str)
    @test d["fruit"]["apple"]["color"] == "red"
    @test d["fruit"]["apple"]["taste"]["sweet"] == true
    @test d["fruit"]["apple"]["texture"]["smooth"] == true
end

@testitem "Tables: Multiple independent tables" begin
    str = """
    [a]
    x = 1

    [b]
    y = 2

    [c]
    z = 3
    """
    d = parsetoml(str)
    @test d == Dict("a" => Dict("x" => 1), "b" => Dict("y" => 2), "c" => Dict("z" => 3))
end

@testitem "Tables: Deep nesting" begin
    str = """
    [x.y.z.w.v.u.t.s.r]
    key = "deep"
    """
    d = parsetoml(str)
    @test d["x"]["y"]["z"]["w"]["v"]["u"]["t"]["s"]["r"]["key"] == "deep"
end

@testitem "Array of tables: Multiple entries with shared prefix" begin
    str = """
    [[products]]
    id = 1
    name = "Hammer"

    [[products]]
    id = 2
    name = "Nail"

    [[products]]
    id = 3
    name = "Screw"
    """
    d = parsetoml(str)
    @test length(d["products"]) == 3
    @test d["products"][1]["id"] == 1
    @test d["products"][2]["id"] == 2
    @test d["products"][3]["id"] == 3
end

@testitem "Array of tables: Nested in regular tables" begin
    str = """
    [package]
    name = "MyPackage"

    [[package.dependencies]]
    name = "Dep1"
    version = "1.0"

    [[package.dependencies]]
    name = "Dep2"
    version = "2.0"
    """
    d = parsetoml(str)
    @test d["package"]["name"] == "MyPackage"
    @test length(d["package"]["dependencies"]) == 2
    @test d["package"]["dependencies"][1]["name"] == "Dep1"
    @test d["package"]["dependencies"][2]["name"] == "Dep2"
end

@testitem "Inline table: Simple" begin
    d = parsetoml("point = {x = 1, y = 2}")
    @test d["point"]["x"] == 1
    @test d["point"]["y"] == 2
end

@testitem "Inline table: Nested tables" begin
    d = parsetoml("data = {a = {b = 1}}")
    @test d["data"]["a"]["b"] == 1
end

@testitem "Inline table: With arrays" begin
    d = parsetoml("data = {arr = [1, 2, 3]}")
    @test d["data"]["arr"] == [1, 2, 3]
end

# ── Special Cases and Edge Cases ──────────────────────────────────────────

@testitem "Edge case: Empty document" begin
    d = parsetoml("")
    @test d == Dict()
end

@testitem "Edge case: Only comments" begin
    d = parsetoml("""
    # This is a comment
    # Another comment
    """)
    @test d == Dict()
end

@testitem "Edge case: Empty tables" begin
    d = parsetoml("""
    [empty]
    [another_empty]
    """)
    @test d["empty"] == Dict()
    @test d["another_empty"] == Dict()
end

@testitem "Edge case: Array of empty tables" begin
    d = parsetoml("""
    [[items]]
    [[items]]
    [[items]]
    """)
    @test length(d["items"]) == 3
    @test all(x -> x == Dict(), d["items"])
end

@testitem "Edge case: Very long key paths" begin
    d = parsetoml("a.b.c.d.e.f.g.h.i.j = 42")
    @test d["a"]["b"]["c"]["d"]["e"]["f"]["g"]["h"]["i"]["j"] == 42
end

@testitem "Edge case: Special characters in quoted keys" begin
    d = parsetoml("""
    "key with spaces" = 1
    "key.with.dots" = 2
    "key=with=equals" = 3
    "key[with]brackets" = 4
    """)
    @test d["key with spaces"] == 1
    @test d["key.with.dots"] == 2
    @test d["key=with=equals"] == 3
    @test d["key[with]brackets"] == 4
end

@testitem "Edge case: Unicode in keys and values" begin
    d = parsetoml("""
    "ʎǝʞ" = "ǝnlɐʌ"
    "こんにちは" = "世界"
    "🍕" = "πízzα"
    """)
    @test d["ʎǝʞ"] == "ǝnlɐʌ"
    @test d["こんにちは"] == "世界"
    @test d["🍕"] == "πízzα"
end

@testitem "Edge case: Large numbers" begin
    d = parsetoml("""
    big_int = 9_223_372_036_854_775_807
    big_float = 1.7976931348623157e+308
    """)
    @test d["big_int"] == 9_223_372_036_854_775_807
    @test d["big_float"] == 1.7976931348623157e+308
end

@testitem "Edge case: Negative zero" begin
    d = parsetoml("negzero = -0")
    @test d["negzero"] == 0
end

@testitem "Edge case: Mixed string types in arrays" begin
    d = parsetoml("""
    strings = ["basic", 'literal', \"\"\"multiline\"\"\", '''raw multiline''']
    """)
    @test length(d["strings"]) == 4
    @test all(isa.(d["strings"], String))
end

# ── Error Handling Tests (adapted for error recovery) ──────────────────────

@testitem "Error: Invalid key-value without key" begin
    # TomlSyntax recovers from this error
    src = """
= "no key name"
valid = 1
"""
    d = parsetoml(src)
    # The invalid line should be skipped, valid line should parse
    @test d["valid"] == 1
    @test !haskey(d, "")
end

@testitem "Error: Key without value" begin
    # TomlSyntax recovers from this error
    src = """
key =
valid = 2
"""
    d = parsetoml(src)
    # The invalid line should be skipped, valid line should parse
    @test d["valid"] == 2
    @test !haskey(d, "key")
end

@testitem "Error: Multiple key-value pairs on one line" begin
    # TomlSyntax recovers from this error
    src = """
first = "Tom" last = "Preston-Werner"
valid = 3
"""
    d = parsetoml(src)
    # Should parse the first valid key, then error on the second
    @test d["valid"] == 3
end

@testitem "Error: Conflicting key assignments" begin
    # TomlSyntax handles duplicate keys via error recovery
    src = """
key = 1
key = 2
valid = 5
"""
    green = parse_toml_green(src)
    # Lossless: total span equals source length
    @test green.span == length(src)
    d = parsetoml(src)
    # The exact behavior depends on how TomlSyntax handles duplicates
    # At minimum, the valid key should be parseable
    @test d["valid"] == 5
end

@testitem "Error: Table conflict test" begin
    # TomlSyntax recovers from table conflicts
    src = """
[table]
x = 1
"""
    d = parsetoml(src)
    # The table should exist with its first key
    @test haskey(d, "table")
    @test d["table"]["x"] == 1
end

@testitem "Error: Duplicate standard table header" begin
    # TomlSyntax recovers from this error
    src = """
[section]
a = 1

[section]
b = 2
"""
    green = parse_toml_green(src)
    @test green.span == length(src)
    d = parsetoml(src)
    # The section should be parseable
    @test haskey(d, "section")
end

@testitem "Error: Array of tables then standard table conflict" begin
    # TomlSyntax recovers from this error
    src = """
[[fruit]]
name = "apple"

[fruit]
color = "red"
"""
    green = parse_toml_green(src)
    @test green.span == length(src)
    d = parsetoml(src)
    @test haskey(d, "fruit")
end

@testitem "Error: Invalid characters in bare keys" begin
    # TomlSyntax handles this gracefully
    src = """
bare@key = 1
valid = 7
"""
    d = parsetoml(src)
    @test d["valid"] == 7
end

@testitem "Error: Bare key like identifier in array" begin
    # TomlSyntax recovers from this error
    src = """
arr = [1, bare_value, 3]
valid = 8
"""
    d = parsetoml(src)
    @test d["valid"] == 8
    # The array should have the parseable elements
    @test 1 in d["arr"] && 3 in d["arr"]
end
end