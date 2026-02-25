"""
    TOMLParser

A TOML v1.0 parser for Julia, structured after the JuliaSyntax.jl architecture.

# Architecture (mirrors JuliaSyntax.jl)

1. **Kinds** (`TOMLKind`): An enum-like type tagging every node and token.
2. **Tokenizer** (`Tokenizer`): Produces a flat stream of `RawToken`s (position + kind).
3. **Parser** (`ParseState` + `parse!`): Recursive-descent parser that emits *events*
   into a `GreenNodeBuilder`, producing a lossless **Green Tree** (CST).
4. **GreenNode**: Immutable, position-independent CST node (stores kind + span + children).
5. **SyntaxNode**: A cursor/wrapper that pairs a `GreenNode` with an absolute position,
   providing the user-facing AST-like API.
6. **`parsetoml`**: High-level entry point returning `Dict{String,Any}`.

All whitespace & comments are preserved in the green tree (lossless), but are skipped by
the high-level Dict conversion.
"""
module TomlSyntax

export parsetoml, tokenize, parse_toml_green, SyntaxNode, GreenNode

# ══════════════════════════════════════════════════════════════════════════════
# §1  Kinds — analogous to JuliaSyntax.Kind
# ══════════════════════════════════════════════════════════════════════════════

"""
    TOMLKind

Enum representing the *kind* of every token and interior node in the CST.
"""
@enum TOMLKind::UInt16 begin
    # ── Special ──
    K_NONE           # sentinel / uninitialised
    K_ERROR          # error recovery token
    K_EOF            # end of file

    # ── Trivia (whitespace & comments) ──
    K_WHITESPACE     # spaces/tabs (no newlines)
    K_NEWLINE        # \n or \r\n
    K_COMMENT        # # …

    # ── Punctuation ──
    K_LBRACKET       # [
    K_RBRACKET       # ]
    K_LBRACE         # {
    K_RBRACE         # }
    K_DOT            # .
    K_COMMA          # ,
    K_EQ             # =

    # ── Literals ──
    K_BARE_KEY       # unquoted key
    K_BASIC_STRING   # "…"
    K_LITERAL_STRING # '…'
    K_ML_BASIC_STRING    # """…"""
    K_ML_LITERAL_STRING  # '''…'''
    K_INTEGER        # 42, 0x1A, 0o17, 0b1010
    K_FLOAT          # 3.14, inf, nan
    K_BOOL           # true / false
    K_DATETIME       # offset date-time, local date-time, local date, local time

    # ── Composite (interior) nodes ──
    K_TOPLEVEL       # root of the document
    K_KEYVAL         # key = value
    K_KEY            # a dotted or simple key (wrapper)
    K_VALUE          # a value wrapper node
    K_ARRAY          # [v, v, …]
    K_INLINE_TABLE   # {k = v, …}
    K_STD_TABLE      # [key]
    K_ARRAY_TABLE    # [[key]]
end

"""True if kind represents trivia (whitespace, newlines, comments)."""
is_trivia(k::TOMLKind) = k == K_WHITESPACE || k == K_NEWLINE || k == K_COMMENT

"""True if kind represents a string literal."""
is_string(k::TOMLKind) = k in (K_BASIC_STRING, K_LITERAL_STRING,
                                K_ML_BASIC_STRING, K_ML_LITERAL_STRING)

"""True if kind can appear as part of a key."""
is_key_kind(k::TOMLKind) = k == K_BARE_KEY || k == K_INTEGER || k == K_BASIC_STRING || k == K_LITERAL_STRING

# ══════════════════════════════════════════════════════════════════════════════
# §2  RawToken — the output of the Tokenizer
# ══════════════════════════════════════════════════════════════════════════════

"""
    RawToken

A lightweight token: just a kind and a byte range. No copy of the source text.
"""
struct RawToken
    kind::TOMLKind
    startbyte::Int   # 1-based inclusive
    endbyte::Int     # 1-based inclusive
end

Base.length(t::RawToken) = t.endbyte - t.startbyte + 1
span(t::RawToken) = length(t)

# ══════════════════════════════════════════════════════════════════════════════
# §3  Tokenizer (Lexer)
# ══════════════════════════════════════════════════════════════════════════════

"""
    Tokenizer

Stateful byte-level tokenizer for TOML. Produces `RawToken`s one at a time.
"""
mutable struct Tokenizer
    data::Vector{UInt8}
    pos::Int   # next byte to read, 1-based

    Tokenizer(s::AbstractString) = new(Vector{UInt8}(s), 1)
    Tokenizer(v::Vector{UInt8})  = new(v, 1)
end

Base.eof(t::Tokenizer) = t.pos > length(t.data)
peek_byte(t::Tokenizer) = t.data[t.pos]

function peek_byte(t::Tokenizer, offset::Int)
    i = t.pos + offset
    1 <= i <= length(t.data) ? t.data[i] : 0x00
end

advance!(t::Tokenizer) = (t.pos += 1)

