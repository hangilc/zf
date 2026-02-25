# zf

A Forth interpreter written in Zig.

## Build

```
zig build
```

Binary is output to `./zig-out/bin/zf`.

## Usage

```
zf [options] [file...]
```

### Options

| Option | Description |
|--------|-------------|
| `-i`, `--interactive` | Enter REPL after running files |
| `-n`, `--no-rc` | Skip loading `~/.zfrc` |
| `-h`, `--help` | Show help |

### Examples

```bash
zf                        # Start REPL
zf program.fs             # Run a file
zf -i lib.fs              # Run file, then enter REPL
zf -n                     # REPL without loading ~/.zfrc
zf lib.fs main.fs         # Run multiple files in order
```

## Startup

On launch, zf loads `~/.zfrc` if it exists. Use `-n` to skip.

## Language

### Data Types

| Type | Example | Description |
|------|---------|-------------|
| Integer | `42`, `-7` | 64-bit signed integer |
| Float | `3.14`, `-0.5` | 64-bit floating point |
| String | `s" hello"` | String value on stack |

Arithmetic with mixed int/float automatically promotes to float.

### Stack Operations

| Word | Stack Effect | Description |
|------|-------------|-------------|
| `.` | `( n -- )` | Pop and print top |
| `.s` | `( -- )` | Display entire stack (non-destructive) |
| `drop` | `( n -- )` | Discard top |
| `dup` | `( n -- n n )` | Duplicate top |
| `swap` | `( a b -- b a )` | Swap top two |
| `over` | `( a b -- a b a )` | Copy second to top |
| `rot` | `( a b c -- b c a )` | Rotate third to top |

### Arithmetic

| Word | Stack Effect | Description |
|------|-------------|-------------|
| `+` | `( a b -- a+b )` | Add |
| `-` | `( a b -- a-b )` | Subtract |
| `*` | `( a b -- a*b )` | Multiply |
| `/` | `( a b -- a/b )` | Divide |
| `mod` | `( a b -- a%b )` | Modulo (integers only) |
| `negate` | `( n -- -n )` | Negate |
| `abs` | `( n -- |n| )` | Absolute value |

### Comparison

All comparisons return `-1` (true) or `0` (false).

| Word | Stack Effect | Description |
|------|-------------|-------------|
| `=` | `( a b -- flag )` | Equal |
| `<>` | `( a b -- flag )` | Not equal |
| `<` | `( a b -- flag )` | Less than |
| `>` | `( a b -- flag )` | Greater than |
| `<=` | `( a b -- flag )` | Less or equal |
| `>=` | `( a b -- flag )` | Greater or equal |
| `0=` | `( n -- flag )` | Equal to zero |
| `not` | `( flag -- flag )` | Logical not |

### Strings

| Syntax | Description |
|--------|-------------|
| `." hello"` | Print string immediately |
| `s" hello"` | Push string onto stack |

### Output

| Word | Description |
|------|-------------|
| `.` | Pop and print value |
| `.s` | Show stack contents |
| `." text"` | Print literal text |
| `cr` | Print newline |

### Word Definitions

```forth
: square ( n -- n*n ) dup * ;
5 square .  \ 25
```

Definitions can span multiple lines:

```forth
: factorial
  dup 1 <= if
    drop 1
  else
    dup 1 - factorial *
  then
;
```

| Word | Description |
|------|-------------|
| `: name ... ;` | Define a new word |
| `words` | List all defined words |

### Control Flow

#### If / Else / Then

```forth
: check 0 > if ." positive" else ." negative" then cr ;
5 check    \ positive
-3 check   \ negative
```

`else` is optional:

```forth
: maybe-print 0 > if ." yes" then cr ;
```

#### Do Loop

```forth
limit start do ... loop
```

Loops from `start` to `limit - 1`:

```forth
10 0 do i . loop cr    \ 0 1 2 3 4 5 6 7 8 9
```

With step:

```forth
10 0 do i . 2 +loop cr  \ 0 2 4 6 8
```

| Word | Description |
|------|-------------|
| `do` | Start loop (pops limit and start) |
| `loop` | Increment counter by 1, repeat if < limit |
| `+loop` | Add TOS to counter, repeat if < limit |
| `i` | Current loop counter |
| `j` | Outer loop counter (nested loops) |

### Comments

```forth
\ This is a line comment

( This is an inline comment )

: square ( n -- n*n ) dup * ;  \ with stack effect
```

### Other

| Word | Description |
|------|-------------|
| `bye` | Exit zf |

## Examples

See the `examples/` directory:

- `hello.fs` — Hello World
- `fizzbuzz.fs` — FizzBuzz 1–100
- `multiline.fs` — Recursive factorial

## License

MIT

Created with helps from OpenClaw and Claude Code.

