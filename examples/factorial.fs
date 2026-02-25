: factorial ( n -- n! )
  dup 1 <= if
    drop 1
  else
    dup 1 - factorial *
  then
;

." 10! = " 10 factorial . cr