function next_token!(t::Tokenizer)::RawToken
    if eof(t)
        return RawToken(K_EOF, t.pos, t.pos - 1)
    end

    start = t.pos
    c = peek_byte(t)

    # ── Newline ──
    if c == UInt8('\n')
        advance!(t)
        return RawToken(K_NEWLINE, start, t.pos - 1)
    elseif c == UInt8('\r')
        advance!(t)
        if !eof(t) && peek_byte(t) == UInt8('\n')
            advance!(t)
        end
        return RawToken(K_NEWLINE, start, t.pos - 1)
    end

    # ── Whitespace (spaces / tabs, no newlines) ──
    if c == UInt8(' ') || c == UInt8('\t')
        while !eof(t) && (peek_byte(t) == UInt8(' ') || peek_byte(t) == UInt8('\t'))
            advance!(t)
        end
        return RawToken(K_WHITESPACE, start, t.pos - 1)
    end

    # ── Comment ──
    if c == UInt8('#')
        while !eof(t) && peek_byte(t) != UInt8('\n') && peek_byte(t) != UInt8('\r')
            advance!(t)
        end
        return RawToken(K_COMMENT, start, t.pos - 1)
    end

    # ── Punctuation ──
    if c == UInt8('['); advance!(t); return RawToken(K_LBRACKET, start, start); end
    if c == UInt8(']'); advance!(t); return RawToken(K_RBRACKET, start, start); end
    if c == UInt8('{'); advance!(t); return RawToken(K_LBRACE,  start, start); end
    if c == UInt8('}'); advance!(t); return RawToken(K_RBRACE,  start, start); end
    if c == UInt8('.'); advance!(t); return RawToken(K_DOT,     start, start); end
    if c == UInt8(','); advance!(t); return RawToken(K_COMMA,   start, start); end
    if c == UInt8('='); advance!(t); return RawToken(K_EQ,      start, start); end

    # ── Strings ──
    if c == UInt8('"')
        return lex_basic_string!(t, start)
    end
    if c == UInt8('\'')
        return lex_literal_string!(t, start)
    end

    # ── Numbers (or date-times starting with a digit) ──
    if is_digit(c) || (c == UInt8('+') || c == UInt8('-'))
        return lex_number_or_date!(t, start)
    end

    # ── Bare key / boolean / inf / nan ──
    if is_bare_key_char(c)
        return lex_bare_key_or_keyword!(t, start)
    end

    # ── Unknown → error token ──
    advance!(t)
    return RawToken(K_ERROR, start, t.pos - 1)
end

# ── helpers ──

is_digit(c::UInt8)  = UInt8('0') <= c <= UInt8('9')
is_hex(c::UInt8)    = is_digit(c) || (UInt8('a') <= c <= UInt8('f')) || (UInt8('A') <= c <= UInt8('F'))
is_alpha(c::UInt8)  = (UInt8('a') <= c <= UInt8('z')) || (UInt8('A') <= c <= UInt8('Z'))

function is_bare_key_char(c::UInt8)
    is_digit(c) || is_alpha(c) || c == UInt8('-') || c == UInt8('_')
end

function lex_basic_string!(t::Tokenizer, start::Int)
    advance!(t) # skip opening "
    # Check for multi-line """
    if !eof(t) && peek_byte(t) == UInt8('"') && peek_byte(t, 1) == UInt8('"')
        advance!(t); advance!(t) # skip two more "
        return lex_ml_basic_string!(t, start)
    end
    # Single-line basic string
    while !eof(t)
        c = peek_byte(t)
        if c == UInt8('\\')
            advance!(t) # skip backslash
            if !eof(t); advance!(t); end # skip escaped char
        elseif c == UInt8('"')
            advance!(t)
            return RawToken(K_BASIC_STRING, start, t.pos - 1)
        elseif c == UInt8('\n') || c == UInt8('\r')
            # Unterminated string
            return RawToken(K_ERROR, start, t.pos - 1)
        else
            advance!(t)
        end
    end
    return RawToken(K_ERROR, start, t.pos - 1)
end

function lex_ml_basic_string!(t::Tokenizer, start::Int)
    # We have already consumed the opening """
    while !eof(t)
        c = peek_byte(t)
        if c == UInt8('\\')
            advance!(t)
            if !eof(t); advance!(t); end
        elseif c == UInt8('"') && peek_byte(t, 1) == UInt8('"') && peek_byte(t, 2) == UInt8('"')
            advance!(t); advance!(t); advance!(t)
            # TOML allows up to two extra quotes: """""
            while !eof(t) && peek_byte(t) == UInt8('"'); advance!(t); end
            return RawToken(K_ML_BASIC_STRING, start, t.pos - 1)
        else
            advance!(t)
        end
    end
    return RawToken(K_ERROR, start, t.pos - 1)
end

function lex_literal_string!(t::Tokenizer, start::Int)
    advance!(t) # skip opening '
    if !eof(t) && peek_byte(t) == UInt8('\'') && peek_byte(t, 1) == UInt8('\'')
        advance!(t); advance!(t)
        return lex_ml_literal_string!(t, start)
    end
    while !eof(t)
        c = peek_byte(t)
        if c == UInt8('\'')
            advance!(t)
            return RawToken(K_LITERAL_STRING, start, t.pos - 1)
        elseif c == UInt8('\n') || c == UInt8('\r')
            return RawToken(K_ERROR, start, t.pos - 1)
        else
            advance!(t)
        end
    end
    return RawToken(K_ERROR, start, t.pos - 1)
