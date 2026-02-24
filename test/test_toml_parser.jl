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
    green = parse_toml_green("[server]\nhost = \"localhost\"")
    @test green.kind == K_TOPLEVEL
    @test green.children !== nothing
    @test green.span == length("[server]\nhost = \"localhost\"")

    # SyntaxNode API
    root = SyntaxNode(green, 1, "[server]\nhost = \"localhost\"")
    ntc = TomlSyntax.nontrivia_children(root)
    @test any(c -> kind(c) == K_STD_TABLE, ntc)
    @test any(c -> kind(c) == K_KEYVAL, ntc)
end

@testitem "Comments preserved in green tree" begin
    src = "# A comment\nkey = 1"
    green = parse_toml_green(src)
    root = SyntaxNode(green, 1, src)
    all_children = TomlSyntax.children(root)
    @test any(c -> kind(c) == K_COMMENT, all_children)
end

@testitem "Lossless round-trip" begin
    src = "[server]\n  host = \"localhost\" # comment\n  port = 8080\n"
    green = parse_toml_green(src)
    @test green.span == length(src)
    # The total span equals the source length → lossless
end
