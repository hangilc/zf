\ Multi-line word definition test

: factorial  \ ( n -- n! )
  dup 1 <= if
    drop 1
  else
    dup 1 - factorial *
  then
;

: test
  ." Factorials:" cr
  6 1 do
    i . ." ! = " i factorial . cr
  loop
;

test