end

function lex_ml_literal_string!(t::Tokenizer, start::Int)
    while !eof(t)
        c = peek_byte(t)
        if c == UInt8('\'') && peek_byte(t, 1) == UInt8('\'') && peek_byte(t, 2) == UInt8('\'')
            advance!(t); advance!(t); advance!(t)
            while !eof(t) && peek_byte(t) == UInt8('\''); advance!(t); end
            return RawToken(K_ML_LITERAL_STRING, start, t.pos - 1)
        else
            advance!(t)
        end
    end
    return RawToken(K_ERROR, start, t.pos - 1)
end

function lex_number_or_date!(t::Tokenizer, start::Int)
    # Consume a +/- prefix if present
    c = peek_byte(t)
    has_sign = false
    if c == UInt8('+') || c == UInt8('-')
        has_sign = true
        advance!(t)
        if eof(t)
            return RawToken(K_ERROR, start, t.pos - 1)
        end
        c = peek_byte(t)
    end

    # inf / nan after sign
    if !has_sign || (c != UInt8('i') && c != UInt8('n'))
        # nothing
    end
    if is_alpha(c)
        # Could be +inf, -inf, +nan, -nan
        word_start = t.pos
        while !eof(t) && is_bare_key_char(peek_byte(t))
            advance!(t)
        end
        word = String(t.data[word_start:t.pos-1])
        if word in ("inf", "nan")
            return RawToken(K_FLOAT, start, t.pos - 1)
        end
        return RawToken(K_ERROR, start, t.pos - 1)
    end

    if !is_digit(c)
        return RawToken(K_ERROR, start, t.pos - 1)
    end

    # Check for 0x, 0o, 0b
    if c == UInt8('0') && !eof(t)
        c2 = peek_byte(t, 1)
        if c2 == UInt8('x') || c2 == UInt8('o') || c2 == UInt8('b')
            advance!(t); advance!(t)
            while !eof(t) && (is_hex(peek_byte(t)) || peek_byte(t) == UInt8('_'))
                advance!(t)
            end
            return RawToken(K_INTEGER, start, t.pos - 1)
        end
    end

    # Consume digits (with optional underscores)
    while !eof(t) && (is_digit(peek_byte(t)) || peek_byte(t) == UInt8('_'))
        advance!(t)
    end

    # Check for date-time: if next char is '-' or ':' and we had 2 or 4 digits, it's a date/time
    if !eof(t) && !has_sign
        nc = peek_byte(t)
        digit_count = t.pos - start
        if nc == UInt8('-') && digit_count == 4
            # Looks like a date: YYYY-...
            return lex_datetime!(t, start)
        elseif nc == UInt8(':') && digit_count == 2
            # Looks like a local time: HH:...
            return lex_datetime!(t, start)
        end
    end

    if eof(t)
        return RawToken(K_INTEGER, start, t.pos - 1)
    end

    nc = peek_byte(t)

    # Float: dot or exponent
    is_float = false
    if nc == UInt8('.')
        advance!(t)
        is_float = true
        while !eof(t) && (is_digit(peek_byte(t)) || peek_byte(t) == UInt8('_'))
            advance!(t)
        end
        if !eof(t)
            nc = peek_byte(t)
        end
    end
    if !eof(t) && (peek_byte(t) == UInt8('e') || peek_byte(t) == UInt8('E'))
        is_float = true
        advance!(t)
        if !eof(t) && (peek_byte(t) == UInt8('+') || peek_byte(t) == UInt8('-'))
            advance!(t)
        end
        while !eof(t) && (is_digit(peek_byte(t)) || peek_byte(t) == UInt8('_'))
            advance!(t)
        end
    end

    return RawToken(is_float ? K_FLOAT : K_INTEGER, start, t.pos - 1)
end

function lex_datetime!(t::Tokenizer, start::Int)
    # We've consumed the first group of digits (date YYYY or time HH).
    # Continue consuming anything that looks datetime-ish: digits, -, :, T, Z, +, .
    while !eof(t)
        c = peek_byte(t)
        if is_digit(c) || c == UInt8('-') || c == UInt8(':') || c == UInt8('.') ||
           c == UInt8('T') || c == UInt8('t') || c == UInt8('Z') || c == UInt8('z') ||
           c == UInt8('+') || c == UInt8(' ')
            # Space is allowed between date and time in TOML: "1979-05-27 07:32:00"
            # but only if followed by a digit (to avoid eating trailing spaces)
            if c == UInt8(' ')
                if peek_byte(t, 1) != 0x00 && is_digit(peek_byte(t, 1))
                    advance!(t)
                else
                    break
                end
            else
                advance!(t)
            end
        else
            break
        end
    end
    return RawToken(K_DATETIME, start, t.pos - 1)
end

function lex_bare_key_or_keyword!(t::Tokenizer, start::Int)
    while !eof(t) && is_bare_key_char(peek_byte(t))
        advance!(t)
    end
    word = String(t.data[start:t.pos-1])
    if word == "true" || word == "false"
        return RawToken(K_BOOL, start, t.pos - 1)
    elseif word == "inf" || word == "nan"
        return RawToken(K_FLOAT, start, t.pos - 1)
    end
    return RawToken(K_BARE_KEY, start, t.pos - 1)
