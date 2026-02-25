

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