end

"""
    tokenize(source::AbstractString) → Vector{RawToken}

Tokenize the full source into a vector of tokens (including trivia and EOF).
"""
function tokenize(source::AbstractString)
    t = Tokenizer(source)
    tokens = RawToken[]
    while true
        tok = next_token!(t)
        push!(tokens, tok)
        if tok.kind == K_EOF
            break
        end
    end
    return tokens
end

# ══════════════════════════════════════════════════════════════════════════════
# §4  GreenNode — immutable, position-independent CST node
# ══════════════════════════════════════════════════════════════════════════════

"""
    GreenNode

An immutable CST node. Leaves hold raw byte spans; interior nodes hold children.
This mirrors the green tree concept from JuliaSyntax.jl / Roslyn.

- `kind`: The `TOMLKind` of this node.
- `span`: Total byte width of this node (including all children / trivia).
- `children`: `nothing` for leaf tokens, `Vector{GreenNode}` for interior nodes.
"""
struct GreenNode
    kind::TOMLKind
    span::Int
    children::Union{Nothing, Vector{GreenNode}}
end

is_leaf(n::GreenNode) = n.children === nothing
Base.length(n::GreenNode) = n.span
kind(n::GreenNode) = n.kind

function Base.show(io::IO, n::GreenNode)
    if is_leaf(n)
        print(io, "GreenNode(", n.kind, ", span=", n.span, ")")
    else
        print(io, "GreenNode(", n.kind, ", span=", n.span, ", ", Base.length(n.children), " children)")
    end
end

function print_green_tree(io::IO, node::GreenNode, source::AbstractString, offset::Int=0; indent::Int=0)
    prefix = "  " ^ indent
    if is_leaf(node)
        text = source[offset+1 : offset+node.span]
        println(io, prefix, node.kind, " (", repr(text), ")")
    else
        println(io, prefix, node.kind, " [span=", node.span, "]")
        child_offset = offset
        for child in node.children
            print_green_tree(io, child, source, child_offset; indent=indent+1)
            child_offset += child.span
        end
    end
end

print_green_tree(node::GreenNode, source::AbstractString; kw...) =
    print_green_tree(stdout, node, source; kw...)

# ══════════════════════════════════════════════════════════════════════════════
# §5  Parser — recursive descent, emitting a GreenNode tree
# ══════════════════════════════════════════════════════════════════════════════

"""
    ParseState

Holds the token stream and current position for the recursive-descent parser.
Analogous to `JuliaSyntax.ParseState`.
"""
mutable struct ParseState
    source::String
    tokens::Vector{RawToken}
    pos::Int  # index into tokens

    ParseState(source::AbstractString) = begin
        tokens = tokenize(source)
        new(String(source), tokens, 1)
    end
end

current_token(ps::ParseState) = ps.tokens[ps.pos]
peek_kind(ps::ParseState)     = current_token(ps).kind

function at_eof(ps::ParseState)
    peek_kind(ps) == K_EOF
end

"""Consume the current token, returning it as a leaf GreenNode."""
function bump!(ps::ParseState)::GreenNode
    tok = current_token(ps)
    ps.pos += 1
    GreenNode(tok.kind, span(tok), nothing)
end

"""Consume tokens while they are trivia, collecting them into a vector."""
function collect_trivia!(ps::ParseState, nodes::Vector{GreenNode})
    while !at_eof(ps) && is_trivia(peek_kind(ps))
        push!(nodes, bump!(ps))
    end
end

"""Expect a specific kind; emit error node if mismatch."""
function expect!(ps::ParseState, kind::TOMLKind, nodes::Vector{GreenNode})
    if peek_kind(ps) == kind
        push!(nodes, bump!(ps))
    else
        # Insert a zero-width error node
        push!(nodes, GreenNode(K_ERROR, 0, nothing))
    end
end

"""
Skip tokens up to (but not including) the next newline or EOF,
collecting all skipped tokens as children of a K_ERROR interior node.
Returns a zero-width K_ERROR leaf if nothing was skipped.
"""
function skip_to_eol!(ps::ParseState)::GreenNode
    nodes = GreenNode[]
    while !at_eof(ps) && peek_kind(ps) != K_NEWLINE
        push!(nodes, bump!(ps))
    end
    isempty(nodes) && return GreenNode(K_ERROR, 0, nothing)
    total_span = sum(n.span for n in nodes; init=0)
    GreenNode(K_ERROR, total_span, nodes)
end

"""
Skip tokens until one of the given stop kinds is reached (or EOF),
collecting all skipped tokens as children of a K_ERROR interior node.
Returns a zero-width K_ERROR leaf if nothing was skipped.
"""
function skip_until!(ps::ParseState, stop_kinds::NTuple)::GreenNode
    nodes = GreenNode[]
    while !at_eof(ps) && !(peek_kind(ps) in stop_kinds)
        push!(nodes, bump!(ps))
    end
    isempty(nodes) && return GreenNode(K_ERROR, 0, nothing)
    total_span = sum(n.span for n in nodes; init=0)
    GreenNode(K_ERROR, total_span, nodes)
end

# ── Top-level parser ──

"""
    parse_toml_green(source::AbstractString) → GreenNode

Parse the source into a green tree (CST). The root node has kind `K_TOPLEVEL`.
"""
function parse_toml_green(source::AbstractString)::GreenNode
    ps = ParseState(source)
    children = GreenNode[]

    while !at_eof(ps)
        collect_trivia!(ps, children)
        at_eof(ps) && break

        k = peek_kind(ps)
        if k == K_LBRACKET
            # Could be [table] or [[array-table]]
            push!(children, parse_table_header!(ps))
        elseif is_key_kind(k)
            push!(children, parse_keyval!(ps))
        else
            # Unexpected token — skip to end of line, wrapping all skipped
            # tokens (including this one) in a single K_ERROR interior node.
            push!(children, skip_to_eol!(ps))
        end
    end

    # Consume trailing trivia + EOF
    collect_trivia!(ps, children)
    if !at_eof(ps)
        push!(children, bump!(ps))  # EOF token
    end

    total_span = sum(n.span for n in children; init=0)
    GreenNode(K_TOPLEVEL, total_span, children)
end

function parse_table_header!(ps::ParseState)::GreenNode
    children = GreenNode[]

    # Peek ahead to distinguish [[…]] from […]
    # We need to look past the first '[' and any whitespace
    saved_pos = ps.pos
    is_array_table = false
    if peek_kind(ps) == K_LBRACKET
        next_idx = ps.pos + 1
        # Skip whitespace tokens to find potential second [
        while next_idx <= length(ps.tokens) && is_trivia(ps.tokens[next_idx].kind)
            next_idx += 1
        end
        if next_idx <= length(ps.tokens) && ps.tokens[next_idx].kind == K_LBRACKET
            is_array_table = true
        end
    end

    if is_array_table
        # [[key]]
        push!(children, bump!(ps))  # first [
        collect_trivia!(ps, children)
        push!(children, bump!(ps))  # second [
        collect_trivia!(ps, children)
        push!(children, parse_key!(ps))
        collect_trivia!(ps, children)
        expect!(ps, K_RBRACKET, children)
        collect_trivia!(ps, children)
        expect!(ps, K_RBRACKET, children)
        kind = K_ARRAY_TABLE
    else
        # [key]
        push!(children, bump!(ps))  # [
        collect_trivia!(ps, children)
        push!(children, parse_key!(ps))
        collect_trivia!(ps, children)
        expect!(ps, K_RBRACKET, children)
        kind = K_STD_TABLE
    end

    total_span = sum(n.span for n in children; init=0)
    GreenNode(kind, total_span, children)
end

function parse_key!(ps::ParseState)::GreenNode
    children = GreenNode[]
    # A key is: simple-key *( '.' simple-key )
    push!(children, parse_simple_key!(ps))
    while !at_eof(ps)
        collect_trivia!(ps, children)
        if peek_kind(ps) == K_DOT
            push!(children, bump!(ps))  # .
            collect_trivia!(ps, children)
            push!(children, parse_simple_key!(ps))
        else
            break
        end
    end
    total_span = sum(n.span for n in children; init=0)
    GreenNode(K_KEY, total_span, children)
end

function parse_simple_key!(ps::ParseState)::GreenNode
    k = peek_kind(ps)
    if k == K_BARE_KEY || k == K_BASIC_STRING || k == K_LITERAL_STRING
        return bump!(ps)
    end
    # Error
    return GreenNode(K_ERROR, 0, nothing)
end

function parse_keyval!(ps::ParseState)::GreenNode
    children = GreenNode[]
    push!(children, parse_key!(ps))
    collect_trivia!(ps, children)
    if peek_kind(ps) == K_EQ
        push!(children, bump!(ps))  # =
        collect_trivia!(ps, children)
        push!(children, parse_value!(ps))
    else
        # Missing '=': insert a zero-width error sentinel.
        # Recovery is left to the caller (top-level skips to EOL via its own
        # else branch; parse_inline_table! uses skip_until! as a guard).
        push!(children, GreenNode(K_ERROR, 0, nothing))
    end
    total_span = sum(n.span for n in children; init=0)
    GreenNode(K_KEYVAL, total_span, children)
end

function parse_value!(ps::ParseState)::GreenNode
    k = peek_kind(ps)
    if k == K_BASIC_STRING || k == K_LITERAL_STRING ||
       k == K_ML_BASIC_STRING || k == K_ML_LITERAL_STRING ||
       k == K_INTEGER || k == K_FLOAT || k == K_BOOL || k == K_DATETIME
        return bump!(ps)
    elseif k == K_ERROR
        # Tokenizer-level error (e.g. unterminated string): consume the token
        # so it becomes the error value node rather than leaking into the stream.
        return bump!(ps)
    elseif k == K_LBRACKET
        return parse_array!(ps)
    elseif k == K_LBRACE
        return parse_inline_table!(ps)
    else
        # Missing value: return a zero-width error without consuming anything.
        return GreenNode(K_ERROR, 0, nothing)
    end
end

function parse_array!(ps::ParseState)::GreenNode
    children = GreenNode[]
    push!(children, bump!(ps))  # [
    collect_trivia!(ps, children)

    # Values separated by commas; trailing comma allowed
    while !at_eof(ps) && peek_kind(ps) != K_RBRACKET
        prev_pos = ps.pos
        push!(children, parse_value!(ps))
        collect_trivia!(ps, children)
        if ps.pos == prev_pos
            # parse_value! made no progress (unexpected token that is not a
            # valid value and not a K_ERROR from the tokenizer).  Skip ahead
            # to the next separator or close bracket so we don't stall.
            push!(children, skip_until!(ps, (K_COMMA, K_RBRACKET, K_NEWLINE)))
            collect_trivia!(ps, children)
        end
        if peek_kind(ps) == K_COMMA
            push!(children, bump!(ps))  # ,
            collect_trivia!(ps, children)
        else
            break
        end
    end

    expect!(ps, K_RBRACKET, children)
    total_span = sum(n.span for n in children; init=0)
    GreenNode(K_ARRAY, total_span, children)
end

function parse_inline_table!(ps::ParseState)::GreenNode
    children = GreenNode[]
    push!(children, bump!(ps))  # {
    collect_trivia!(ps, children)

    first = true
    while !at_eof(ps) && peek_kind(ps) != K_RBRACE
        if !first
            expect!(ps, K_COMMA, children)
            collect_trivia!(ps, children)
        end
        first = false
        prev_pos = ps.pos
        push!(children, parse_keyval!(ps))
        collect_trivia!(ps, children)
        # Guard against infinite loop: if parse_keyval! made no progress
        # (e.g. current token is not a key kind and not at end-of-line),
        # skip ahead to the next logical separator to avoid stalling.
        if ps.pos == prev_pos
            push!(children, skip_until!(ps, (K_COMMA, K_RBRACE, K_NEWLINE)))
            collect_trivia!(ps, children)
        end
    end

    expect!(ps, K_RBRACE, children)
    total_span = sum(n.span for n in children; init=0)
    GreenNode(K_INLINE_TABLE, total_span, children)
end

# ══════════════════════════════════════════════════════════════════════════════
# §6  SyntaxNode — cursor over the green tree with absolute positions
# ══════════════════════════════════════════════════════════════════════════════

"""
    SyntaxNode

A cursor that wraps a `GreenNode` and an absolute byte offset into the source.
This is the user-facing API for navigating the CST, analogous to
`JuliaSyntax.SyntaxNode`.
"""
struct SyntaxNode
    green::GreenNode
    position::Int       # 1-based byte offset of the start of this node
    source::String      # the full original source
end

kind(n::SyntaxNode) = n.green.kind
span(n::SyntaxNode) = n.green.span
is_leaf(n::SyntaxNode) = is_leaf(n.green)

"""Get the source text covered by this node."""
function sourcetext(n::SyntaxNode)
    n.source[n.position : n.position + n.green.span - 1]
end

"""Return the children of this node as `SyntaxNode`s."""
function children(n::SyntaxNode)
    if is_leaf(n.green)
        return SyntaxNode[]
    end
    result = SyntaxNode[]
    offset = n.position
    for child_green in n.green.children
        push!(result, SyntaxNode(child_green, offset, n.source))
        offset += child_green.span
    end
    return result
end

"""Return non-trivia children."""
function nontrivia_children(n::SyntaxNode)
    filter(c -> !is_trivia(kind(c)), children(n))
end

function Base.show(io::IO, n::SyntaxNode)
    print(io, "SyntaxNode(", kind(n), ", pos=", n.position, ", span=", span(n), ")")
end

# ══════════════════════════════════════════════════════════════════════════════
# §7  Value conversion — GreenNode / SyntaxNode → Julia types
# ══════════════════════════════════════════════════════════════════════════════

"""
    node_value(node::SyntaxNode) → Any

Convert a value-bearing SyntaxNode into the corresponding Julia value.
"""
function node_value(n::SyntaxNode)
    k = kind(n)
    text = sourcetext(n)

    if k == K_BASIC_STRING
        inner = SubString(text, nextind(text, 1), prevind(text, ncodeunits(text)))
        return unescape_basic_string(String(inner))
    elseif k == K_LITERAL_STRING
        inner = SubString(text, nextind(text, 1), prevind(text, ncodeunits(text)))
        return String(inner)
    elseif k == K_ML_BASIC_STRING
        # For multiline strings ("""), convert to string first then use proper string indexing
        s = String(text)
        # Skip the first """ and last """ - using string character indexing which handles UTF-8
        s = s[4:end-3]
        # Strip leading newline per TOML spec
        if startswith(s, "\n"); s = s[2:end]
        elseif startswith(s, "\r\n"); s = s[3:end]; end
        return unescape_basic_string(s)
    elseif k == K_ML_LITERAL_STRING
        # For multiline literal strings ('''), convert to string first then use proper string indexing
        s = String(text)
        # Skip the first ''' and last ''' - using string character indexing which handles UTF-8
        s = s[4:end-3]
        if startswith(s, "\n"); s = s[2:end]
        elseif startswith(s, "\r\n"); s = s[3:end]; end
        return s
    elseif k == K_INTEGER
        return parse_toml_integer(text)
    elseif k == K_FLOAT
        return parse_toml_float(text)
    elseif k == K_BOOL
        return text == "true"
    elseif k == K_DATETIME
        return parse_toml_datetime(text)
    elseif k == K_ARRAY
        return convert_array(n)
    elseif k == K_INLINE_TABLE
        return convert_inline_table(n)
    else
        error("Cannot convert node of kind $k to a value")
    end
end

function convert_array(n::SyntaxNode)
    result = Any[]
    for child in nontrivia_children(n)
        k = kind(child)
        k == K_LBRACKET && continue
        k == K_RBRACKET && continue
        k == K_COMMA    && continue
        k == K_ERROR    && continue  # skip error recovery nodes
        push!(result, node_value(child))
    end
    return result
end

function convert_inline_table(n::SyntaxNode)
    result = Dict{String,Any}()
    for child in nontrivia_children(n)
        k = kind(child)
        k == K_LBRACE  && continue
        k == K_RBRACE  && continue
        k == K_COMMA   && continue
        k == K_ERROR   && continue  # skip error recovery nodes
        if k == K_KEYVAL
            set_keyval!(result, child)
        end
    end
    return result
end

function key_parts(n::SyntaxNode)::Vector{String}
    # n is a K_KEY node; extract its dotted key segments
    parts = String[]
    for child in nontrivia_children(n)
        k = kind(child)
        k == K_DOT && continue
        if k == K_BARE_KEY
            push!(parts, sourcetext(child))
        elseif k == K_INTEGER
            # Numeric bare keys like 1234 should be treated as string keys
            push!(parts, sourcetext(child))
        elseif k == K_BASIC_STRING
            text = sourcetext(child)
            # Use proper Unicode-safe substring extraction: remove first and last character
            inner = SubString(text, nextind(text, 1), prevind(text, ncodeunits(text)))
            push!(parts, unescape_basic_string(String(inner)))
        elseif k == K_LITERAL_STRING
            text = sourcetext(child)
            # Use proper Unicode-safe substring extraction: remove first and last character
            inner = SubString(text, nextind(text, 1), prevind(text, ncodeunits(text)))
            push!(parts, String(inner))
        elseif k == K_KEY
            # Nested K_KEY (shouldn't normally happen but handle gracefully)
            append!(parts, key_parts(child))
        end
    end
    return parts
end

function set_keyval!(table::Dict{String,Any}, kv_node::SyntaxNode)
    ntc = nontrivia_children(kv_node)
    # Find key and value nodes (skip K_EQ and K_ERROR)
    key_node = nothing
    val_node = nothing
    for child in ntc
        k = kind(child)
        if k == K_KEY
            key_node = child
        elseif k == K_EQ || k == K_ERROR
            # skip separator and any error recovery nodes
            continue
        elseif key_node !== nothing
            val_node = child
            break
        end
    end

    if key_node === nothing || val_node === nothing
        return
    end

    parts = key_parts(key_node)
    isempty(parts) && return  # key parsing entirely failed; nothing to set

    value = node_value(val_node)

    # Navigate / create intermediate tables for dotted keys
    current = table
    for i in 1:length(parts)-1
        p = parts[i]
        if !haskey(current, p)
            current[p] = Dict{String,Any}()
        end
        current = current[p]
    end
    current[parts[end]] = value
end

# ── String unescaping ──

function unescape_basic_string(s::AbstractString)
    buf = IOBuffer()
    i = 1
    chars = collect(s)
    while i <= length(chars)
        c = chars[i]
        if c == '\\'
            i += 1
            if i > length(chars); break; end
            esc = chars[i]
            if     esc == 'b';  write(buf, '\b')
            elseif esc == 't';  write(buf, '\t')
            elseif esc == 'n';  write(buf, '\n')
            elseif esc == 'f';  write(buf, '\f')
            elseif esc == 'r';  write(buf, '\r')
            elseif esc == '"';  write(buf, '"')
            elseif esc == '\\'; write(buf, '\\')
            elseif esc == 'u'
                hex = String(chars[i+1:i+4]); i += 4
                write(buf, Char(parse(UInt32, hex; base=16)))
            elseif esc == 'U'
                hex = String(chars[i+1:i+8]); i += 8
                write(buf, Char(parse(UInt32, hex; base=16)))
            elseif esc == '\n' || esc == '\r'
                # Line ending backslash — skip whitespace
                i += 1
                while i <= length(chars) && (chars[i] == ' ' || chars[i] == '\t' ||
                                               chars[i] == '\n' || chars[i] == '\r')
                    i += 1
                end
                continue
            else
                write(buf, '\\'); write(buf, esc)
            end
        else
            write(buf, c)
        end
        i += 1
    end
    return String(take!(buf))
end

# ── Number parsing ──

function parse_toml_integer(s::AbstractString)
    s = replace(s, "_" => "")
    if startswith(s, "0x") || startswith(s, "0X")
        return parse(Int64, s[3:end]; base=16)
    elseif startswith(s, "0o") || startswith(s, "0O")
        return parse(Int64, s[3:end]; base=8)
    elseif startswith(s, "0b") || startswith(s, "0B")
        return parse(Int64, s[3:end]; base=2)
    else
        return parse(Int64, s)
    end
end

function parse_toml_float(s::AbstractString)
    s = replace(s, "_" => "")
    if s in ("inf", "+inf");  return Inf
    elseif s == "-inf";       return -Inf
    elseif s in ("nan", "+nan"); return NaN
    elseif s == "-nan";       return NaN  # TOML spec: -nan is still NaN
    end
    return parse(Float64, s)
end

# ── DateTime parsing ──

using Dates

function parse_toml_datetime(s::AbstractString)
    # Normalize 'T' separator (TOML also allows space)
    s = replace(s, r"(?<=\d) (?=\d)" => "T")

    # Try offset date-time: 1979-05-27T07:32:00Z or …+00:00
    if occursin('Z', s) || occursin('z', s) || occursin(r"[+-]\d{2}:\d{2}$", s)
        # Strip offset for parsing; store it conceptually
        # Julia's Dates doesn't have offset support, so parse as DateTime
        base = replace(s, r"[Zz]$" => "")
        base = replace(base, r"[+-]\d{2}:\d{2}$" => "")
        return _parse_datetime(base)
    end

    # Local date-time: 1979-05-27T07:32:00
    if occursin('T', s) || occursin('t', s)
        return _parse_datetime(s)
    end

    # Local date: 1979-05-27
    if occursin('-', s) && !occursin(':', s)
        return Date(s)
    end

    # Local time: 07:32:00 or 07:32:00.999
    if occursin(':', s)
        return _parse_time(s)
    end

    return s  # fallback
end

function _parse_time(s::AbstractString)
    # Handle fractional seconds
    if occursin('.', s)
        m = match(r"(\d{2}):(\d{2}):(\d{2})\.(\d+)", s)
        if m !== nothing
            hour = parse(Int, m.captures[1])
            minute = parse(Int, m.captures[2])
            second = parse(Int, m.captures[3])
            frac = m.captures[4]
            # Convert fractional part to milliseconds
            ms = parse(Int, rpad(frac[1:min(3,length(frac))], 3, '0'))
            return Time(hour, minute, second, ms)
        end
    end
    return Time(s)
end

function _parse_datetime(s::AbstractString)
    s = replace(s, r"[Tt]" => "T")
    # Handle fractional seconds
    if occursin('.', s)
        # Truncate to milliseconds for Julia
        m = match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.(\d+)", s)
        if m !== nothing
            frac = m.captures[2]
            ms = parse(Int, rpad(frac[1:min(3,length(frac))], 3, '0'))
            return DateTime(m.captures[1], dateformat"yyyy-mm-ddTHH:MM:SS") + Millisecond(ms)
        end
    end
    return DateTime(s, dateformat"yyyy-mm-ddTHH:MM:SS")
end

# ══════════════════════════════════════════════════════════════════════════════
# §8  High-level API: parsetoml
# ══════════════════════════════════════════════════════════════════════════════

"""
    parsetoml(source::AbstractString) → Dict{String, Any}

Parse a TOML string and return a nested `Dict{String, Any}`, matching the
interface of `TOML.parse` in the standard library.

## Example
```julia
d = parsetoml(\"\"\"
[server]
host = "localhost"
port = 8080
\"\"\")
d["server"]["host"]  # "localhost"
```
"""
function parsetoml(source::AbstractString)::Dict{String,Any}
    green = parse_toml_green(source)
    root = SyntaxNode(green, 1, String(source))
    return build_dict(root)
end

function build_dict(root::SyntaxNode)::Dict{String,Any}
    result = Dict{String,Any}()
    current_table = result
    current_path = String[]

    for child in children(root)
        k = kind(child)
        is_trivia(k) && continue
        k == K_EOF && continue

        if k == K_KEYVAL
            set_keyval!(current_table, child)

        elseif k == K_STD_TABLE
            # [table.path]
            path = extract_header_key(child)
            current_path = path
            current_table = ensure_table!(result, path)

        elseif k == K_ARRAY_TABLE
            # [[array.table]]
            path = extract_header_key(child)
            current_path = path
            current_table = ensure_array_table!(result, path)
        end
    end

    return result
end

function extract_header_key(header_node::SyntaxNode)::Vector{String}
    for child in nontrivia_children(header_node)
        if kind(child) == K_KEY
            return key_parts(child)
        end
    end
    return String[]
end

function ensure_table!(root::Dict{String,Any}, path::Vector{String})
    current = root
    for p in path
        if !haskey(current, p)
            current[p] = Dict{String,Any}()
        end
        v = current[p]
        if v isa Vector
            current = v[end]  # Navigate into the last element of an array-table
        else
            current = v
        end
    end
    return current
end

function ensure_array_table!(root::Dict{String,Any}, path::Vector{String})
    current = root
    for i in 1:length(path)-1
        p = path[i]
        if !haskey(current, p)
            current[p] = Dict{String,Any}()
        end
        v = current[p]
        if v isa Vector
            current = v[end]
        else
            current = v
        end
    end
    last_key = path[end]
    if !haskey(current, last_key)
        current[last_key] = Any[]
    end
    arr = current[last_key]
    new_table = Dict{String,Any}()
    push!(arr, new_table)
    return new_table
end

end # module TomlSyntax
